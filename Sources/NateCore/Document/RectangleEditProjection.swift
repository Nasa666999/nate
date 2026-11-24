import Foundation

public struct RectangleEditProjection: Sendable, Codable, Equatable {
    public let range: ByteRange
    public let leadingSpaces: Int
    public let trailingSpaces: Int

    /// 业务作用：保留选择时实际覆盖的字节和 Tab 两侧列数，后来的字形更新不能重解释原视觉删除范围。
    /// 参数说明:
    /// - range: 已包含部分选中边缘 Tab 的完整行内实际范围。
    /// - leadingSpaces: 起始 Tab 中未选中的列数。
    /// - trailingSpaces: 结束 Tab 中未选中的列数。
    /// 返回：有界实际编辑投影，正文行和 Tab 证据在绑定时另行完整验证。
    public init(range: ByteRange, leadingSpaces: Int = 0, trailingSpaces: Int = 0) throws {
        guard range.lower >= 0, range.upper >= range.lower, range.upper != NSNotFound,
            (0...1_000_000).contains(leadingSpaces), (0...1_000_000).contains(trailingSpaces),
            !range.isEmpty || leadingSpaces == 0 && trailingSpaces == 0
        else {
            throw NateError.message("矩形实际范围和 Tab 保留列数无效。")
        }
        self.range = range
        self.leadingSpaces = leadingSpaces
        self.trailingSpaces = trailingSpaces
    }

    /// 业务作用：原生投影只能扩大到边缘的一字节 Tab，不能借视觉证据取得其它未选中文字的权限。
    /// 参数说明:
    /// - selection: 仍对应同一行的原逻辑几何。
    /// - text: 同一完整已提交正文。
    /// - checkingCancellation: 后台校验响应取消；已发布正文的串行视图同步必须完成其证据整理。
    /// 返回：字节、行、字形与 Tab 两侧证据一致时保留投影，否则失败。
    public func validated(for selection: TextSelection, in text: PieceTree, checkingCancellation: Bool = true)
        throws -> RectangleEditProjection
    {
        guard text.isBoundary(selection.anchor), text.isBoundary(selection.head) else {
            throw NateError.invalidRange
        }
        return try validated(
            for: selection,
            in: text,
            body: text.physicalLineBody(containing: selection.range.lower),
            checkingCancellation: checkingCancellation
        )
    }

    /// 业务作用：复用调用者已经确认的同源物理行，验证投影在原行和原选择内只延伸到真实 Tab。
    /// 参数说明:
    /// - selection: 已确认原字节边界的选择。
    /// - text: 本次复验固定的原文。
    /// - body: 同一原文与选择起点对应的完整物理行正文。
    /// - checkingCancellation: 是否允许原准备任务取消当前复验。
    /// 返回：所有扩张字节和字形边界已证实时保留完整投影，否则失败。
    func validated(
        for selection: TextSelection,
        in text: PieceTree,
        body: ByteRange,
        checkingCancellation: Bool
    ) throws -> RectangleEditProjection {
        let entirelyASCII = text.byteCount == text.utf16Count
        guard range.lower >= body.lower, range.upper <= body.upper,
            range.lower <= selection.range.lower, selection.range.upper <= range.upper,
            selection.virtualColumn == 0 || range.isEmpty && range.lower == body.upper,
            entirelyASCII || text.isBoundary(range.lower) && text.isBoundary(range.upper),
            leadingSpaces == 0 || text.byte(at: range.lower) == 9,
            trailingSpaces == 0 || text.byte(at: range.upper - 1) == 9,
            range.lower == selection.range.lower
                || text.byte(at: range.lower) == 9 && selection.range.lower == range.lower + 1,
            range.upper == selection.range.upper
                || text.byte(at: range.upper - 1) == 9 && selection.range.upper == range.upper - 1
        else {
            throw NateError.message("矩形实际范围超出原选择或缺少边缘 Tab，未扩大编辑权限。")
        }
        // 同源计数相等证明全篇都是 ASCII；该行的正文范围已经排除唯一会切分字形的 CRLF。
        if entirelyASCII {
            if checkingCancellation {
                try Task.checkCancellation()
            }
            return self
        }
        var navigation = try GraphemeNavigation(text: text, checkingCancellation: checkingCancellation)
        guard try navigation.isBoundary(at: range.lower), try navigation.isBoundary(at: range.upper) else {
            throw NateError.message("矩形实际投影不能切开完整字形。")
        }
        return self
    }

    /// 业务作用：恢复原生投影仍遵守空范围和列数限制，不能经外部归档注入无界填充。
    /// 参数说明:
    /// - decoder: 已限制原始容量的所属归档解码器。
    /// 返回：合法投影，实际正文语义仍须复验。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            range: values.decode(ByteRange.self, forKey: .range),
            leadingSpaces: values.decode(Int.self, forKey: .leadingSpaces),
            trailingSpaces: values.decode(Int.self, forKey: .trailingSpaces)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case range, leadingSpaces, trailingSpaces
    }
}
