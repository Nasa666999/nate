import AppKit
import CryptoKit
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
            return data.map {
                String(format: "%02X", $0)
            }.joined(separator: " ")
        case "hexDecode":
            let values = Array(
                text.filter {
                    !$0.isWhitespace
                }
            )
            guard values.count.isMultiple(of: 2) else {
                throw NateError.message("HEX 必须包含成对十六进制数字。")
            }
            var bytes: [UInt8] = []
            for i in stride(from: 0, to: values.count, by: 2) {
                guard let byte = UInt8(String(values[i...i + 1]), radix: 16) else {
                    throw NateError.message("HEX 包含非法数字。")
                }
                bytes.append(byte)
            }
            guard let result = String(bytes: bytes, encoding: .utf8) else {
                throw NateError.message("HEX 结果不是合法 UTF-8 文本，源内容保持不变。")
            }
            return result
        case "md5":
            return Insecure.MD5.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        case "sha1":
            return Insecure.SHA1.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        case "sha256":
            return SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        case "sha512":
            return SHA512.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        default: throw NateError.message("未知文本工具。")
        }
    }
}

extension ApplicationController {
    /// 业务作用：查看 Unicode 标量的字符与进制表示，不猜测多字符为单字节。
    /// 参数说明: 无。
    /// 返回：显示输入文本每个标量的十进制、十六进制、八进制和二进制值。
    func characterConverter() {
        guard let text = SystemIntegration.prompt("字符与进制转换", "输入字符，或 U+十六进制标量码点", initial: "A") else {
            return
        }
        let decoded: String
        if text.hasPrefix("U+"), let number = UInt32(text.dropFirst(2), radix: 16),
            let scalar = Unicode.Scalar(number)
        {
            decoded = String(scalar)
        }
        else {
            decoded = text
        }
        let rows = decoded.unicodeScalars.map {
            "\($0)   十进制 \($0.value)   U+\(String($0.value, radix: 16, uppercase: true))   八进制 \(String($0.value, radix: 8))   二进制 \(String($0.value, radix: 2))"
        }
        mainWindow?.showResults(rows.joined(separator: "\n"))
    }
}
