import Foundation
import NateCore

public enum MultipleSelectionAction: Sendable, Equatable {
    case all
    case next
    case skip
}

public struct MultipleSelectionOptions: Sendable, Codable, Equatable {
    public var caseSensitive = true
    public var wholeWord = false

    /// 业务作用：多选匹配拥有独立条件，不借用完整查找或持久样式设置。
    /// 参数说明: 无。
    /// 返回：默认区分大小写且允许词内字面匹配。
    public init() {}
}

private enum MultipleSelectionStop: Error {
    case found(ByteRange)
}

public struct PreparedMultipleSelection: Sendable {
    public let selections: [TextSelection]
    public let query: String

    /// 业务作用：从固定快照完整准备全部、追加或跳过选区，追加仅扫描到首个未占用命中。
    /// 参数说明:
    /// - snapshot: 原正文身份与修订。
    /// - selections: 原视图按建立顺序保存的全部真实选区，最后一项为继续位置。
    /// - query: 同一多选序列保留的完整原文，首次动作为空并从最后选区或完整光标词读取。
    /// - action: 全部匹配、追加下一个或替换最后选区为下一个匹配。
    /// - options: 多选独立的大小写与整词开关。
    /// 返回：最多十万个选区和完整原查询；取消、五秒超时或超量时不返回部分计划。
    public init(
        snapshot: DocumentSnapshot,
        selections: [TextSelection],
        query: String? = nil,
        action: MultipleSelectionAction,
        options: MultipleSelectionOptions
    ) throws {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard selections.count <= 100_000, let lastSelection = selections.last else {
            throw NateError.message("多选目标需要至少一个光标，最多十万个选区。")
        }
        for selection in selections {
            guard selection.virtualColumn == 0, snapshot.text.isBoundary(selection.anchor),
                snapshot.text.isBoundary(selection.head)
            else {
                throw NateError.message("匹配多选只接受完整原文中的真实选区，虚拟列不能缩成另一查询。")
            }
        }
        var targets = selections
        let expression: String
        if let query {
            expression = query
        }
        else {
            let input = try QuickFindInput(
                text: snapshot.text,
                selections: [lastSelection],
                fillLimit: nil
            )
            expression = input.query
            if input.expandedWord {
                targets[targets.count - 1] = TextSelection(
                    anchor: input.selection.lower,
                    head: input.selection.upper
                )
                if action == .next {
                    self.selections = targets
                    self.query = expression
                    return
                }
            }
        }
        var search = SearchOptions()
        search.query = expression
        search.caseSensitive = options.caseSensitive
        search.wholeWord = options.wholeWord
        try search.validateInput()
        let input = SearchInput(snapshot.text)
        let permit: @Sendable () -> Bool = {
            !Task.isCancelled && ContinuousClock.now < deadline
        }
        let occupied = Self.occupiedRanges(targets)
        let original = targets
        var result: [TextSelection] = []
        do {
            if action == .all {
                guard let scope = snapshot.text.nsRange(ByteRange(0, snapshot.text.byteCount)) else {
                    throw NateError.invalidRange
                }
                _ = try LiteralMatcher.find(
                    snapshot: snapshot,
                    input: input,
                    range: scope,
                    options: search,
                    permit: permit,
                    onHit: {
                        range in
                        guard let bytes = snapshot.text.byteRange(range) else {
                            throw NateError.invalidRange
                        }
                        guard result.count < 100_000 else {
                            throw NateError.message("匹配超过十万个选区，原选区保留。")
                        }
                        result.append(TextSelection(anchor: bytes.lower, head: bytes.upper))
                    }
                )
                if result.isEmpty {
                    result = targets
                }
            }
            else {
                guard action == .skip || targets.count < 100_000 else {
                    throw NateError.message("多选已达十万项，不能追加更多选区。")
                }
                let origin = targets[targets.count - 1].range.upper
                let scopes = [ByteRange(origin, snapshot.text.byteCount), ByteRange(0, origin)]
                var candidate: ByteRange?
                for scope in scopes {
                    guard scope.count > 0, let range = snapshot.text.nsRange(scope) else {
                        continue
                    }
                    do {
                        _ = try LiteralMatcher.find(
                            snapshot: snapshot,
                            input: input,
                            range: range,
                            options: search,
                            permit: permit,
                            onHit: {
                                found in
                                guard let bytes = snapshot.text.byteRange(found) else {
                                    throw NateError.invalidRange
                                }
                                if !Self.intersects(bytes, occupied: occupied) {
                                    // 找到首个合法目标即结束扫描，后续密集命中不能阻止一次追加。
                                    throw MultipleSelectionStop.found(bytes)
                                }
                            }
                        )
                    }
                    catch MultipleSelectionStop.found(let found) {
                        candidate = found
                    }
                    if candidate != nil {
                        break
                    }
                }
                result = targets
                if let candidate {
                    if action == .skip {
                        result.removeLast()
                    }
                    result.append(TextSelection(anchor: candidate.lower, head: candidate.upper))
                }
            }
        }
        catch is CancellationError {
            try Task.checkCancellation()
            throw NateError.message("多选匹配超过五秒预算，原选区保留。")
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("多选匹配超过五秒预算，原选区保留。")
        }
        self.selections = result.isEmpty ? original : result
        self.query = expression
    }

    /// 业务作用：用合并后的占用范围拒绝重复和交叠匹配，不随现有光标数量逐项扫描每个候选。
    /// 参数说明:
    /// - selections: 当前真实视图的全部选区。
    /// 返回：按原文字节位置排序的非交叠占用范围，空光标也保留其占用位置。
    private static func occupiedRanges(_ selections: [TextSelection]) -> [ByteRange] {
        let ranges: [ByteRange] = selections.map(\.range)
        let sorted = ranges.sorted {
            (a: ByteRange, b: ByteRange) -> Bool in
            if a.lower == b.lower {
                return a.upper < b.upper
            }
            return a.lower < b.lower
        }
        var result: [ByteRange] = []
        for range in sorted {
            if let last = result.last, range.lower < last.upper || range == last {
                result[result.count - 1] = ByteRange(last.lower, max(last.upper, range.upper))
            }
            else {
                result.append(range)
            }
        }
        return result
    }

    /// 业务作用：追加目标必须完全不接触已有选区内部，避免同一正文被重复选择或空光标落进新选择。
    /// 参数说明:
    /// - range: 新匹配的非空字节范围。
    /// - occupied: 已排序归并的现有占用范围。
    /// 返回：新匹配与既有正文选择交叠，或覆盖既有空光标位置时为真。
    private static func intersects(_ range: ByteRange, occupied: [ByteRange]) -> Bool {
        var lower = 0, upper = occupied.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if occupied[middle].upper < range.lower
                || occupied[middle].upper == range.lower && !occupied[middle].isEmpty
            {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < occupied.count else {
            return false
        }
        let existing = occupied[lower]
        return existing.isEmpty
            ? existing.lower >= range.lower && existing.lower < range.upper : existing.lower < range.upper
    }
}
