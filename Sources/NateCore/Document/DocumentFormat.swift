import Foundation

public enum LineEnding: String, Sendable, Codable, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var text: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// 业务作用：只确定新插入换行的规则，既有混合换行不被归一化。
    /// 参数说明:
    /// - text: 已解码正文。
    /// 返回：首个实际换行的类型；没有换行时使用 LF。
    public static func detect(_ text: String) -> LineEnding {
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == 10 {
                return .lf
            }
            if byte == 13 {
                return iterator.next() == 10 ? .crlf : .cr
            }
        }
        return .lf
    }
}

public struct DocumentFormat: Sendable, Codable, Equatable {
    public var codePage: UInt32
    public var bom: Bool
    public var lineEnding: LineEnding
    public static let utf8 = DocumentFormat()

    /// 业务作用：将影响持久化与新输入的文档参数纳入同一事务和历史。
    /// 参数说明:
    /// - codePage: 明确代码页。
    /// - bom: 是否输出前导 BOM。
    /// - lineEnding: 新输入的换行规则。
    /// 返回：独立于存储后端的格式值。
    public init(codePage: UInt32 = 65001, bom: Bool = false, lineEnding: LineEnding = .lf) {
        self.codePage = codePage
        self.bom = bom
        self.lineEnding = lineEnding
    }
}
