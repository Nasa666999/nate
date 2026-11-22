import Foundation

public struct TextComparisonHunk: Sendable, Equatable {
    public let originalLines: Range<Int>
    public let revisedLines: Range<Int>
    public let originalRange: ByteRange
    public let revisedRange: ByteRange
}

public struct TextComparison: Sendable {
    public static let maximumBytesPerSide = 8_388_608
    public static let maximumCombinedLines = 100_000
    public static let maximumLineBytes = 262_144
    public let hunks: [TextComparisonHunk]
    public let originalLineCount: Int
    public let revisedLineCount: Int
    public let insertedLineCount: Int
    public let removedLineCount: Int

    /// 业务作用：固定两份完整正文的最短逐行增删差异，真实换行与 Unicode 字节身份参与比较。
    /// 参数说明:
    /// - original: 左侧不可变正文，最多 8 MiB。
    /// - revised: 右侧不可变正文，最多 8 MiB。
    /// - deadline: 调用方更早的共同截止，省略时使用五秒，不能延长内置预算。
    /// - permit: 本次完整比较仍拥有执行资格。
    /// 返回：有序完整变更区间；取消、容量、计算或追踪内存超限整体失败，不提供近似或部分差异。
    public init(
        original: PieceTree,
        revised: PieceTree,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ComparisonBudget(deadline: deadline, permit: permit)
        try budget.check()
        // 在复制正文之前拒绝超量快照，大文档不能因为比较入口先产生完整中间字符串。
        guard original.byteCount <= Self.maximumBytesPerSide, revised.byteCount <= Self.maximumBytesPerSide
        else {
            throw NateError.message("文档比较每侧最多 8 MiB，未截取部分正文。")
        }
        let left = try Self.lines(original, budget: budget)
        let right = try Self.lines(revised, budget: budget)
        guard left.count + right.count <= Self.maximumCombinedLines else {
            throw NateError.message("文档比较两侧合计最多十万个物理行。")
        }
        originalLineCount = left.count
        revisedLineCount = right.count
        var prefix = 0
        while prefix < min(left.count, right.count), try Self.equal(left[prefix], right[prefix], budget) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(left.count, right.count) - prefix,
            try Self.equal(left[left.count - suffix - 1], right[right.count - suffix - 1], budget)
        {
            suffix += 1
        }
        let steps = try Self.shortestSteps(
            Array(left[prefix..<(left.count - suffix)]),
            Array(right[prefix..<(right.count - suffix)]),
            budget: budget
        )
        var changes: [TextComparisonHunk] = []
        var i = prefix, j = prefix
        var start: (Int, Int)?
        for step in steps {
            try budget.consume(1)
            switch step {
            case .equal:
                if let begin = start {
                    changes.append(
                        Self.hunk(
                            begin,
                            end: (i, j),
                            left: left,
                            right: right,
                            original: original,
                            revised: revised
                        )
                    )
                    start = nil
                }
                i += 1
                j += 1
            case .remove:
                if start == nil {
                    start = (i, j)
                }
                i += 1
            case .insert:
                if start == nil {
                    start = (i, j)
                }
                j += 1
            }
        }
        if let begin = start {
            changes.append(
                Self.hunk(begin, end: (i, j), left: left, right: right, original: original, revised: revised)
            )
        }
        try budget.check()
        hunks = changes
        insertedLineCount = changes.reduce(0) {
            $0 + $1.revisedLines.count
        }
        removedLineCount = changes.reduce(0) {
            $0 + $1.originalLines.count
        }
    }
}

private struct ComparisonLine {
    let range: ByteRange
    let bytes: Data
}

private enum ComparisonStep {
    case equal
    case remove
    case insert
}

private final class ComparisonBudget {
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool
    var work = 0

    /// 业务作用：读取、逐行求解和回溯共用同一截止与操作资格。
    /// 参数说明:
    /// - deadline: 调用方更早的共同截止。
    /// - permit: 本次完整比较仍然有效的权限。
    /// 返回：最多五秒和六千四百万工作单位的独立预算。
    init(deadline: ContinuousClock.Instant?, permit: @escaping @Sendable () -> Bool) {
        self.deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        self.permit = permit
    }

