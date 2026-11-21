import Foundation
import NateCore

public struct MarkupInsertionTarget: Sendable, Hashable {
    public let range: ByteRange
    public let leadingSpaces: Int

    /// 业务作用：固定普通选择的真实范围和明确虚拟空白，原始名称不能因输入定位改变而被猜测。
    /// 参数说明:
    /// - range: 同一快照上的完整替换范围。
    /// - leadingSpaces: 普通虚拟光标在输入前生成的明确空格数。
    /// 返回：尚未取得写入权限的词法目标，由整批计划复验。
    public init(range: ByteRange, leadingSpaces: Int = 0) {
        self.range = range
        self.leadingSpaces = leadingSpaces
    }
}

public struct MarkupClosurePlan: Sendable {
    private let documentID: UUID
    private let revision: UInt64
    private let selectionGeneration: UUID?
    private let source: PieceTree
    private let deadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool
    private let inputs: [MarkupInsertionTarget: String]
    public let conservativeScriptContext: Bool
    public let nameLimitExceeded: Bool

    /// 业务作用：单次有界前缀扫描为全部目标确认标签闭合内容，注释、声明和原始文本不生成外观标签。
    /// 参数说明:
    /// - snapshot: 当前固定原文及选择控制身份。
    /// - dialect: 当前明确的 HTML 或 XML 规则。
    /// - targets: 已归并的普通选择真实范围与虚拟前缀。
    /// - deadline: 从识别到最终输入准备共同拥有的截止。
    /// - permit: 当前动作仍可继续的资格。
    /// 返回：全部目标的完整结束符输入；前缀、输出、边界或资格不足时整体失败。
    public init(
        snapshot: DocumentSnapshot,
        dialect: MarkupDialect,
        targets: [MarkupInsertionTarget],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        try Self.check(deadline: deadline, permit: permit)
        guard !targets.isEmpty, targets.count <= 100_000 else {
            throw NateError.message("标签输入需要一至十万个完整目标。")
        }
        documentID = snapshot.id
        revision = snapshot.revision
        selectionGeneration = snapshot.selectionGeneration
        source = snapshot.text
        self.deadline = deadline
        self.permit = permit
        var comparisons = 0
        let ordered = try targets.sorted {
            comparisons += 1
            if comparisons & 255 == 0 {
                try Self.check(deadline: deadline, permit: permit)
            }
            return $0.range.lower == $1.range.lower
                ? $0.range.upper < $1.range.upper : $0.range.lower < $1.range.lower
        }
        var removed = 0, minimum = 0
        var previous: ByteRange?
        for target in ordered {
            try Self.check(deadline: deadline, permit: permit)
            let range = target.range
            guard range.lower >= 0, range.upper >= range.lower,
                snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper),
                (0...1_000_000).contains(target.leadingSpaces)
            else {
                throw NateError.invalidRange
            }
            if let previous {
                guard previous.upper <= range.lower, !(previous.isEmpty && previous == range) else {
                    throw NateError.overlappingEdits
                }
            }
            previous = range
            removed += range.count
            minimum += 1 + target.leadingSpaces
        }
        let maximum = min(268_435_456, 1_073_741_824 - snapshot.text.byteCount + removed)
        // 真实最终规模不可能成立时先拒绝，不能先为每个目标创建闭合文本或虚拟空白。
        guard minimum <= maximum, (ordered.last?.range.lower ?? 0) <= 67_108_864 else {
            throw NateError.message("标签输入超过 64 MiB 原文前缀、256 MiB 输出或 1 GiB 正文预算。")
        }
        var remaining = maximum
        var cursor = 0, steps = 0
        var scanner = MarkupLexing(dialect: dialect)
        var output: [MarkupInsertionTarget: String] = [:]
        var limited = false
        for target in ordered {
            while cursor < target.range.lower {
                try Self.check(deadline: deadline, permit: permit)
                let end = min(target.range.lower, cursor + 8192)
                for byte in snapshot.text.bytes(in: ByteRange(cursor, end)) {
                    if steps & 255 == 0 {
                        try Self.check(deadline: deadline, permit: permit)
                    }
                    steps += 1
                    scanner.consume(byte)
                }
                cursor = end
            }
            try Self.check(deadline: deadline, permit: permit)
            limited = limited || scanner.mode == .tag && scanner.tag.capacityExceeded
            var closure = scanner.proposedClosure(leadingSpaces: target.leadingSpaces) ?? ""
            if !closure.isEmpty, closure.utf8.count <= snapshot.text.byteCount - target.range.upper {
                let existing = snapshot.text.bytes(
                    in: ByteRange(target.range.upper, target.range.upper + closure.utf8.count)
                )
                let proposed = Array(closure.utf8)
                let matches =
                    dialect == .html
                    ? MarkupNames.folded(existing) == MarkupNames.folded(proposed) : existing == proposed
                if matches {
                    closure = ""
                }
            }
            let size = 1 + target.leadingSpaces + closure.utf8.count
            guard size <= remaining else {
                throw NateError.message("完整标签输入超过正文或输出容量，未提交部分目标。")
            }
            remaining -= size
            output[target] = ">" + closure
        }
        try Self.check(deadline: deadline, permit: permit)
        conservativeScriptContext = scanner.ambiguousScript
        nameLimitExceeded = limited
        inputs = output
    }

    /// 业务作用：输入事务只能读取同一原字节及选择身份已经确认的闭合内容，旧计划不能重新取得写入资格。
    /// 参数说明:
    /// - target: 已完整确认的原范围与定位空白。
    /// - snapshot: 核心事务实际采用的来源。
    /// 返回：包含真实结束符和可选闭合标签的完整文字，来源或执行资格改变时抛错。
    public func input(for target: MarkupInsertionTarget, snapshot: DocumentSnapshot) throws -> String {
        try Self.check(deadline: deadline, permit: permit)
        // 文档标识和修订不能替代正文证据，非共享树仍须在原截止内逐字节比较。
        guard snapshot.id == documentID, snapshot.revision == revision,
            snapshot.selectionGeneration == selectionGeneration,
            try source.byteEqual(
                to: snapshot.text,
                permit: {
                    permit() && ContinuousClock.now < deadline
                }
            ),
            let value = inputs[target]
        else {
            throw NateError.message("标签输入来源或完整目标已经改变，未提交旧内容。")
        }
        return value
    }

    /// 业务作用：所有目标共享同一取消与时间资格，最后一项也不能绕过失权门禁。
    /// 参数说明:
    /// - deadline: 完整输入动作的原截止。
    /// - permit: 当前继续准备的资格。
    /// 返回：仍有完整执行资格时继续，否则抛错且不发布部分计划。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("标签输入已取消或超过共同截止，原内容与选择保持原状。")
        }
    }
}
