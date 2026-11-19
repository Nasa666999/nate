import CryptoKit
import Foundation
import NateCore

public enum DigestAlgorithm: String, Sendable, CaseIterable, Codable {
    case md5
    case sha1
    case sha256
    case sha512

    /// 业务作用：以明确算法名称区分摘要结果，不把兼容摘要当作身份认证。
    /// 参数说明: 无。
    /// 返回：实际 MD5 或 SHA 算法的展示名称。
    public var title: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }
}

public struct DigestValues: Sendable, Equatable {
    public let md5: String
    public let sha1: String
    public let sha256: String
    public let sha512: String

    /// 业务作用：同一原字节快照可切换算法显示，不为切换菜单重新读取已经改变的来源。
    /// 参数说明:
    /// - algorithm: 用户明确选择的实际算法。
    /// 返回：对应快照的小写十六进制完整摘要。
    public func value(for algorithm: DigestAlgorithm) -> String {
        switch algorithm {
        case .md5: return md5
        case .sha1: return sha1
        case .sha256: return sha256
        case .sha512: return sha512
        }
    }
}

struct DigestAccumulator {
    var md5 = Insecure.MD5()
    var sha1 = Insecure.SHA1()
    var sha256: SHA256?
    var sha512 = SHA512()

    /// 业务作用：一次流式读取计算全部摘要，文件已有同流 SHA-256 基线时复用其完整证据。
    /// 参数说明:
    /// - includeSHA256: 是否由本累积器独立维护 SHA-256。
    /// 返回：尚未消费原字节的完整算法状态。
    init(includeSHA256: Bool) {
        sha256 = includeSHA256 ? SHA256() : nil
    }

    /// 业务作用：各算法接收同一完整原字节块，NUL、BOM 和换行不会被重新解释或标准化。
    /// 参数说明:
    /// - bytes: 只在本次同步调用期间有效的原字节。
    /// 返回：全部已启用算法同步推进，不持有块内指针。
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        md5.update(bufferPointer: bytes)
        sha1.update(bufferPointer: bytes)
        sha256?.update(bufferPointer: bytes)
        sha512.update(bufferPointer: bytes)
    }

    /// 业务作用：完整来源验证后才生成全部结果，文件 SHA-256 只能取同一描述符的实际基线。
    /// 参数说明:
    /// - fileSHA256: 文件读取已经完整确认的 SHA-256；文本路径省略。
    /// 返回：完整摘要集合；没有任何同流 SHA-256 来源时失败。
    mutating func finalize(fileSHA256: String? = nil) throws -> DigestValues {
        let fullSHA: String
        if let fileSHA256 {
            fullSHA = fileSHA256
        }
        else if let value = sha256 {
            fullSHA = Self.hex(value.finalize())
        }
        else {
            throw NateError.message("摘要缺少同一原字节快照的 SHA-256 证据。")
        }
        return DigestValues(
            md5: Self.hex(md5.finalize()),
            sha1: Self.hex(sha1.finalize()),
            sha256: fullSHA,
            sha512: Self.hex(sha512.finalize())
        )
    }

    /// 业务作用：摘要直接编码为固定 ASCII 十六进制，不引入区域格式或数字精度变化。
    /// 参数说明:
    /// - digest: 系统算法完整输出字节。
    /// 返回：每个原字节恰好两个小写十六进制数字。
    private static func hex<Value: Digest>(_ digest: Value) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(128)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 15)])
        }
        return String(
            decoding: bytes,
            as: UTF8.self
        )
    }
}