    /// 业务作用：每次有界工作前复验执行资格，拒绝不完整结果进入呈现。
    /// 参数说明: 无。
    /// 返回：资格及五秒截止仍有效时继续，否则抛错。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("文档比较超过五秒，未显示部分差异。")
        }
    }

    /// 业务作用：按实际状态和比较字节累计工作量，重复行不能绕过有界最短路径求解。
    /// 参数说明:
    /// - count: 当前完整步骤至少需要检查的状态或字节数量。
    /// 返回：累计不超过六千四百万单位时继续，否则整份拒绝。
    func consume(_ count: Int) throws {
        try check()
        guard count <= 64_000_000 - work else {
            throw NateError.message("文档比较超过计算预算，未以近似差异代替完整结果。")
        }
        work += count
    }
}

extension TextComparison {
    /// 业务作用：按真实 CR、LF 与 CRLF 切出包含结束符的物理行，不使用字符串规范等价判断。
    /// 参数说明:
    /// - text: 已通过单侧容量门禁的完整正文。
    /// - budget: 本次比较的共同预算。
    /// 返回：每行原字节和合法范围；超长行或过量行整体拒绝。
    private static func lines(_ text: PieceTree, budget: ComparisonBudget) throws -> [ComparisonLine] {
        try budget.consume(text.byteCount)
        let bytes = text.bytes(in: ByteRange(0, text.byteCount))
        var result: [ComparisonLine] = []
        var cursor = 0, start = 0
        while cursor < bytes.count {
            if cursor & 4095 == 0 {
                try budget.check()
            }
            if bytes[cursor] == 13 || bytes[cursor] == 10 {
                if bytes[cursor] == 13, cursor + 1 < bytes.count, bytes[cursor + 1] == 10 {
                    cursor += 1
                }
                cursor += 1
                try appendLine(bytes, start: start, end: cursor, to: &result, budget: budget)
                start = cursor
            }
            else {
                cursor += 1
            }
            guard cursor - start <= maximumLineBytes else {
                throw NateError.message("文档比较单个物理行最多 256 KiB，未截断原文。")
            }
        }
        if start < bytes.count {
            try appendLine(bytes, start: start, end: bytes.count, to: &result, budget: budget)
        }
        return result
    }

    /// 业务作用：完整物理行先通过容量门禁，再取得独立原字节以进行精确比较。
    /// 参数说明:
    /// - bytes: 当前完整正文的原始 UTF-8。
    /// - start: 本行起点。
    /// - end: 包含真实结束符的本行终点。
    /// - result: 当前已确认的完整行集合。
    /// - budget: 本次完整比较的共同预算。
    /// 返回：合法行完整追加，超量时拒绝全部比较。
    private static func appendLine(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        to result: inout [ComparisonLine],
        budget: ComparisonBudget
    ) throws {
        try budget.consume(1)
        guard result.count < maximumCombinedLines, end - start <= maximumLineBytes else {
            throw NateError.message("文档比较物理行数量或长度超过容量。")
        }
        result.append(
            ComparisonLine(
                range: ByteRange(start, end),
                bytes: Data(bytes[start..<end])
            )
        )
    }

    /// 业务作用：行身份直接来自完整字节，换行、NUL 和规范等价 Unicode 均不能被忽略。
    /// 参数说明:
    /// - left: 左侧完整物理行。
    /// - right: 右侧完整物理行。
    /// - budget: 本次比较的共同预算。
    /// 返回：真实长度和每个字节一致时为真，失权或工作超量时失败。
    private static func equal(_ left: ComparisonLine, _ right: ComparisonLine, _ budget: ComparisonBudget)
        throws -> Bool
    {
        try budget.consume(left.bytes.count == right.bytes.count ? max(1, left.bytes.count) : 1)
        return left.bytes == right.bytes
    }

