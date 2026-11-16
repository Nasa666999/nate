import Foundation
import NateCore

public enum SearchMode: String, Sendable, Codable, CaseIterable {
    case literal = "普通"
    case extended = "扩展"
    case regex = "正则表达式"
}

public struct SearchOptions: Sendable, Codable, Equatable {
    public var query = ""
    public var replacement = ""
    public var mode: SearchMode = .literal
    public var caseSensitive = false
    public var wholeWord = false
    public var dotMatchesNewline = false
    public var wrap = true
    public var backwards = false
    public var selectionOnly = false
    public var recursive = true
    public var includeHidden = false
    public var ignoreOpenBuffers = false
    public var maxMatches = 100_000
    public var stepLimit = 5_000_000

    /// 业务作用：建立可独立保存和复用的查找条件。
    /// 参数说明: 无。
    /// 返回：普通搜索默认选项。
    public init() {}
}

public struct SearchHit: Sendable {
    public let utf16Range: NSRange
    public let range: ByteRange?
    public let captures: [Int: NSRange]
    public let names: [String: Int]

    /// 业务作用：保留正则字符单位与无损修改范围的差异。
    /// 参数说明:
    /// - utf16Range: 引擎的完整命中。
    /// - range: 可无损转换的内核范围。
    /// - captures: 已参与的捕获，未参与组不登记。
    /// - names: 命名捕获索引。
    /// 返回：只读命中证据。
    public init(
        utf16Range: NSRange,
        range: ByteRange?,
        captures: [Int: NSRange] = [:],
        names: [String: Int] = [:]
    ) {
        self.utf16Range = utf16Range
        self.range = range
        self.captures = captures
        self.names = names
    }
}

public struct SearchResult: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let options: SearchOptions
    public let hits: [SearchHit]
}

public enum ExtendedEscapes {
    /// 业务作用：按固定宽度解释扩展模式，未知或残缺转义保持字面内容。
    /// 参数说明:
    /// - input: 查找或替换框原始内容。
    /// 返回：已解释的实际文本，保留 NUL 与换行。
    public static func decode(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        var i = 0
        let simple: [UInt32: UInt32] = [110: 10, 114: 13, 116: 9, 48: 0, 92: 92]
        let numeric: [UInt32: (Int, Int)] = [
            98: (8, 2), 111: (3, 8), 100: (3, 10), 120: (2, 16), 117: (4, 16),
        ]
        while i < scalars.count {
            if scalars[i].value == 92, i + 1 < scalars.count {
                if let value = simple[scalars[i + 1].value], let scalar = Unicode.Scalar(value) {
                    output.append(scalar)
                    i += 2
                    continue
                }
                if let (width, radix) = numeric[scalars[i + 1].value], i + 2 + width <= scalars.count {
                    let digits = String(String.UnicodeScalarView(scalars[(i + 2)..<(i + 2 + width)]))
                    if let value = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(value) {
                        output.append(scalar)
                        i += 2 + width
                        continue
                    }
                }
            }
            output.append(scalars[i])
            i += 1
        }
        return String(output)
    }
}
