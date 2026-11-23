import Foundation

struct ChangeHistoryCount: Sendable {
    var edition: Int
    var count: Int
}

struct ChangeHistoryDeletion: Sendable {
    var position: Int
    var editions: [ChangeHistoryCount]
}

struct ChangeHistorySpan: Sendable {
    var position: Int
    var length: Int
    var edition: Int
    var count: Int
    var insertion: Bool
}

struct ChangeHistoryLog: Sendable {
    var work = ChangeHistoryWork()
    var runs: ChangeHistoryRuns
    var deletions: [ChangeHistoryDeletion] = []
    var steps: [Int] = []
    var spans: [ChangeHistorySpan] = []

    /// 业务作用：插入和删除共用同一正文长度，删除位置另以稀疏记录保留。
    /// 参数说明:
    /// - length: 当前正文原字节长度。
    /// 返回：未修改的完整历史日志。
    init(length: Int) {
        runs = ChangeHistoryRuns(length: length)
    }

    /// 业务作用：按原字节位置定位删除记录，正文没有删除时不产生逐字符占位。
    /// 参数说明:
    /// - position: 当前正文中的删除锚点。
    /// 返回：首个不小于目标位置的有序记录下标。
    func deletionIndex(at position: Int) -> Int {
        var lower = 0
        var upper = deletions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if deletions[middle].position < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower
    }

    /// 业务作用：同一删除位置保留按发生顺序排列的类别与重复计数。
    /// 参数说明:
    /// - position: 当前正文中的精确删除锚点。
    /// 返回：该点完整的有序类别；没有记录时为空。
    func editions(at position: Int) -> [ChangeHistoryCount] {
        let index = deletionIndex(at: position)
        return index < deletions.count && deletions[index].position == position
            ? deletions[index].editions : []
    }

    /// 业务作用：插入正文时移动删除锚点，插入点原有删除归属新文字之后。
    /// 参数说明:
    /// - position: 本次插入起点。
    /// - count: 插入的原字节长度。
    /// 返回：区间及全部后续删除位置同步前移。
    mutating func insertSpace(at position: Int, count: Int) throws {
        try runs.insertSpace(at: position, count: count)
        let first = deletionIndex(at: position)
        for index in first..<deletions.count {
            if index & 255 == 0 {
                try work.check()
            }
            deletions[index].position += count
        }
    }

    /// 业务作用：删除正文后保留起点已有证据，后继删除锚点按实际字节收拢。
    /// 参数说明:
    /// - position: 删除起点。
    /// - count: 删除的原字节长度。
    /// 返回：正文区间及删除索引共同收缩，范围内部证据由调用方提前保存。
    mutating func delete(at position: Int, count: Int) throws {
        let original = editions(at: position)
        let end = position + count
        try runs.delete(at: position, count: count)
        var result: [ChangeHistoryDeletion] = []
        for (index, entry) in deletions.enumerated() {
            if index & 255 == 0 {
                try work.check()
            }
            if entry.position < position {
                result.append(entry)
            }
            else if entry.position >= end {
                result.append(
                    ChangeHistoryDeletion(position: entry.position - count, editions: entry.editions)
                )
            }
        }
        deletions = result
        if !original.isEmpty {
            setEditions(original, at: position)
        }
    }

    /// 业务作用：删除前保留原修改类别及内部删除顺序，撤销可恢复完整证据。
    /// 参数说明:
    /// - position: 即将删除的原范围起点。
    /// - count: 即将移除的原字节长度。
    /// 返回：完整逆向记录和收拢删除证据建立；容量不足时外层候选整体拒绝。
    mutating func saveHistory(at position: Int, count: Int) throws {
        guard steps.count < 1_000_000 else {
            throw NateError.message("修改历史删除步骤超过一百万项，未采用部分记录。")
        }
        steps.append(0)
        let end = position + count
        var cursor = position
        if runs.value(at: cursor) == 0 {
            cursor = runs.end(at: cursor)
        }
        while cursor < end {
            try work.check()
            let next = runs.end(at: cursor)
            try pushSpan(
                ChangeHistorySpan(
                    position: cursor,
                    length: min(next, end) - cursor,
                    edition: runs.value(at: cursor),
                    count: 1,
                    insertion: true
                )
            )
            cursor = runs.end(at: next)
        }
        let first = deletionIndex(at: position + 1)
        let last = deletionIndex(at: end + 1)
        let collapsed = Array(deletions[first..<last])
        for entry in collapsed {
            try work.check()
            for edition in entry.editions {
                try pushSpan(
                    ChangeHistorySpan(
                        position: entry.position,
                        length: 0,
                        edition: edition.edition,
                        count: edition.count,
                        insertion: false
                    )
                )
            }
        }
        for entry in collapsed {
            try work.check()
            for (index, edition) in entry.editions.enumerated() {
                if index & 255 == 0 {
                    try work.check()
                }
                pushDeletion(at: position, value: edition)
            }
            setEditions([], at: entry.position)
        }
        try validateCapacity()
    }

