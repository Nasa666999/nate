import Foundation

public typealias CompletionOverrideRead = LanguageXMLOverrideRead

public struct CompletionOverrideStore: Sendable {
    public static let maximumXMLBytes = LanguageXMLOverrideStore.maximumXMLBytes
    private let storage: LanguageXMLOverrideStore

    /// 业务作用：补全继续使用原有磁盘命名和恢复标记，升级无需搬动已保存的定义。
    /// 参数说明:
    /// - directory: 当前应用支持目录。
    /// 返回：独立于其它语言资源的补全存储。
    public init(directory: URL) {
        storage = LanguageXMLOverrideStore(directory: directory, kind: .completion)
    }

    /// 业务作用：读取当前语言原字节及磁盘基线，供表单重新载入。
    /// 参数说明:
    /// - language: 注册表实际语言标识。
    /// - permit: 继续读取的资格。
    /// 返回：现有记录的完整证据；真正缺失为空，读取失败向上传递。
    public func load(
        language: String,
        permit: @Sendable () -> Bool = { true }
    ) throws -> CompletionOverrideRead? {
        try storage.load(language: language, permit: permit)
    }

    /// 业务作用：从当前磁盘基线原子发布用户定义或恢复标记。
    /// 参数说明:
    /// - xml: 通过校验的完整 XML，空值表示恢复随包补全。
    /// - language: 表单确切绑定的语言标识。
    /// - expected: 发布前确认的原磁盘基线。
    /// - permit: 继续持久化的资格。
    /// 返回：已发布记录的新基线，磁盘冲突及取消向上传递。
    public func publish(
        _ xml: Data?,
        language: String,
        expected: DiskBaseline?,
        permit: @Sendable () -> Bool = { true }
    ) throws -> DiskBaseline {
        try storage.publish(xml, language: language, expected: expected, permit: permit)
    }
}
