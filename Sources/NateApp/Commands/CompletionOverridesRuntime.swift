import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax

@MainActor
final class CompletionOverridesRuntime {
    struct Entry: Sendable {
        let generation: UUID
        let xml: Data?
        let definition: CompletionDefinition?
        let baseline: DiskBaseline?
        let diagnostic: String?
    }

    nonisolated static let maximumEntries = 128
    nonisolated static let maximumBytes = 16_777_216
    var entries: [String: Entry] = [:]
    var ready = false
    var busy = false

    /// 业务作用：运行中的每次发布检查全部保留 XML，避免少量重复导入绕过补全目录的总容量。
    /// 参数说明:
    /// - bytes: 当前语言将要保留的完整资源字节数，切回随包时为零。
    /// - language: 本次实际更改的语言标识。
    /// 返回：新目录仍满足定义数量与总字节限制时继续，否则保留原配置。
    func requireCapacity(bytes: Int, for language: String) throws {
        let others = entries.filter { $0.key != language && $0.value.xml != nil }
        let count = others.count + (bytes > 0 ? 1 : 0)
        let total = others.values.reduce(bytes) { $0 + ($1.xml?.count ?? 0) }
        guard count <= Self.maximumEntries, total <= Self.maximumBytes else {
            throw NateError.message("用户补全最多 128 份，合计不超过 16 MiB。")
        }
    }
}

