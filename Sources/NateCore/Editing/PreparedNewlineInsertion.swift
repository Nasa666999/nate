import Foundation

public struct NewlineInsertionTarget: Sendable {
    public let id: UUID
    public let range: ByteRange
    public let leadingSpaces: Int
    public let trailingSpaces: Int

    /// 业务作用：矩形换行固定原生边缘与需要保留的两侧空白，不把像素列推断交给正文核心。
    /// 参数说明:
    /// - id: 原完整选择中的稳定行身份。
    /// - range: 原生边缘已经证明的实际替换范围。
    /// - leadingSpaces: 换行前补齐或保留的原空白列数。
    /// - trailingSpaces: 换行后的原 Tab 剩余列数。
    /// 返回：尚未取得写入权限的完整目标，边界和容量由整批准备再次验证。
    public init(id: UUID, range: ByteRange, leadingSpaces: Int = 0, trailingSpaces: Int = 0) {
        self.id = id
        self.range = range
        self.leadingSpaces = leadingSpaces
        self.trailingSpaces = trailingSpaces
    }
}

public struct PreparedNewlineInsertion: Sendable {
    public let transaction: PreparedTransaction

    /// 业务作用：每个光标独立继承插入点前的原行及已明确边缘空白，全部换行形成同一撤销单元。
    /// 参数说明:
    /// - snapshot: 含完整源选择与文档换行规则的固定正文。
    /// - targets: 矩形由原生视图证明的全部边缘，普通流式选择必须省略。
    /// - inheritIndentation: 是否继承原字节缩进及其中明确的 Tab 或虚拟保留列，已有空白不作格式转换。
    /// - permit: 前缀读取、容量检查和事务构建共享的继续资格。
    /// 返回：保留建立顺序、身份和主项的完整事务；缩进读取累计超过 1 MiB 或任一目标失败时全部保留。
    public init(
        snapshot: DocumentSnapshot,
        targets: [NewlineInsertionTarget]? = nil,
        inheritIndentation: Bool = true,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        // 验证、归并与正文构建沿同一截止继续，进入下一阶段不能重新取得完整准备时间。
        let sharedPermit: @Sendable () -> Bool = {
            permit() && ContinuousClock.now < budget.deadline
        }
        // 没有源选择和控制代次就无法复验提交目标或撤销来源，不能按旧几何继续准备。
        guard let original = snapshot.selectionState, snapshot.selectionGeneration != nil else {
            throw NateError.message("换行需要原文档的完整选择身份。")
        }
        _ = try original.validated(in: snapshot.text, permit: sharedPermit)
        let resolved: [NewlineInsertionTarget]
        let primary: UUID
        if let targets {
            // 明确目标必须覆盖同一原矩形的全部身份，正文改变后旧像素不能重新授予修改资格。
            guard case .rectangle(let shape) = original.shape, !shape.needsRevalidation,
                targets.count == original.entries.count,
                Set(targets.map(\.id)) == Set(original.entries.map(\.id))
            else {
                throw NateError.message("矩形换行需要全部原选择的完整原生边缘，不能只提交部分行。")
            }
            resolved = targets
            primary = original.primaryID
        }
        else {
            // 核心没有原生字形证据，不能把矩形边缘静默当成普通连续选择。
            guard case .stream = original.shape else {
                throw NateError.message("矩形换行必须先由实际视图证明 Tab 和虚拟边缘。")
            }
            let normalized = try original.normalized(in: snapshot.text, permit: sharedPermit)
            resolved = normalized.entries.map {
                NewlineInsertionTarget(
                    id: $0.id,
                    range: $0.selection.range,
                    leadingSpaces: $0.selection.virtualColumn
                )
            }
            primary = normalized.primaryID
        }
        guard !resolved.isEmpty, resolved.count <= 100_000 else {
            throw NateError.message("换行需要一至十万个完整目标。")
        }
        let ending = snapshot.format.lineEnding.text
        var minimumOutput = 0, removed = 0
        // 所有原边界与空白容量先完整确认，再读取缩进或分配目标文字，后项失败不能留下前项输入。
        for target in resolved {
            try budget.check()
            guard target.range.lower >= 0, target.range.upper >= target.range.lower,
                snapshot.text.isBoundary(target.range.lower), snapshot.text.isBoundary(target.range.upper),
                (0...1_000_000).contains(target.leadingSpaces),
                (0...1_000_000).contains(target.trailingSpaces)
            else {
                throw NateError.invalidRange
            }
            let minimum = ending.utf8.count + target.leadingSpaces + target.trailingSpaces
            guard minimum <= 256 * 1024 * 1024 - minimumOutput else {
                throw NateError.message("全部换行及保留空白超过 256 MiB，未准备部分缩进。")
            }
            minimumOutput += minimum
            removed += target.range.count
        }
        // 原文容量已不可能成立时，不得先读取长缩进或创建虚拟空白副本。
        guard snapshot.text.byteCount - removed <= 1024 * 1024 * 1024 - minimumOutput else {
            throw NateError.message("换行后的正文超过 1 GiB，原内容与选择保留。")
        }
        var remaining = 1_048_576
        var remainingOutput = min(
            256 * 1024 * 1024 - minimumOutput,
            1024 * 1024 * 1024 - snapshot.text.byteCount + removed - minimumOutput
        )
        let converted = try resolved.map {
            target in
            let indent = try Self.indentation(
                in: snapshot.text,
                before: target.range.lower,
                enabled: inheritIndentation,
                remaining: &remaining,
                budget: budget
            )
            // 插入点仍在前导空白中时，原生边缘保留的 Tab 列也是本次实际缩进，不能在换行后丢掉。
            let extra = indent.continuesIndentation ? target.leadingSpaces : 0
            guard extra <= remainingOutput, indent.text.utf8.count <= remainingOutput - extra else {
                throw NateError.message("完整换行及缩进超过正文或输出容量，未分配部分继承空白。")
            }
            remainingOutput -= indent.text.utf8.count + extra
            return SelectionInsertionTarget(
                id: target.id,
                range: target.range,
                text: ending + indent.text + String(repeating: " ", count: extra),
                leadingSpaces: target.leadingSpaces,
                trailingSpaces: target.trailingSpaces
            )
        }
        transaction = try PreparedSelectionInsertion(
            snapshot: snapshot,
            targets: converted,
            primaryID: primary,
            name: "换行",
            permit: sharedPermit
        ).transaction
    }

