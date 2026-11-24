import Foundation
import NateCore
import NateStorage
import NateSyntax

struct UserFunctionListAssociations: Sendable {
    struct Archive: Codable, Sendable {
        let map: Data
        let rules: [String: Data]
    }

    let archive: Archive
    let associations: FunctionListAssociations
    private let rules: [String: PreparedFunctionList]
    private static let maximumRuleBytes = 16 * 1_048_576

    /// 业务作用：整组关联和持久化依赖先完成安全解析，任何一项失败都不得替换旧关联。
    /// 参数说明:
    /// - archive: 关联及本次持久化的原始规则字节。
    /// - bundled: 当前应用随包解析资源，作为没有同层文件的显式关联目标。
    /// - permit: 当前读取及校验仍有效的资格。
    /// 返回：完整的活动关联和预编译用户规则；任一缺失、超量或非法引用均失败。
    init(
        _ archive: Archive,
        bundled: FunctionListCatalog?,
        permit: @escaping @Sendable () -> Bool
    ) throws {
        let maximum = LanguageXMLOverrideStore.maximumXMLBytes
        guard (1...maximum).contains(archive.map.count), archive.rules.count <= 128,
            archive.rules.values.reduce(0, { $0 + $1.count }) <= Self.maximumRuleBytes
        else {
            throw NateError.message("关联 XML 最多 1 MiB，关联规则最多 128 份、合计 16 MiB。")
        }
        let associations = try FunctionListAssociations(data: archive.map)
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        let canCompile: @Sendable () -> Bool = { permit() && ContinuousClock.now < deadline }
        var rules: [String: PreparedFunctionList] = [:]
        var seen: Set<String> = []
        for (filename, data) in archive.rules.sorted(by: { $0.key < $1.key }) {
            guard (1...maximum).contains(data.count),
                let key = FunctionListAssociations.ruleKey(forFilename: filename), seen.insert(key).inserted
            else {
                throw NateError.message("函数列表关联归档包含无效、重复或超量的规则文件。")
            }
            // 原字节相同的完整随包定义仍使用随包规则权限，任何改写都按独立用户规则校验。
            if bundled?.definitions[key]?.originalXML == data {
                continue
            }
            do {
                rules[key] = try PreparedFunctionList(FunctionListDefinition(data: data), permit: canCompile)
            }
            catch is CancellationError where permit() && ContinuousClock.now >= deadline {
                throw NateError.message("函数列表关联超过整组规则的 12 秒校验预算。")
            }
            catch is CancellationError {
                throw CancellationError()
            }
            catch {
                throw NateError.message(filename + "：" + error.localizedDescription)
            }
        }
        for (key, filename) in associations.ruleFilenames
        where rules[key] == nil && bundled?.definitions[key] == nil {
            throw NateError.message("函数列表关联缺少规则文件 " + filename + "。")
        }
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        self.archive = archive
        self.associations = associations
        self.rules = rules
    }

    /// 业务作用：启动和重载都重新核对整个归档与当前随包资源的匹配关系。
    /// 参数说明:
    /// - data: 已安全读取的完整磁盘归档。
    /// - bundled: 这次恢复使用的实际随包目录。
    /// - permit: 读取与规则准备的当前资格。
    /// 返回：与当前资源兼容的完整关联状态，损坏归档不产生部分结果。
    static func restoring(
        _ data: Data,
        bundled: FunctionListCatalog?,
        permit: @escaping @Sendable () -> Bool
    ) throws -> Self {
        let archive: Archive
        do {
            archive = try PropertyListDecoder().decode(Archive.self, from: data)
        }
        catch {
            throw NateError.message("函数列表关联归档格式无效。")
        }
        return try Self(archive, bundled: bundled, permit: permit)
    }

    /// 业务作用：只从关联同层读取实际引用的规则，缺席文件可使用相同名称的随包定义。
    /// 参数说明:
    /// - url: 用户实际选择的关联文件。
    /// - bundled: 可复用的同名随包定义。
    /// - permit: 本轮输入文件访问与解析资格。
    /// 返回：同一来源的原 XML 与依赖经过共同预算及两次身份核对后，交付整组已验证关联。
    static func importing(
        _ url: URL,
        bundled: FunctionListCatalog?,
        permit: @escaping @Sendable () -> Bool
    ) throws -> Self {
        try FileStorage.validateFileURL(url)
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let mapURL = directory.appendingPathComponent(url.lastPathComponent)
        let maximum = LanguageXMLOverrideStore.maximumXMLBytes
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let directoryStamp = try DirectoryContents.observe(
            root: root,
            directory: directory,
            permit: permit
        )
        guard
            let map = try FunctionListAssociationStore.readImportXML(
                mapURL,
                in: directory,
                matching: directoryStamp,
                maximumBytes: maximum,
                permit: permit
            ), !map.data.isEmpty
        else {
            throw NateError.message("所选 overrideMap.xml 不存在或为空。")
        }
        let associations = try FunctionListAssociations(data: map.data)
        var rules: [String: Data] = [:]
        var evidence: [(URL, DiskBaseline?)] = [(mapURL, map.baseline)]
        var remaining = maximumRuleBytes
        for (_, filename) in associations.ruleFilenames.sorted(by: { $0.key < $1.key }) {
            let leaf = directory.appendingPathComponent(filename)
            let rule = try FunctionListAssociationStore.readImportXML(
                leaf,
                in: directory,
                matching: directoryStamp,
                maximumBytes: min(remaining, maximum),
                permit: permit
            )
            if let rule {
                remaining -= rule.data.count
                rules[filename] = rule.data
            }
            evidence.append((leaf, rule?.baseline))
        }
        // 关联和依赖必须来自同一个稳定目录。分次读取后复验每一份及真正缺席的路径，避免串用两个发布批次。
        for (leaf, expected) in evidence {
            let current = try FunctionListAssociationStore.readImportXML(
                leaf,
                in: directory,
                matching: directoryStamp,
                maximumBytes: maximum,
                collectBytes: false,
                permit: permit
            )
            guard current?.baseline == expected else {
                throw NateError.message("导入过程中函数列表 XML 已改变，请重新选择。")
            }
        }
        guard
            directoryStamp
                == (try DirectoryContents.observe(root: root, directory: directory, permit: permit))
        else {
            throw NateError.message("导入过程中函数列表目录已改变，请重新选择。")
        }
        return try Self(Archive(map: map.data, rules: rules), bundled: bundled, permit: permit)
    }

    /// 业务作用：返回实际覆盖到语言的原定义和已编译规则，随包规则沿用自己的来源权限。
    /// 参数说明:
    /// - language: 当前实际内置语言或 UDL 标识。
    /// - bundled: 当前随包目录，用作关联可见的内置规则。
    /// 返回：有映射时给出对应定义；仅同层用户规则附带预编译执行树。
    func resolution(
        for language: String,
        bundled: FunctionListCatalog?
    ) -> (definition: FunctionListDefinition, prepared: PreparedFunctionList?)? {
        guard let key = associations.ruleKey(for: language) else {
            return nil
        }
        if let prepared = rules[key] {
            return (prepared.definition, prepared)
        }
        return bundled?.definitions[key].map {
            ($0, nil)
        }
    }
}
