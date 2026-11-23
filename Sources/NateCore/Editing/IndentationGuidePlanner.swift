import Foundation

public struct IndentationGuideAnchor: Sendable, Equatable {
    public let byteOffset: Int
    public let virtualColumns: Int
    public let column: Int
}

public struct IndentationGuideLine: Sendable, Equatable {
    public let anchors: [IndentationGuideAnchor]
    public let isBlank: Bool
}

public struct IndentationGuidePlanner {
    private struct Prefix {
        let columns: Int
        let end: Int
        let boundaries: [Int]
        let blank: Bool
    }
    private let snapshot: DocumentSnapshot
    private let width: Int
    private let forwardOnly: Bool
    private let isFoldHeader: @Sendable (Int) -> Bool
    private let deadline: ContinuousClock.Instant
    private var operationDeadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool
    private var prefixes: [Int: Prefix] = [:]
    private var remainingBytes = 65_536
    private var remainingGuides = 4096

    /// 业务作用：一个呈现批次共用前导扫描、参考线和截止预算，邻近空行不能反复扫描同一长前缀。
    /// 参数说明:
    /// - snapshot: 当前可见正文的固定原字节快照。
    /// - tabWidth: 当前语言实际采用的一至三十二列 Tab 停靠。
    /// - forwardOnly: Python 类语言只从后继文本及前方块开端推断空行缩进。
    /// - isFoldHeader: 只查询同一正文快照已经确认的块开端，不触发结构分析。
    /// - deadline: 本批次共同的计算截止。
    /// - permit: 本批次来源和呈现资格仍然有效。
    /// 返回：共享至多 65536 个读取字节、4096 个来源行及 4096 条参考线的规划器，非法 Tab 宽度整体拒绝。
    public init(
        snapshot: DocumentSnapshot,
        tabWidth: Int,
        forwardOnly: Bool,
        isFoldHeader: @escaping @Sendable (Int) -> Bool = {
            _ in false
        },
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard (1...32).contains(tabWidth) else {
            throw NateError.message("缩进参考线需要一至三十二列的有效 Tab 宽度。")
        }
        self.snapshot = snapshot
        width = tabWidth
        self.forwardOnly = forwardOnly
        self.isFoldHeader = isFoldHeader
        self.deadline = deadline
        operationDeadline = deadline
        self.permit = permit
    }

    /// 业务作用：参考线只位于完整缩进内部，空行沿最多二十行的前后文本和已确认块开端延续。
    /// 参数说明:
    /// - line: 当前快照中的真实逻辑行号。
    /// - deadline: 当前调用可使用的更短计算截止；为空时沿批次共同截止。
    /// 返回：完整原字节锚点及空行虚拟列；超量、取消或失去来源时不提供该行的部分结果。
    public mutating func prepare(
        line: Int,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> IndentationGuideLine {
        operationDeadline = min(self.deadline, deadline ?? self.deadline)
        try check()
        guard (0..<snapshot.text.lineCount).contains(line) else {
            throw NateError.message("缩进参考线的来源行已经失效。")
        }
        let own = try prefix(line)
        var columns = own.columns
        if own.blank {
            var previous = line
            let lower = max(0, line - 20)
            while previous > lower, try prefix(previous).blank {
                previous -= 1
            }
            if previous < line {
                let earlier = try prefix(previous)
                let header = isFoldHeader(previous)
                if !forwardOnly || header {
                    columns = max(columns, earlier.columns + (header ? width : 0))
                }
            }
            var next = line
            let upper = line + min(20, snapshot.text.lineCount - line)
            while next < upper, try prefix(next).blank {
                next += 1
            }
            if next > line, next < snapshot.text.lineCount {
                columns = max(columns, try prefix(next).columns)
            }
        }
        let count = max(0, (columns - 1) / width)
        guard count <= remainingGuides else {
            throw NateError.message("当前帧缩进参考线超过 4096 条，后续参考线暂停，正文保持。")
        }
        var anchors: [IndentationGuideAnchor] = []
        anchors.reserveCapacity(count)
        for index in 0..<count {
            let column = (index + 1) * width
            if index < own.boundaries.count {
                anchors.append(
                    IndentationGuideAnchor(
                        byteOffset: own.boundaries[index],
                        virtualColumns: 0,
                        column: column
                    )
                )
            }
            else {
                anchors.append(
                    IndentationGuideAnchor(
                        byteOffset: own.end,
                        virtualColumns: column - own.columns,
                        column: column
                    )
                )
            }
        }
        try check()
        remainingGuides -= anchors.count
        return IndentationGuideLine(anchors: anchors, isBlank: own.blank)
    }

    /// 业务作用：只读取真实前导 ASCII 空格与 Tab，Unicode 空白、NUL 及正文不被猜作缩进。
    /// 参数说明:
    /// - line: 当前有限邻近范围内的来源行号。
    /// 返回：同一快照的完整前导证据；共同字节或单前缀预算不足时拒绝截断缩进。
    private mutating func prefix(_ line: Int) throws -> Prefix {
        if let cached = prefixes[line] {
            return cached
        }
        guard prefixes.count < 4096 else {
            throw NateError.message("当前批次缩进来源超过 4096 行，后续参考线暂停，正文保持。")
        }
        let range = snapshot.text.lineRange(line, includeEnding: false)
        var offset = range.lower, columns = 0
        var boundaries: [Int] = []
        while offset < range.upper {
            if offset & 255 == 0 {
                try check()
            }
            guard remainingBytes > 0 else {
                throw NateError.message("当前帧缩进前导读取超过 65536 字节，后续参考线暂停，正文保持。")
            }
            remainingBytes -= 1
            let byte = snapshot.text.byte(at: offset)
            guard byte == 32 || byte == 9 else {
                break
            }
            columns += byte == 9 ? width - columns % width : 1
            offset += 1
            if columns % width == 0 {
                guard boundaries.count < 4096 else {
                    throw NateError.message("单行缩进超过 4096 级，未使用截断缩进绘制参考线。")
                }
                boundaries.append(offset)
            }
        }
        let result = Prefix(
            columns: columns,
            end: offset,
            boundaries: boundaries,
            blank: offset == range.upper
        )
        prefixes[line] = result
        return result
    }

    /// 业务作用：共享截止与来源资格贯穿所有邻行读取，过期规划不能继续占用当前绘制。
    /// 参数说明: 无。
    /// 返回：资格仍有效且未取消、未超过截止时通过，否则停止当前规划。
    private func check() throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < operationDeadline else {
            throw NateError.message("缩进参考线来源失效或超过计算截止，后续参考线暂停，正文保持。")
        }
    }
}
