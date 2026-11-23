import Foundation

public enum UserConfigurationJSON {
    /// 业务作用：偏好 JSON 在业务解码与差异展示前保持唯一键和有界结构，重复定义不能表达另一套配置。
    /// 参数说明:
    /// - data: 至多 1 MiB 的完整偏好 JSON 原字节。
    /// - permit: 当前完整语义校验仍有执行资格。
    /// 返回：合法 JSON、至多 64 层、16384 个键且每键至多 512 UTF-8 字节时通过，重复或超限整体拒绝。
    public static func validate(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try ConfigurationJSONInput.validate(
            data,
            maximumBytes: 1_048_576,
            maximumKeys: 16_384,
            label: "用户配置",
            permit: permit
        )
    }
}
