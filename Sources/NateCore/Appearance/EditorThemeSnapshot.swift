import CryptoKit
import Foundation

public struct EditorThemeSnapshot: Sendable, Equatable {
    public let definition: EditorThemeDefinition
    public let identity: String
    public let encoded: Data

    /// 业务作用：主题在进入视图前固定完整归档与跨重启身份，容量不足的定义不能改变布局权限。
    /// 参数说明:
    /// - definition: 单项字段已经校验的完整主题定义。
    /// - permit: 当前解析或应用意图仍具有执行资格。
    /// 返回：编码和摘要全部完成的不可变主题；超量或取消时不发布半份配置。
    public init(
        _ definition: EditorThemeDefinition,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let data = try EditorThemeCodec.encode(definition, permit: permit)
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        try Task.checkCancellation()
        guard permit() else {
            throw NateError.message("主题应用资格已经改变，未发布新身份。")
        }
        self.definition = definition
        identity = digest
        encoded = data
    }
}
