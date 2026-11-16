import Foundation

public struct ByteRange: Sendable, Codable, Hashable {
    public var lower: Int
    public var upper: Int
    public var count: Int {
        upper - lower
    }
    public var isEmpty: Bool {
        lower == upper
    }

    /// 业务作用：建立 UTF-8 半开范围；合法性由所属快照校验。
    /// 参数说明:
    /// - lower: 包含的起始字节。
    /// - upper: 不包含的结束字节。
    /// 返回：保留端点，不隐式交换或截断非法输入。
    public init(_ lower: Int, _ upper: Int) {
        self.lower = lower
        self.upper = upper
    }
}

public struct TextSelection: Sendable, Codable, Hashable {
    public var anchor: Int
    public var head: Int
    public var virtualColumn: Int
    public var range: ByteRange {
        ByteRange(min(anchor, head), max(anchor, head))
    }

    /// 业务作用：记录带方向和虚拟列的视图选区。
    /// 参数说明:
    /// - anchor: 固定端 UTF-8 位置。
    /// - head: 活动端 UTF-8 位置。
    /// - virtualColumn: 行尾之外尚未写入的视觉列。
    /// 返回：选区本身不产生正文修改。
    public init(anchor: Int, head: Int, virtualColumn: Int = 0) {
        self.anchor = anchor
        self.head = head
        self.virtualColumn = virtualColumn
    }
}

public enum NateError: Error, LocalizedError, Sendable {
    case invalidRange
    case staleRevision
    case readOnly
    case overlappingEdits
    case invalidText
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange: "文本范围不属于当前快照或切开了字符编码。"
        case .staleRevision: "文档已经变化，请重新执行此操作。"
        case .readOnly: "当前文档为编辑器只读。"
        case .overlappingEdits: "编辑范围交叠，无法确定一次性修改结果。"
        case .invalidText: "内容不是合法的 UTF-8 文本。"
        case .message(let value): value
        }
    }
}
