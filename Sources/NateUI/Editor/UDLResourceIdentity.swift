import CryptoKit
import Foundation
import NateSyntax

enum UDLResourceIdentity {
    /// 业务作用：矩形视觉证据包含实际生效的 UDL 字段，原 XML 相同也不能掩盖内存规则或字体样式变化。
    /// 参数说明:
    /// - definition: 当前视图实际使用的固定 UDL。
    /// - hash: 已包含字体布局、Tab 和原资源的摘要状态。
    /// 返回：按原字节和稳定字段顺序追加完整规则，不引入每次启动变化的随机身份。
    static func update(_ definition: UDLDefinition, hash: inout SHA256) {
        append("UDLEffectiveRules", hash: &hash)
        append(definition.name, hash: &hash)
        append(definition.caseIgnored ? "yes" : "no", hash: &hash)
        append(String(definition.extensions.count), hash: &hash)
        for value in definition.extensions {
            append(value, hash: &hash)
        }
        append(String(definition.prefix.count), hash: &hash)
        for value in definition.prefix.sorted() {
            append(String(value), hash: &hash)
        }
        append(String(definition.lists.count), hash: &hash)
        for key in definition.lists.keys.sorted(by: rawOrder) {
            append(key, hash: &hash)
            let values = definition.lists[key] ?? []
            append(String(values.count), hash: &hash)
            for value in values {
                append(value, hash: &hash)
            }
        }
        append(String(definition.styles.count), hash: &hash)
        for key in definition.styles.keys.sorted(by: rawOrder) {
            guard let style = definition.styles[key] else {
                continue
            }
            append(key, hash: &hash)
            append(style.name, hash: &hash)
            append(style.foreground == nil ? "none" : "some", hash: &hash)
            append(style.foreground ?? "", hash: &hash)
            append(style.background == nil ? "none" : "some", hash: &hash)
            append(style.background ?? "", hash: &hash)
            append(String(style.fontStyle), hash: &hash)
            append(String(style.nesting), hash: &hash)
        }
    }

    /// 业务作用：字段用明确 UTF-8 长度分隔，空值和相邻规则不能形成相同的串接证据。
    /// 参数说明:
    /// - value: 当前字段原文字节。
    /// - hash: 同一完整资源摘要。
    /// 返回：追加长度、分隔符和原文，不做 Unicode 归一化。
    private static func append(_ value: String, hash: inout SHA256) {
        hash.update(data: Data(String(value.utf8.count).utf8))
        hash.update(data: Data([0]))
        hash.update(data: Data(value.utf8))
    }

    /// 业务作用：资源字典的枚举顺序不参与视觉身份，规范等价的不同原字节仍维持明确顺序。
    /// 参数说明:
    /// - lhs: 左侧资源键。
    /// - rhs: 右侧资源键。
    /// 返回：按完整 UTF-8 原字节字典序比较。
    private static func rawOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
