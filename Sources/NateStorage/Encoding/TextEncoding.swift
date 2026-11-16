import CoreFoundation
import Foundation
import NateCore

public struct TextEncoding: Sendable, Codable, Equatable, Hashable {
    public var codePage: UInt32
    public var bom: Bool
    public var name: String
    public static let utf8 = TextEncoding(codePage: 65001, bom: false, name: "UTF-8")

    /// 业务作用：明确文件代码页和 BOM，避免含糊的系统默认 ANSI。
    /// 参数说明:
    /// - codePage: Windows 代码页编号。
    /// - bom: 是否输出该 Unicode 编码的前导标记。
    /// - name: 用户可见名称。
    /// 返回：可随保存请求固定的编码参数。
    public init(codePage: UInt32, bom: Bool = false, name: String) {
        self.codePage = codePage
        self.bom = bom
        self.name = name
    }

    public static let available: [TextEncoding] = {
        var values: [TextEncoding] = [
            .utf8, .init(codePage: 65001, bom: true, name: "UTF-8 BOM"),
            .init(codePage: 1200, bom: true, name: "UTF-16 LE BOM"),
            .init(codePage: 1201, bom: true, name: "UTF-16 BE BOM"),
            .init(codePage: 1252, name: "ANSI · Windows-1252"),
            .init(codePage: 936, name: "GB2312 · CP936 / GBK"),
            .init(codePage: 950, name: "Big5 · CP950"),
            .init(codePage: 932, name: "Shift-JIS · CP932"),
            .init(codePage: 949, name: "Windows 949"),
            .init(codePage: 51949, name: "EUC-KR · CP51949"),
            .init(codePage: 54936, name: "GB18030"),
            .init(codePage: 874, name: "TIS-620 · CP874"),
            .init(codePage: 10007, name: "Mac Cyrillic · CP10007"),
        ]
        for code in [720, 775, 855, 866, 852, 737, 869, 862, 861, 865, 857, 850, 858, 860, 863, 437] {
            values.append(TextEncoding(codePage: UInt32(code), name: "OEM \(code)"))
        }
        for code in 1250...1258 where code != 1252 {
            values.append(TextEncoding(codePage: UInt32(code), name: "Windows-\(code)"))
        }
        for code in [1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15] {
            values.append(TextEncoding(codePage: UInt32(28590 + code), name: "ISO 8859-\(code)"))
        }
        values.append(TextEncoding(codePage: 20866, name: "KOI8-R"))
        values.append(TextEncoding(codePage: 21866, name: "KOI8-U"))
        return values
    }()

    var cfEncoding: CFStringEncoding {
        if codePage == 65001 {
            return CFStringBuiltInEncodings.UTF8.rawValue
        }
        if codePage == 1200 {
            return CFStringBuiltInEncodings.UTF16LE.rawValue
        }
        if codePage == 1201 {
            return CFStringBuiltInEncodings.UTF16BE.rawValue
        }
        if codePage == 54936 {
            return CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        }
        if codePage == 51949 {
            return CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        }
        return CFStringConvertWindowsCodepageToEncoding(codePage)
    }

    /// 业务作用：严格解码原字节，不以替代字符掩盖非法序列。
    /// 参数说明:
    /// - data: 不包含前导 BOM 的源字节。
    /// 返回：合法正文；无法无损解释时明确失败。
    public func decode(_ data: Data) throws -> String {
        if codePage == 65001 {
            guard let text = String(data: data, encoding: .utf8) else {
                throw NateError.invalidText
            }
            return text
        }
        guard cfEncoding != kCFStringEncodingInvalidId else {
            throw NateError.message("系统没有 \(name) 的严格转换器。")
        }
        let decoded: CFString? = data.withUnsafeBytes {
            bytes in
            CFStringCreateWithBytes(
                nil,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                cfEncoding,
                false
            )
        }
        guard let decoded else {
            throw NateError.message("源字节不是合法的 \(name)，原文件保持不变。")
        }
        return decoded as String
    }

    /// 业务作用：在触碰目标文件之前完成严格编码，不能输出问号或近似字符。
    /// 参数说明:
    /// - text: 已提交的正文快照。
    /// 返回：包含所选 BOM 的完整文件字节；不可表示时失败。
    public func encode(_ text: String) throws -> Data {
        let value = text as CFString
        let length = CFStringGetLength(value)
        var used = 0
        let converted = CFStringGetBytes(
            value,
            CFRange(location: 0, length: length),
            cfEncoding,
            0,
            false,
            nil,
            0,
            &used
        )
        guard converted == length else {
            throw NateError.message("正文包含 \(name) 无法表示的字符，请转换为 UTF-8。")
        }
        var output = [UInt8](repeating: 0, count: used)
        let written = CFStringGetBytes(
            value,
            CFRange(location: 0, length: length),
            cfEncoding,
            0,
            false,
            &output,
            used,
            &used
        )
        guard written == length else {
            throw NateError.message("编码过程未能完整输出正文。")
        }
        var result = Data()
        if bom {
            if codePage == 65001 {
                result.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            if codePage == 1200 {
                result.append(contentsOf: [0xFF, 0xFE])
            }
            if codePage == 1201 {
                result.append(contentsOf: [0xFE, 0xFF])
            }
        }
        result.append(contentsOf: output)
        return result
    }

    /// 业务作用：优先识别 BOM，其次严格 UTF-8；传统编码必须保持推断标识。
    /// 参数说明:
    /// - data: 完整原文件字节。
    /// - explicit: 用户指定的代码页，优先于推断。
    /// 返回：正文、实际编码和是否为推断的标记。
    public static func detect(_ data: Data, explicit: TextEncoding? = nil) throws -> (
        String, TextEncoding, Bool
    ) {
        var encoding = explicit ?? .utf8
        var skip = 0
        if data.starts(with: [0xEF, 0xBB, 0xBF]) && (explicit == nil || explicit?.codePage == 65001) {
            encoding = .init(codePage: 65001, bom: true, name: "UTF-8 BOM")
            skip = 3
        }
        else if data.starts(with: [0xFF, 0xFE]) && (explicit == nil || explicit?.codePage == 1200) {
            encoding = .init(codePage: 1200, bom: true, name: "UTF-16 LE BOM")
            skip = 2
        }
        else if data.starts(with: [0xFE, 0xFF]) && (explicit == nil || explicit?.codePage == 1201) {
            encoding = .init(codePage: 1201, bom: true, name: "UTF-16 BE BOM")
            skip = 2
        }
        let content = Data(data.dropFirst(skip))
        return (try encoding.decode(content), encoding, explicit == nil && skip == 0)
    }
}