    /// 业务作用：Myers 最短路径保留完整回溯证据，内存不足时拒绝而不合并未计算的差异。
    /// 参数说明:
    /// - left: 已移除共同前后缀的左侧完整物理行。
    /// - right: 已移除共同前后缀的右侧完整物理行。
    /// - budget: 求解与回溯共同持有的预算。
    /// 返回：具有最少增删行数的完整有序步骤，最多四百万个回溯整数。
    private static func shortestSteps(
        _ left: [ComparisonLine],
        _ right: [ComparisonLine],
        budget: ComparisonBudget
    ) throws -> [ComparisonStep] {
        if left.isEmpty {
            return Array(repeating: .insert, count: right.count)
        }
        if right.isEmpty {
            return Array(repeating: .remove, count: left.count)
        }
        let maximum = left.count + right.count, offset = maximum + 1
        var frontier = Array(repeating: 0, count: maximum * 2 + 3)
        var trace: [[Int]] = []
        var retained = 0, distance = 0
        search: for d in 0...maximum {
            try budget.consume(d + 1)
            // 每层仅保留有效对角线区间，固定总量先于下一份数组分配。
            guard 2 * d + 1 <= 4_000_000 - retained else {
                throw NateError.message("文档比较超过 32 MB 回溯预算，未显示部分差异。")
            }
            retained += 2 * d + 1
            var found = false
            for k in stride(from: -d, through: d, by: 2) {
                try budget.consume(1)
                let index = offset + k
                var x =
                    k == -d || k != d && frontier[index - 1] < frontier[index + 1]
                    ? frontier[index + 1] : frontier[index - 1] + 1
                var y = x - k
                while x < left.count, y < right.count, try equal(left[x], right[y], budget) {
                    x += 1
                    y += 1
                }
                frontier[index] = x
                if x >= left.count, y >= right.count {
                    found = true
                    break
                }
            }
            trace.append(Array(frontier[(offset - d)...(offset + d)]))
            if found {
                distance = d
                break search
            }
        }
        var x = left.count, y = right.count
        var steps: [ComparisonStep] = []
        if distance > 0 {
            for d in stride(from: distance, through: 1, by: -1) {
                try budget.consume(1)
                let previous = trace[d - 1], k = x - y
                let previousK =
                    k == -d || k != d && previous[k - 1 + d - 1] < previous[k + 1 + d - 1] ? k + 1 : k - 1
                let oldX = previous[previousK + d - 1], oldY = oldX - previousK
                while x > oldX, y > oldY {
                    steps.append(.equal)
                    x -= 1
                    y -= 1
                }
                if x == oldX {
                    steps.append(.insert); y -= 1
                }
                else {
                    steps.append(.remove); x -= 1
                }
            }
        }
        while x > 0, y > 0 {
            steps.append(.equal)
            x -= 1
            y -= 1
        }
        while x > 0 {
            steps.append(.remove)
            x -= 1
        }
        while y > 0 {
            steps.append(.insert)
            y -= 1
        }
        try budget.check()
        return steps.reversed()
    }

    /// 业务作用：相邻增删步骤组成同一可导航变更，空侧仍保留真实插入锚点。
    /// 参数说明:
    /// - start: 两侧变更开始的零基行索引。
    /// - end: 两侧变更结束的零基行索引。
    /// - left: 左侧完整行索引。
    /// - right: 右侧完整行索引。
    /// - original: 左侧完整正文，仅用于空末行锚点。
    /// - revised: 右侧完整正文，仅用于空末行锚点。
    /// 返回：包含两侧合法 UTF-8 边界与完整行跨度的变更。
    private static func hunk(
        _ start: (Int, Int),
        end: (Int, Int),
        left: [ComparisonLine],
        right: [ComparisonLine],
        original: PieceTree,
        revised: PieceTree
    ) -> TextComparisonHunk {
        let a = start.0 == left.count ? original.byteCount : left[start.0].range.lower
        let b = start.1 == right.count ? revised.byteCount : right[start.1].range.lower
        let c = end.0 == left.count ? original.byteCount : left[end.0].range.lower
        let d = end.1 == right.count ? revised.byteCount : right[end.1].range.lower
        return TextComparisonHunk(
            originalLines: start.0..<end.0,
            revisedLines: start.1..<end.1,
            originalRange: ByteRange(a, c),
            revisedRange: ByteRange(b, d)
        )
    }
}
