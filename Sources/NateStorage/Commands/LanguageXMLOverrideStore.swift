import Foundation
import NateCore

public struct LanguageXMLOverrideRead: Sendable {
    public let xml: Data?
    public let baseline: DiskBaseline
}

public struct LanguageXMLOverrideStore: Sendable {
    public enum Kind: Sendable, Equatable {
        case completion
        case functionList
    }

    public static let maximumXMLBytes = 1_048_576
    private let bundled: Data
    private let prefix: String
    private let directory: URL
    private let storage: RecoveryStore

    /// 业务作用：不同语言 XML 资源使用独立的固定路径，导入文件名和语言显示名称不能指定写入位置。
    /// 参数说明:
    /// - directory: 应用已建立的支持目录。
    /// - kind: 资源类别，决定实际存储命名和恢复随包记录的格式。
    /// 返回：固定父级、保持原末级并逐次拒绝改向的存储。
    public init(directory: URL, kind: Kind) {
        switch kind {
        case .completion:
            prefix = "completion-"
            bundled = Data("NATE COMPLETION USE BUNDLED\n".utf8)
        case .functionList:
            prefix = "function-list-"
            bundled = Data("NATE FUNCTION LIST USE BUNDLED\n".utf8)
        }
        do {
            try FileStorage.validateFileURL(directory)
            self.directory = directory.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        }
        catch {
            self.directory = directory
        }
        storage = RecoveryStore(directory: self.directory)
    }

    /// 业务作用：读取完整用户 XML 和同次磁盘证据，恢复随包规则的记录与真正缺失区别处理。
    /// 参数说明:
    /// - language: 当前注册表中确切的语言标识。
    /// - permit: 本轮读取继续有效的资格。
    /// 返回：原字节和基线，真正缺失为空；链接、容量或读取失败向上传递。
    public func load(
        language: String,
        permit: @Sendable () -> Bool = { true }
    ) throws -> LanguageXMLOverrideRead? {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        let target = try location(for: language)
        guard try storage.recoveryFileExists(target) else {
            return nil
        }
        let current = try storage.readRecoveryFile(target, maximumBytes: Self.maximumXMLBytes, permit: permit)
        return LanguageXMLOverrideRead(
            xml: current.data == bundled ? nil : current.data,
            baseline: current.baseline
        )
    }

    /// 业务作用：经过业务校验的用户 XML 或恢复随包的决定原子持久化，留存磁盘外部改写证据。
    /// 参数说明:
    /// - xml: 已完整校验的用户 XML，空值表示切回随包定义。
    /// - language: 本次明确编辑的语言标识。
    /// - expected: 表单开始时确认的原磁盘基线，空值要求资源确实缺失。
    /// - permit: 存储发布仍有效的资格。
    /// 返回：实际已持久化的基线；外部冲突、改向、取消或失败时不授予成功。
    public func publish(
        _ xml: Data?,
        language: String,
        expected: DiskBaseline?,
        permit: @Sendable () -> Bool = { true }
    ) throws -> DiskBaseline {
        if let xml {
            guard !xml.isEmpty, xml.count <= Self.maximumXMLBytes, xml != bundled else {
                throw NateError.message("用户语言 XML 必须为 1 字节至 1 MiB 的原始定义。")
            }
        }
        let target = try location(for: language)
        let current = try load(language: language, permit: permit)
        // 永远用原表单已确认的基线写盘，重新读取只用于撤销旧权限，不能替旧表单授予覆盖资格。
        guard current?.baseline == expected else {
            throw NateError.message("用户语言资源已在磁盘上改变，请重新载入。")
        }
        if let current, current.xml == xml {
            return current.baseline
        }
        return try FileStorage.save(
            xml ?? bundled,
            to: target,
            expected: expected,
            resolvingDirectoryLinks: false,
            permit: permit
        )
    }

    /// 业务作用：每个确切语言标识映射到支持目录内的唯一固定文件，注册表文字不会作为路径段。
    /// 参数说明:
    /// - language: 语言的稳定原标识。
    /// 返回：已确认位于无链接目标目录的完整路径；标识或目录无效时拒绝。
    private func location(for language: String) throws -> URL {
        guard !language.isEmpty, language.utf8.count <= 4096, !language.utf8.contains(0) else {
            throw NateError.message("用户语言资源的语言标识无效。")
        }
        let digest = FileStorage.digest(Data(language.utf8))
        let target = directory.appendingPathComponent(prefix + digest + ".resource")
        _ = try storage.recoveryParent(target)
        return target
    }
}