    /// 业务作用：恢复删除正文后拆回原有删除锚点及区间类别，不将新文字冒充原修改。
    /// 参数说明:
    /// - position: 已重新插入原文的起点。
    /// - count: 本次恢复的原字节长度。
    /// 返回：消费一个完整逆向步骤；缺失或不一致记录时拒绝候选。
    mutating func restoreDeletion(at position: Int, count: Int) throws {
        let values = editions(at: position + count)
        guard !values.isEmpty, let total = steps.popLast() else {
            throw NateError.message("修改历史缺少完整删除记录，未采用部分恢复。")
        }
        setEditions([], at: position + count)
        setEditions(values, at: position)
        try popDeletion(at: position, count: 1)
        var remaining = total
        while remaining > 0 {
            try work.check()
            guard var span = spans.popLast() else {
                throw NateError.message("修改历史逆向区间不完整，未采用部分恢复。")
            }
            let consumed = min(remaining, span.count)
            if consumed < span.count {
                let original = span
                span.count = consumed
                var rest = original
                rest.count -= consumed
                spans.append(rest)
            }
            if span.insertion {
                guard span.count == 1 else {
                    throw NateError.message("修改历史插入计数无效，未采用部分恢复。")
                }
                try runs.fill(at: span.position, count: span.length, edition: span.edition)
            }
            else {
                guard editions(at: position).last?.edition == span.edition else {
                    throw NateError.message("修改历史删除类别不一致，未采用部分恢复。")
                }
                try popDeletion(at: position, count: span.count)
                var original = editions(at: span.position)
                original.insert(ChangeHistoryCount(edition: span.edition, count: span.count), at: 0)
                setEditions(original, at: span.position)
            }
            remaining -= consumed
        }
    }

    /// 业务作用：多个删除落在同一锚点时保留顺序并压缩相邻相同类别。
    /// 参数说明:
    /// - position: 删除锚点。
    /// - value: 新增的类别及重复次数。
    /// 返回：完整顺序记录加入该锚点。
    mutating func pushDeletion(at position: Int, value: ChangeHistoryCount) {
        var original = editions(at: position)
        if original.last?.edition == value.edition {
            original[original.count - 1].count += value.count
        }
        else {
            original.append(value)
        }
        setEditions(original, at: position)
    }

    /// 业务作用：成功保存保留历史位置，将当前和逆向记录中的未保存证据转为已保存。
    /// 参数说明: 无。
    /// 返回：原有历史、删除顺序及撤销步骤保持，只有保存类别改变。
    mutating func save() throws {
        try runs.save()
        for index in spans.indices {
            if index & 255 == 0 {
                try work.check()
            }
            if spans[index].edition == 3 {
                spans[index].edition = 2
            }
        }
        for index in deletions.indices {
            if index & 255 == 0 {
                try work.check()
            }
            for inner in deletions[index].editions.indices {
                if inner & 255 == 0 {
                    try work.check()
                }
                if deletions[index].editions[inner].edition == 3 {
                    deletions[index].editions[inner].edition = 2
                }
            }
        }
    }

    /// 业务作用：稀疏记录和逆向栈共享有限容量，密集编辑不能无限保留显示元数据。
    /// 参数说明: 无。
    /// 返回：所有索引和计数在预算内时通过，否则拒绝完整候选。
    func validateCapacity() throws {
        try work.check()
        var editions = 0
        for (index, deletion) in deletions.enumerated() {
            if index & 255 == 0 {
                try work.check()
            }
            editions += deletion.editions.count
        }
        var count = 0
        for (index, step) in steps.enumerated() {
            if index & 255 == 0 {
                try work.check()
            }
            count += step
        }
        guard deletions.count <= 65_536, spans.count <= 1_000_000,
            editions <= 1_000_000, count <= 1_000_000
        else {
            throw NateError.message("修改历史删除索引或逆向记录超过容量，未采用部分记录。")
        }
    }

    /// 业务作用：逆向步骤准确记录需恢复的类别数量，相邻同类删除可跨步骤压缩但不丢计数。
    /// 参数说明:
    /// - span: 当前删除步骤需保留的区间或锚点。
    /// 返回：记录和步骤总数同步增加，超量时拒绝候选。
    private mutating func pushSpan(_ span: ChangeHistorySpan) throws {
        try work.check()
        guard let lastStep = steps.last, lastStep <= 1_000_000 - span.count else {
            throw NateError.message("修改历史单步逆向记录超过容量，未采用部分记录。")
        }
        steps[steps.count - 1] += span.count
        if !span.insertion, let last = spans.last, !last.insertion,
            last.position == span.position, last.edition == span.edition
        {
            spans[spans.count - 1].count += span.count
        }
        else {
            spans.append(span)
        }
    }

    /// 业务作用：消费锚点末尾的精确删除次数，恢复过程不能跨越其它类别的顺序证据。
    /// 参数说明:
    /// - position: 当前恢复锚点。
    /// - count: 需要移除的末尾重复次数。
    /// 返回：完整次数可用时消费，否则拒绝候选。
    private mutating func popDeletion(at position: Int, count: Int) throws {
        var original = editions(at: position)
        guard let last = original.last, count > 0, last.count >= count else {
            throw NateError.message("修改历史删除次数不完整，未采用部分恢复。")
        }
        if last.count == count {
            original.removeLast()
        }
        else {
            original[original.count - 1].count -= count
        }
        setEditions(original, at: position)
    }

    /// 业务作用：同一位置只保留一份完整有序类别，清空后不留下无意义占位。
    /// 参数说明:
    /// - values: 已准备的完整有序类别。
    /// - position: 当前正文中的精确锚点。
    /// 返回：原记录整体替换、移除或插入，位置排序保持。
    private mutating func setEditions(_ values: [ChangeHistoryCount], at position: Int) {
        let index = deletionIndex(at: position)
        if index < deletions.count, deletions[index].position == position {
            if values.isEmpty {
                deletions.remove(at: index)
            }
            else {
                deletions[index].editions = values
            }
        }
        else if !values.isEmpty {
            deletions.insert(ChangeHistoryDeletion(position: position, editions: values), at: index)
        }
    }
}
