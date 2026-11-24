import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax

@MainActor
final class LanguageXMLOverrides<Definition: Sendable> {
    typealias Parser = @Sendable (Data, @escaping @Sendable () -> Bool) throws -> Definition

    struct Entry: Sendable {
        let generation = UUID()
        let xml: Data?
        let definition: Definition?
        let baseline: DiskBaseline?
        var diagnostic: String? = nil
    }

    enum Change {
        case reload
        case save(Data?, expecting: UUID?)
    }

    let kind: LanguageXMLOverrideStore.Kind
    let label: String
    let parse: Parser
    var entries: [String: Entry] = [:]
    var ready = false
    var busy = false

    /// 业务作用：独立的资源类别分别保存解析结果、磁盘基线和表单代次。
    /// 参数说明:
    /// - kind: 存储的固定语言资源类别。
    /// - label: 用户可见的资源名称。
    /// - parse: 已有 XML 解析器及格式校验规则。
    /// 返回：没有预读用户文件的独立运行状态。
    init(kind: LanguageXMLOverrideStore.Kind, label: String, parse: @escaping Parser) {
        self.kind = kind
        self.label = label
        self.parse = parse
    }

    /// 业务作用：冷启动和运行中使用同一资源总容量，单份合法文件不能绕过目录总量限制。
    /// 参数说明:
    /// - bytes: 新定义与其余已有定义的合计原字节数。
    /// - count: 应用后有效 XML 定义总数。
    /// 返回：最多 128 份和 16 MiB 时通过，超限保留现有资源。
    nonisolated static func requireCapacity(bytes: Int, count: Int) throws {
        guard count <= 128, bytes <= 16_777_216 else {
            throw NateError.message("同类用户语言资源最多 128 份，合计不超过 16 MiB。")
        }
    }
}

extension ApplicationController {
    /// 业务作用：冷启动按注册表语言读取独立的用户 XML，失败的来源保留原文件及可复验基线。
    /// 参数说明:
    /// - overrides: 当前独立类别的校验及存储状态。
    /// 返回：有效记录一次启用，单份损坏不影响其余语言，启动读取取消后仍可手动重新载入。
    func loadLanguageXMLOverrides<Rule: Sendable>(_ overrides: LanguageXMLOverrides<Rule>) async {
        guard let applicationSupport, let registry, !overrides.ready, !overrides.busy else {
            return
        }
        overrides.busy = true
        defer {
            overrides.busy = false
            overrides.ready = true
        }
        let store = LanguageXMLOverrideStore(directory: applicationSupport, kind: overrides.kind)
        let candidates = registry.languages.filter { $0.id != "searchResult" }.map { ($0.id, $0.name) }
        let parse = overrides.parse
        do {
            let (entries, errors) = try await readIO.readCancellable { token in
                var entries: [String: LanguageXMLOverrides<Rule>.Entry] = [:]
                var errors: [String] = []
                var count = 0
                var bytes = 0
                for (language, name) in candidates {
                    try token.check()
                    var baseline: DiskBaseline?
                    do {
                        let permit: @Sendable () -> Bool = { !token.isCancelled }
                        guard let disk = try store.load(language: language, permit: permit) else {
                            continue
                        }
                        baseline = disk.baseline
                        if let xml = disk.xml {
                            try LanguageXMLOverrides<Rule>.requireCapacity(
                                bytes: bytes + xml.count,
                                count: count + 1
                            )
                            let definition = try parse(xml, permit)
                            entries[language] = .init(xml: xml, definition: definition, baseline: baseline)
                            count += 1
                            bytes += xml.count
                        }
                        else {
                            entries[language] = .init(xml: nil, definition: nil, baseline: baseline)
                        }
                    }
                    catch is CancellationError {
                        throw CancellationError()
                    }
                    catch {
                        if let baseline {
                            // 已知损坏文件的原基线只允许用户明确替换这一份，后续磁盘改写仍撤销该资格。
                            entries[language] = .init(
                                xml: nil,
                                definition: nil,
                                baseline: baseline,
                                diagnostic: error.localizedDescription
                            )
                        }
                        if errors.count < 12 {
                            errors.append(name + "：" + error.localizedDescription)
                        }
                    }
                }
                return (entries, errors)
            }
            try Task.checkCancellation()
            guard !closing, self.applicationSupport == applicationSupport else {
                return
            }
            overrides.entries = entries
            if !errors.isEmpty {
                SystemIntegration.alert("部分用户\(overrides.label)未载入", errors.joined(separator: "\n"))
            }
        }
        catch is CancellationError {}
        catch {
            SystemIntegration.alert("用户\(overrides.label)未载入", error.localizedDescription)
        }
    }

    /// 业务作用：重新载入与表单保存分别确认来源，规则、基线和代次同步发布，迟到操作无权改写当前语言。
    /// 参数说明:
    /// - overrides: 当前独立类别的规则状态。
    /// - language: 用户明确选择的语言标识，磁盘使用注册表原字节。
    /// - change: 重新读入或带表单代次的明确保存，保存空值为恢复随包规则。
    /// 返回：实际发布的原语言标识，磁盘改写、非法规则或失效表单保留先前有效定义。
    func applyLanguageXMLOverride<Rule: Sendable>(
        _ overrides: LanguageXMLOverrides<Rule>,
        language: String,
        change: LanguageXMLOverrides<Rule>.Change
    ) async throws -> String {
        guard let applicationSupport, let id = registry?.language(language)?.id,
            id != "searchResult", overrides.ready, !overrides.busy, !closing
        else {
            throw NateError.message("用户语言资源暂不可应用。")
        }
        let expected = overrides.entries[id]
        if case .save(_, let generation) = change, expected?.generation != generation {
            throw NateError.message("当前语言资源已经改变，请重新打开设置。")
        }
        overrides.busy = true
        defer {
            overrides.busy = false
        }
        let store = LanguageXMLOverrideStore(directory: applicationSupport, kind: overrides.kind)
        let xml: Data?
        var baseline: DiskBaseline?
        switch change {
        case .reload:
            let disk = try await readIO.readCancellable { token in
                try store.load(language: id, permit: { !token.isCancelled })
            }
            xml = disk?.xml
            baseline = disk?.baseline
        case .save(let data, _):
            xml = data
            baseline = expected?.baseline
        }
        if let xml, !(1...LanguageXMLOverrideStore.maximumXMLBytes).contains(xml.count) {
            throw NateError.message("用户语言 XML 必须为 1 字节至 1 MiB 的原始定义。")
        }
        let others = overrides.entries.filter { $0.key != id && $0.value.xml != nil }
        try LanguageXMLOverrides<Rule>.requireCapacity(
            bytes: others.values.reduce(xml?.count ?? 0) { $0 + ($1.xml?.count ?? 0) },
            count: others.count + (xml == nil ? 0 : 1)
        )
        let parse = overrides.parse
        let definition = try await readIO.readCancellable { token in
            try xml.map { try parse($0, { !token.isCancelled }) }
        }
        // 校验等待期间可能退出、离开原支持目录或删除语言，旧条件不能使尚未写盘的资源取得发布权。
        try Task.checkCancellation()
        guard !closing, self.applicationSupport == applicationSupport,
            registry?.language(id)?.id.utf8.elementsEqual(id.utf8) == true
        else {
            throw NateError.message("语言或支持目录已经改变，资源未应用。")
        }
        if case .save = change {
            let original = baseline
            baseline = try await fileIO.run {
                try store.publish(xml, language: id, expected: original)
            }
        }
        overrides.entries[id] = .init(xml: xml, definition: definition, baseline: baseline)
        return id
    }
}
