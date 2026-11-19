import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage

enum TextTools {
    /// 业务作用：执行明确的文本与字节转换，非法输入在事务提交前失败。
    /// 参数说明:
    /// - name: 工具标识。
    /// - text: 固定输入，按 UTF-8 字节解释。
    /// 返回：完整转换或摘要，不修改源文件。
    static func transform(_ name: String, text: String) throws -> String {
        if let algorithm = DigestAlgorithm(rawValue: name) {
            return try TextDigests.values(text: PieceTree(text)).value(for: algorithm)
        }
        let data = Data(text.utf8)
        if let operation = MIMEOperation(rawValue: name) {
            let result = try MIMECodec.transform(operation, data: data)
            guard
                let value = String(
                    data: result,
                    encoding: .utf8
                )
            else {
                throw NateError.message("解码结果是非 UTF-8 字节，必须通过独立字节结果查看与导出。")
            }
            return value
        }
        switch name {
        case "json":
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return String(
                decoding: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
                ),
                as: UTF8.self
            )
        case "xml":
            guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
                !text.localizedCaseInsensitiveContains("<!ENTITY"), data.count <= 16_777_216
            else {
                throw NateError.message("XML 不允许 DTD、实体声明或超过 16 MB 的格式化输入。")
            }
            let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            return document.xmlString(options: [.nodePrettyPrint])
        case "hexEncode":
            return String(decoding: try HexCodec.encode(data), as: UTF8.self)
        case "hexDecode":
            guard let result = String(data: try HexCodec.decode(data), encoding: .utf8) else {
                throw NateError.message("HEX 结果不是合法 UTF-8 文本，源内容保持不变。")
            }
            return result
        default: throw NateError.message("未知文本工具。")
        }
    }
}