extension ApplicationController {
    /// 业务作用：冷启动从原注册表的确切语言标识读取用户规则，解析失败的单份文件继续留在磁盘。
    /// 参数说明: 无。
    /// 返回：成功的定义一次发布，损坏或超量的定义说明原因并沿用随包规则。
    func loadCompletionOverrides() async {
        guard let applicationSupport, let registry, !completionOverrides.ready else {
            return
        }
        let store = CompletionOverrideStore(directory: applicationSupport)
        let candidates = registry.languages.filter { $0.id != "searchResult" }.map { ($0.id, $0.name) }
        do {
            let (entries, errors) = try await readIO.readCancellable { token in
                var entries: [String: CompletionOverridesRuntime.Entry] = [:]
                var errors: [String] = []
                var count = 0
                var bytes = 0
                for (language, name) in candidates {
                    try token.check()
                    var baseline: DiskBaseline?
                    do {
                        guard let disk = try store.load(language: language, permit: { !token.isCancelled })
                        else {
                            continue
                        }
                        baseline = disk.baseline
                        guard let xml = disk.xml else {
                            entries[language] = CompletionOverridesRuntime.Entry(
                                generation: UUID(),
                                xml: nil,
                                definition: nil,
                                baseline: baseline,
                                diagnostic: nil
                            )
                            continue
                        }
                        guard count < CompletionOverridesRuntime.maximumEntries,
                            xml.count <= CompletionOverridesRuntime.maximumBytes - bytes
                        else {
                            throw NateError.message("用户补全目录超过 128 份或 16 MiB。")
                        }
                        let definition = try CompletionDefinition(importing: xml)
                        entries[language] = CompletionOverridesRuntime.Entry(
                            generation: UUID(),
                            xml: xml,
                            definition: definition,
                            baseline: baseline,
                            diagnostic: nil
                        )
                        count += 1
                        bytes += xml.count
                    }
                    catch is CancellationError {
                        throw CancellationError()
                    }
                    catch {
                        if let baseline {
                            // 原文件虽不可使用，仍保留同次证据，只有用户明确操作才能覆盖这一份。
                            entries[language] = CompletionOverridesRuntime.Entry(
                                generation: UUID(),
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
            completionOverrides.entries = entries
            completionOverrides.ready = true
            if !errors.isEmpty {
                SystemIntegration.alert("部分用户补全未载入", errors.joined(separator: "\n"))
            }
        }
        catch {
            SystemIntegration.alert("用户补全未载入", error.localizedDescription)
        }
    }

    /// 业务作用：读取用户明确指定的当前语言资源，成功前不撤销现有候选或磁盘证据。
    /// 参数说明:
    /// - language: 已明确选中的注册表语言标识。
    /// 返回：完整校验后采用同一份原字节及基线，失败继续保留当前规则。
    func reloadCompletionOverride(language: String) async throws {
        guard let applicationSupport, let id = registry?.language(language)?.id,
            completionOverrides.ready, !completionOverrides.busy, !closing
        else {
            throw NateError.message("用户补全资源暂不可重新载入。")
        }
        completionOverrides.busy = true
        defer {
            completionOverrides.busy = false
        }
        let store = CompletionOverrideStore(directory: applicationSupport)
        let disk = try await readIO.readCancellable { token in
            try store.load(language: id, permit: { !token.isCancelled })
        }
        try completionOverrides.requireCapacity(bytes: disk?.xml?.count ?? 0, for: id)
        let definition = try await fileIO.run {
            try disk?.xml.map { try CompletionDefinition(importing: $0) }
        }
        try Task.checkCancellation()
        guard !closing, registry?.language(id)?.id.utf8.elementsEqual(id.utf8) == true else {
            throw NateError.message("语言已离开当前注册表，补全资源未发布。")
        }
        publishCompletionOverride(id, xml: disk?.xml, definition: definition, baseline: disk?.baseline)
    }

    /// 业务作用：旧表单只拥有确切语言及原记录的写入资格，外部文件更新和重新载入都撤销它。
    /// 参数说明:
    /// - xml: 完整用户 XML，空值明确表示切回随包规则。
    /// - language: 表单明确标示的语言。
    /// - generation: 创建表单时固定的用户资源代次。
    /// 返回：事先校验的完整规则在可靠写入后发布；失败时仍使用当前有效定义。
    func saveCompletionOverride(_ xml: Data?, language: String, generation: UUID?) async throws {
        guard let applicationSupport, let id = registry?.language(language)?.id,
            completionOverrides.ready, !completionOverrides.busy, !closing,
            completionOverrides.entries[id]?.generation == generation
        else {
            throw NateError.message("用户补全资源已经改变或正在使用，请重新打开设置。")
        }
        completionOverrides.busy = true
        defer {
            completionOverrides.busy = false
        }
        let store = CompletionOverrideStore(directory: applicationSupport)
        let expected = completionOverrides.entries[id]?.baseline
        if let xml, !(1...CompletionOverrideStore.maximumXMLBytes).contains(xml.count) {
            throw NateError.message("用户补全 XML 必须为 1 字节至 1 MiB。")
        }
        try completionOverrides.requireCapacity(bytes: xml?.count ?? 0, for: id)
        let definition = try await fileIO.run {
            try xml.map { try CompletionDefinition(importing: $0) }
        }
        // 等待 XML 校验时可能退出或删除语言，持久化前再次确认本次明确发布的对象。
        try Task.checkCancellation()
        guard !closing, registry?.language(id)?.id.utf8.elementsEqual(id.utf8) == true else {
            throw NateError.message("语言已离开当前注册表，磁盘补全资源未改动。")
        }
        let baseline = try await fileIO.run {
            try store.publish(xml, language: id, expected: expected)
        }
        publishCompletionOverride(id, xml: xml, definition: definition, baseline: baseline)
    }

    /// 业务作用：完成当前资源代次发布后撤销旧候选，已经显示的旧文本不能用于确认替换。
    /// 参数说明:
    /// - language: 规则的确切语言标识。
    /// - xml: 本次已经验证的原字节；空值恢复随包规则。
    /// - definition: 与本次原字节一起确认的不可变补全定义。
    /// - baseline: 持久化后或重新读取确认的磁盘基线。
    /// 返回：内存资源与基线同步更新，旧候选和旧表单不再拥有发布资格。
    private func publishCompletionOverride(
        _ language: String,
        xml: Data?,
        definition: CompletionDefinition?,
        baseline: DiskBaseline?
    ) {
        completionOverrides.entries[language] = CompletionOverridesRuntime.Entry(
            generation: UUID(),
            xml: xml,
            definition: definition,
            baseline: baseline,
            diagnostic: nil
        )
        cancelCompletion()
    }
}
