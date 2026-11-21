import Foundation

public struct IndentationBackspaceReader {
    private let text: PieceTree
    private let tabWidth: Int
    private let deadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool
    private var remaining = 1_048_576

    /// 业务作用：同一批退格共用原文、停靠宽度与读取预算，任何失败都先于实际正文提交。
    /// 参数说明:
    /// - text: 本次固定原正文。
    /// - tabWidth: 当前语言的明确 Tab 宽度，一至三十二。
    /// - deadline: 本批目标的共同截止，最多五秒。
    /// - permit: 当前操作的继续资格。
    /// 返回：尚未读取正文的缩进范围读取器；非法宽度拒绝建立。
    public init(
        text: PieceTree,
        tabWidth: Int,
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        // 无合法停靠间距就没有可证明的缩进边缘，不能按夹取后的另一项配置扩大删除范围。
        guard (1...32).contains(tabWidth) else {
            throw NateError.message("缩进退格需要 1 到 32 的 Tab 宽度。")
        }
        self.text = text
        self.tabWidth = tabWidth
        self.deadline = min(deadline, .now.advanced(by: .seconds(5)))
        self.permit = permit
    }

    /// 业务作用：只在插入点前全部为空格或 Tab 时，取得上一个停靠位到当前点的完整原字节范围。
    /// 参数说明:
    /// - offset: 当前普通空光标的真实字节位置。
    /// 返回：完整缩进范围或空；行首、正文中和行结束符交给标准字形删除，超量或失权则整批失败。
    public mutating func range(before offset: Int) throws -> ByteRange? {
        try checkpoint()
        guard text.isBoundary(offset) else {
            throw NateError.invalidRange
        }
        let row = text.lineNumber(at: offset)
        let body = text.lineRange(row, includeEnding: false)
        // 行首和结束符没有可证明的前导缩进，继续使用标准字形语义，不能把它们当成空白列。
        guard offset > body.lower, offset <= body.upper else {
            return nil
        }
        var position = body.lower, column = 0
        var latestStop = body.lower, previousStop = body.lower
        while position < offset {
            try checkpoint()
            guard let byte = text.byte(at: position), byte == 32 || byte == 9 else {
                // 一旦遇到正文，已有缩进计数不再代表当前光标，不能扩大标准退格的删除范围。
                return nil
            }
            column += byte == 9 ? tabWidth - column % tabWidth : 1
            guard column <= 1_000_000 else {
                throw NateError.message("缩进超过一百万逻辑列，未准备部分退格目标。")
            }
            position += 1
            if column % tabWidth == 0 {
                previousStop = latestStop
                latestStop = position
            }
        }
        let start = column % tabWidth == 0 ? previousStop : latestStop
        return ByteRange(start, offset)
    }

    /// 业务作用：所有光标共用原缩进读取额度和截止，后续行不能重新取得完整预算。
    /// 参数说明: 无。
    /// 返回：仍有效时继续；取消、失权、超时或累计读取超过 1 MiB 时明确失败。
    private mutating func checkpoint() throws {
        // 失去继续资格后整批范围应由调用方放弃，不能将此前若干光标当成可提交子集。
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline, remaining > 0 else {
            throw NateError.message("缩进退格已取消或超过共享预算，正文与选择保持原状。")
        }
        remaining -= 1
    }
}
