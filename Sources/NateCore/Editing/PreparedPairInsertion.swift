import Foundation

public struct PreparedPairInsertion: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：逐普通选择准备包围、空光标配对或闭合越过，原选中文本和稳定身份共同形成唯一撤销动作。
    /// 参数说明:
    /// - snapshot: 带完整源选择及控制代次的固定正文。
    /// - command: 本次固定配对定义、真实输入与越过选项。
    /// - completeOpening: 开端是否生成完整一对并包围非空选区；独立结构字符输入关闭此项以保留字面字符。
    /// - tabSettings: 结构前缀采用的实际 Tab 停靠规则。
    /// - indentation: 逐目标的已确认前导空白，为空时保留原行；闭合花括号或方括号前的正文按原字节保留。
    /// - permit: 范围、源字节与事务构建共用的继续资格。
    /// 返回：全部目标完整准备时提供事务；生成配对时光标位于保留文本之后及闭合端之前；矩形、边界、容量或资格失效时拒绝全部动作。
    public init(
        snapshot: DocumentSnapshot,
        command: PairInputCommand,
        completeOpening: Bool = true,
        tabSettings: TabSettings = TabSettings(),
        indentation: (@Sendable (SelectionEntry) throws -> String?)? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        let sharedPermit: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        // 核心没有实际矩形边缘，不能把配对扩大到未选中的 Tab 或虚拟列。
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil,
            case .stream = original.shape
        else {
            throw NateError.message("自动配对需要普通选择的完整身份；矩形沿原字面输入处理。")
        }
        let normalized = try original.normalized(in: snapshot.text, permit: sharedPermit)
        let opening = command.input.utf8.elementsEqual(command.pair.opening.utf8)
        let closing = command.input.utf8.elementsEqual(command.pair.closing.utf8)
        var remaining = 1_048_576
        var intents: [(entry: SelectionEntry, range: ByteRange, paired: Bool)] = []
        var outputBytes = 0, removedBytes = 0
        for entry in normalized.entries {
            try budget.check()
            let selection = entry.selection
            var range = selection.range
            // 明确选区的包围不依赖前一个字符，转义与词内引号限制只约束空光标的自动生成。
            let escaped =
                range.isEmpty
                ? try Self.escaped(
                    in: snapshot.text,
                    before: range.lower,
                    remaining: &remaining,
                    budget: budget
                )
                : false
            var paired = false
            if closing, command.skipExisting, !escaped, range.isEmpty, selection.virtualColumn == 0,
                command.pair.closing.utf8.count <= snapshot.text.byteCount - range.lower,
                snapshot.text.bytes(in: ByteRange(range.lower, range.lower + command.pair.closing.utf8.count))
                    .elementsEqual(command.pair.closing.utf8)
            {
                // 相同原字节替换只推进选择，保留正文修订及重做历史；混合目标仍由同一事务统一发布。
                range = ByteRange(range.lower, range.lower + command.pair.closing.utf8.count)
            }
            else if opening && completeOpening {
                let symmetric = command.pair.opening.utf8.elementsEqual(command.pair.closing.utf8)
                let word =
                    range.isEmpty && symmetric && Self.previousIsWord(in: snapshot.text, before: range.lower)
                paired = !range.isEmpty || !escaped && !word
            }
            let retained = paired ? selection.range.count : 0
            let ends =
                paired
                ? command.pair.opening.utf8.count + command.pair.closing.utf8.count
                : command.input.utf8.count
            // 先确认全部选择及两端的真实输出规模，不能复制巨大原选区后才发现后续目标超量。
            guard retained <= 67_108_864 - ends,
                (0...1_000_000).contains(selection.virtualColumn),
                retained + ends + selection.virtualColumn <= 268_435_456 - outputBytes
            else {
                throw NateError.message("配对输入超过单目标 64 MiB 或共同输出 256 MiB，原选择保持不变。")
            }
            outputBytes += retained + ends + selection.virtualColumn
            removedBytes += range.count
            intents.append((entry, range, paired))
        }
        if indentation == nil {
            // 没有结构前缀调整时，最终正文规模可以在复制任何选中文字前准确确定。
            guard snapshot.text.byteCount - removedBytes <= 1_073_741_824 - outputBytes else {
                throw NateError.message("配对输入后的正文超过 1 GiB，原选择保持不变。")
            }
        }
        let targets = try intents.map { intent in
            try budget.check()
            let entry = intent.entry, selection = entry.selection
            var range = intent.range
            var value = command.input
            var caret = value.utf8.count
            if intent.paired {
                let selected = snapshot.text.text(in: selection.range)
                value = command.pair.opening + selected + command.pair.closing
                caret = command.pair.opening.utf8.count + selected.utf8.count
            }
            if let prefix = try indentation?(entry) {
                let adjusted = try PairIndentationPrefix.prepare(
                    prefix: prefix,
                    entry: entry,
                    text: snapshot.text,
                    settings: tabSettings,
                    allowsBody: closing && (command.input == "}" || command.input == "]"),
                    remaining: &remaining,
                    budget: budget
                )
                range = ByteRange(adjusted.start, range.upper)
                value = prefix + adjusted.body + value
                caret += prefix.utf8.count + adjusted.body.utf8.count
            }
            return SelectionInsertionTarget(
                id: entry.id,
                range: range,
                text: value,
                leadingSpaces: selection.virtualColumn,
                caretByteOffset: caret
            )
        }
        transaction = try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: targets,
            primaryID: normalized.primaryID,
            name: "配对输入",
            permit: sharedPermit
        ).transaction
        try budget.check()
    }

    /// 业务作用：反斜杠转义中的开端保留字面输入，连续反斜杠按真实奇偶关系解释。
    /// 参数说明:
    /// - text: 当前固定原文。
    /// - offset: 插入起点。
    /// - remaining: 全部光标共同拥有的前置读取额度。
    /// - budget: 本轮输入的共同执行资格。
    /// 返回：紧邻的连续反斜杠数为奇数时为真，超量时拒绝而不截断判定。
    private static func escaped(
        in text: PieceTree,
        before offset: Int,
        remaining: inout Int,
        budget: SelectionPreparationBudget
    ) throws -> Bool {
        var index = offset, count = 0
        while index > 0 {
            if count & 255 == 0 {
                try budget.check()
            }
            guard remaining > 0 else {
                throw NateError.message("自动配对前置字节读取超过 1 MiB，全部输入保持原状。")
            }
            remaining -= 1
            guard text.byte(at: index - 1) == 92 else {
                break
            }
            count += 1
            index -= 1
        }
        return count & 1 == 1
    }

    /// 业务作用：词内对称引号保留普通字符语义，固定 Unicode 词分类不随系统地区改变。
    /// 参数说明:
    /// - text: 当前原文。
    /// - offset: 已验证的完整 UTF-8 插入边界。
    /// 返回：紧邻前一个标量属于固定词字符时为真，行首或其它字符为假。
    private static func previousIsWord(in text: PieceTree, before offset: Int) -> Bool {
        guard offset > 0 else {
            return false
        }
        var start = offset - 1
        while start > 0, let byte = text.byte(at: start), byte & 0xc0 == 0x80 {
            start -= 1
        }
        let scalar = text.text(in: ByteRange(start, offset)).unicodeScalars.first
        return scalar.map {
            UnicodeWordClassification.contains($0.value)
        } ?? false
    }
}
