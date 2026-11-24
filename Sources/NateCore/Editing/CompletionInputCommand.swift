import Foundation

public struct CompletionInputCommand: Codable, Sendable {
    public static let maximumPrefixBytes = 65_536
    public static let maximumReplacementBytes = 64 * 1024 * 1024
    public let prefix: String
    public let replacement: String

    /// 业务作用：记录用户实际确认的前缀与候选原文，播放可复用同一完整替换语义。
    /// 参数说明:
    /// - prefix: 原光标之前的完整原始前缀，可为空但不得跨物理行。
    /// - replacement: 用户明确选择的完整候选文字。
    /// 返回：容量及原文范围合法的命令，非法前缀或空候选不取得修改资格。
    public init(prefix: String, replacement: String) throws {
        guard prefix.utf8.count <= Self.maximumPrefixBytes,
            !prefix.utf8.contains(10), !prefix.utf8.contains(13),
            !replacement.isEmpty, replacement.utf8.count <= Self.maximumReplacementBytes
        else {
            throw NateError.message("宏补全需要单行前缀和有效候选，前缀最多 64 KiB，候选最多 64 MiB。")
        }
        self.prefix = prefix
        self.replacement = replacement
    }

    /// 业务作用：读入结构化命令时复验载荷，不能通过独立解码入口绕过前缀与容量约束。
    /// 参数说明:
    /// - decoder: 原始前缀与候选的归档解码器。
    /// 返回：与直接构造具有完全相同约束的完整输入命令。
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            prefix: fields.decode(String.self, forKey: .prefix),
            replacement: fields.decode(String.self, forKey: .replacement)
        )
    }

    /// 业务作用：补全确认与宏播放只替换紧邻现有单光标的相同原始字节，保留尾部文字与稳定选择身份。
    /// 参数说明:
    /// - snapshot: 实际正文、选择及其控制代次的完整固定快照。
    /// 返回：一次可撤销的完整替换；虚拟光标、错误前缀或跨行目标不发布任何正文。
    public func prepare(in snapshot: DocumentSnapshot) throws -> PreparedTransaction {
        guard let state = snapshot.selectionState, case .stream = state.shape, state.entries.count == 1,
            state.primary.selection.range.isEmpty, state.primary.selection.virtualColumn == 0
        else {
            throw NateError.message("补全需要当前实际的单个正文光标。")
        }
        let entry = state.primary
        let head = entry.selection.head
        let size = prefix.utf8.count
        guard head >= size, snapshot.text.isBoundary(head) else {
            throw NateError.invalidRange
        }
        let lower = head - size
        let row = snapshot.text.lineRange(snapshot.text.lineNumber(at: head), includeEnding: false)
        let range = ByteRange(lower, head)
        // 归档没有旧文档坐标的写入权，必须先确认新光标前完整前缀恰好位于同一物理行。
        guard lower >= row.lower, head <= row.upper,
            snapshot.text.isBoundary(lower),
            snapshot.text.bytes(in: range).elementsEqual(prefix.utf8)
        else {
            throw NateError.message("当前光标前的原始前缀不同，补全动作未执行。")
        }
        return try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: [SelectionInsertionTarget(id: entry.id, range: range, text: replacement)],
            name: "补全"
        ).transaction
    }
}
