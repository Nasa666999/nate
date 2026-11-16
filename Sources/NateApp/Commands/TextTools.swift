import AppKit
import CryptoKit
import Foundation
import NateCore
import NatePlatform

enum TextTools {
    /// 业务作用：执行明确的文本与字节转换，非法输入在事务提交前失败。
    /// 参数说明:
    /// - name: 工具标识。
    /// - text: 固定输入，按 UTF-8 字节解释。
    /// 返回：完整转换或摘要，不修改源文件。
    static func transform(_ name: String, text: String) throws -> String {
        let data = Data(text.utf8)
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
        case "base64Encode": return data.base64EncodedString()
        case "base64Decode":
            let normalized = text.filter {
                !$0.isWhitespace
            }
            guard let decoded = Data(base64Encoded: normalized),
                let value = String(data: decoded, encoding: .utf8)
            else {
                throw NateError.message("不是合法 Base64 或解码结果不是 UTF-8 文本。")
            }
            return value
        case "urlEncode":
            let safe = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
            )
            guard let result = text.addingPercentEncoding(withAllowedCharacters: safe) else {
                throw NateError.invalidText
            }
            return result
        case "urlDecode":
            guard let result = text.removingPercentEncoding else {
                throw NateError.message("URL 转义序列无效。")
            }
            return result
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
    /// 业务作用：后台转换固定快照，迟到结果不能覆盖新的用户输入。
    /// 参数说明:
    /// - name: 具体工具。
    /// 返回：摘要复制到剪贴板，其余转换以一次事务应用到原范围。
    func runTextTool(_ name: String) {
        guard let active else {
            return
        }
        let snapshot = active.buffer.snapshot
        let range =
            active.buffer.selections.first.flatMap {
                $0.range.isEmpty ? nil : $0.range
            }
            ?? ByteRange(0, snapshot.text.byteCount)
        Task {
            do {
                let result = try await Task.detached {
                    try TextTools.transform(name, text: snapshot.text.text(in: range))
                }.value
                if ["md5", "sha1", "sha256", "sha512"].contains(name) {
                    SystemIntegration.copy(result)
                    mainWindow?.showResults("\(name.uppercased()) · UTF-8 原换行 · 已复制\n\(result)")
                }
                else {
                    try active.buffer.commit(
                        [TextEdit(range, result)],
                        expectedRevision: snapshot.revision,
                        name: name
                    )
                    mainWindow?.editor.refresh()
                    didEdit()
                }
            }
            catch {
                SystemIntegration.alert("转换失败", error.localizedDescription)
            }
        }
    }

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