    /// 业务作用：只读取插入点之前实际存在的前导空白，遇到正文立即停止，不复制完整超长逻辑行。
    /// 参数说明:
    /// - text: 本次固定原文。
    /// - offset: 当前目标真实插入位置。
    /// - enabled: 是否继承原缩进。
    /// - remaining: 全部光标共同消耗的缩进读取额度。
    /// - budget: 本次完整换行的共同截止与继续资格。
    /// 返回：原字节缩进及插入点是否仍属于前导空白；超量或失权时明确失败，不截断缩进。
    private static func indentation(
        in text: PieceTree,
        before offset: Int,
        enabled: Bool,
        remaining: inout Int,
        budget: SelectionPreparationBudget
    ) throws -> (text: String, continuesIndentation: Bool) {
        guard enabled else {
            return ("", false)
        }
        let start = text.lineStart(text.lineNumber(at: offset))
        var end = start
        // 每个目标共同消耗原额度，超限须拒绝完整缩进，不能以截断前缀改变其它行的输入位置。
        while end < offset {
            if end & 255 == 0 {
                try budget.check()
            }
            guard remaining > 0 else {
                throw NateError.message("全部换行缩进读取超过 1 MiB，原正文与选择保留。")
            }
            remaining -= 1
            guard let byte = text.byte(at: end), byte == 32 || byte == 9 else {
                break
            }
            end += 1
        }
        try budget.check()
        return (text.text(in: ByteRange(start, end)), end == offset)
    }
}
