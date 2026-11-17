import Foundation
import NateCore

struct LegacyCodePage: Sendable {
    let decoded: [UInt32: UInt32]
    let encoded: [UInt32: UInt32]
}

public struct LegacyCodecCatalog: Sendable {
    private let tables: [UInt32: LegacyCodePage]

    /// 业务作用：载入独立代码页映射，缺失系统转换器时仍有严格 Swift 后端。
    /// 参数说明:
    /// - directory: 由应用资源定位器注入的编码资源目录。
    /// 返回：不可变转换表；损坏或重复映射在发布前失败。
    public init(directory: URL) throws {
        try FileStorage.validateFileURL(directory)
        var tables: [UInt32: LegacyCodePage] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "bin" {
            guard let page = UInt32(url.deletingPathExtension().lastPathComponent) else {
                continue
            }
            let bytes = [UInt8](try Data(contentsOf: url))
            guard bytes.count >= 8, Array(bytes.prefix(4)) == Array("NCP1".utf8) else {
                throw NateError.message("编码资源头无效。")
            }
            let count = Int(Self.word(bytes, at: 4))
            guard count <= 100_000, bytes.count == 8 + count * 8 else {
                throw NateError.message("编码资源规模或长度无效。")
            }
            var decoded: [UInt32: UInt32] = [:]
            var encoded: [UInt32: UInt32] = [:]
            for i in 0..<count {
                let key = Self.word(bytes, at: 8 + i * 8)
                let value = Self.word(bytes, at: 12 + i * 8)
                let scalar = value & 0x7FFFFFFF
                guard Unicode.Scalar(scalar) != nil, key >> 24 == 1 || key >> 24 == 2,
                    decoded.updateValue(scalar, forKey: key) == nil
                else {
                    throw NateError.message("编码资源包含非法或重复映射。")
                }
                if value & 0x80000000 != 0 {
                    encoded[scalar] = key
                }
            }
            tables[page] = LegacyCodePage(decoded: decoded, encoded: encoded)
        }
        self.tables = tables
    }

    /// 业务作用：逐字节严格解释明确代码页，不将截断双字节当替代字符。
    /// 参数说明:
    /// - data: 原始文件字节。
    /// - page: 明确的 Windows 代码页。
    /// 返回：表内代码页的解码结果；无该代码页时为空。
    public func decode(_ data: Data, page: UInt32) throws -> String? {
        guard let table = tables[page] else {
            return nil
        }
        let bytes = [UInt8](data)
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let single = UInt32(1 << 24) | UInt32(bytes[i])
            var value = table.decoded[single]
            if value != nil {
                i += 1
            }
            else if i + 1 < bytes.count {
                let double = UInt32(2 << 24) | UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
                value = table.decoded[double]
                i += 2
            }
            guard let value, let scalar = Unicode.Scalar(value) else {
                throw NateError.message("CP\(page) 在字节 \(i) 处包含非法或截断序列。")
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// 业务作用：只输出能无损往返的代码页字符，拒绝近似转换。
    /// 参数说明:
    /// - text: 已提交 Unicode 正文。
    /// - page: 目标 Windows 代码页。
    /// 返回：精确字节；无表时为空，不可表示时失败。
    public func encode(_ text: String, page: UInt32) throws -> Data? {
        guard let table = tables[page] else {
            return nil
        }
        var bytes = Data()
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            guard let key = table.encoded[scalar.value] else {
                throw NateError.message(
                    "CP\(page) 无法无损表示 U+\(String(scalar.value, radix: 16, uppercase: true))。"
                )
            }
            if key >> 24 == 2 {
                bytes.append(UInt8((key >> 8) & 0xFF))
            }
            bytes.append(UInt8(key & 0xFF))
        }
        return bytes
    }

    /// 业务作用：按文件定义读取小端整数，避免未对齐内存访问。
    /// 参数说明:
    /// - bytes: 已校验长度的资源。
    /// - at: 整数字节起点。
    /// 返回：32 位资源字段。
    private static func word(_ bytes: [UInt8], at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3])
            << 24
    }
}
