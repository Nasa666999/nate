import Foundation

struct ChangeHistoryRun: Sendable, Equatable {
    var lower: Int
    var upper: Int
    var edition: Int
}

struct ChangeHistoryRuns: Sendable {
    var work = ChangeHistoryWork()
    private(set) var length: Int
    private(set) var values: [ChangeHistoryRun]

    /// 业务作用：原始正文以单个连续区间表示，文件容量不转化为逐字节修改元数据。
    /// 参数说明:
    /// - length: 已验证正文的原字节长度。
    /// 返回：没有修改的完整区间索引，空正文不分配虚构字符。
    init(length: Int) {
        self.length = length
        values = length == 0 ? [] : [ChangeHistoryRun(lower: 0, upper: length, edition: 0)]
    }

    /// 业务作用：绘制和历史恢复只定位包含目标原字节的连续区间。
    /// 参数说明:
    /// - position: 当前正文中的原字节位置，允许末尾哨兵。
    /// 返回：包含位置的区间下标；末尾返回数组长度。
    func index(at position: Int) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle].upper <= position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower
    }

    /// 业务作用：原生区间在末尾继续提供最后类别，逆向插入才能保留删除前的边界归属。
    /// 参数说明:
    /// - position: 已验证的原字节位置。
    /// 返回：所属区间的原生修改类别；末尾沿最后区间，空正文为零。
    func value(at position: Int) -> Int {
        let offset = index(at: position)
        return offset < values.count ? values[offset].edition : values.last?.edition ?? 0
    }

    /// 业务作用：区间式遍历跳过整段相同状态，长行不逐字节扫描修改类别。
    /// 参数说明:
    /// - position: 当前扫描位置，允许末尾。
    /// 返回：所属区间的排他末端；正文末尾继续返回末尾。
    func end(at position: Int) -> Int {
        let offset = index(at: position)
        return offset < values.count ? values[offset].upper : length
    }

    /// 业务作用：原生历史插入空位时保留边界归属，恢复覆盖层不能误继承右侧修改。
    /// 参数说明:
    /// - position: 插入位置。
    /// - count: 新增的原字节数。
    /// 返回：区间和长度一起推进；元数据超量时由外层完整候选拒绝发布。
    mutating func insertSpace(at position: Int, count: Int) throws {
        let offset = index(at: position)
        var edition = offset < values.count ? values[offset].edition : values.last?.edition ?? 0
        if position == 0 {
            edition = 0
        }
        else if offset < values.count, values[offset].lower == position, edition != 0 {
            edition = values[offset - 1].edition
        }
        try replace(position: position, removed: 0, inserted: count, edition: edition)
    }

    /// 业务作用：删除正文区间时移动全部后续修改证据，不把旧行号保留为另一行的修改。
    /// 参数说明:
    /// - position: 删除起点。
    /// - count: 被移除的原字节数。
    /// 返回：区间完整收缩并合并相邻同类状态。
    mutating func delete(at position: Int, count: Int) throws {
        try replace(position: position, removed: count, inserted: 0, edition: 0)
    }

    /// 业务作用：已确认的连续修改范围整体采用同一原生类别，不改变正文长度。
    /// 参数说明:
    /// - position: 范围起点。
    /// - count: 范围原字节长度。
    /// - edition: 原始、已保存、未保存或撤销覆盖层的内部类别。
    /// 返回：完整范围被替换，邻接相同类别保持单一连续区间。
    mutating func fill(at position: Int, count: Int, edition: Int) throws {
        try replace(position: position, removed: count, inserted: count, edition: edition)
    }

    /// 业务作用：成功保存只转换未保存类别，原始正文及已保存修改区间继续保留。
    /// 参数说明: 无。
    /// 返回：同类相邻区间合并，不清空修改历史。
    mutating func save() throws {
        var result: [ChangeHistoryRun] = []
        for (index, run) in values.enumerated() {
            if index & 255 == 0 {
                try work.check()
            }
            Self.append(
                ChangeHistoryRun(
                    lower: run.lower,
                    upper: run.upper,
                    edition: run.edition == 3 ? 2 : run.edition
                ),
                to: &result
            )
        }
        values = result
    }

    /// 业务作用：区间替换保持完整有序覆盖，元数据容量不足不能发布截断的修改证据。
    /// 参数说明:
    /// - position: 原范围起点。
    /// - removed: 原范围长度。
    /// - inserted: 替换后的长度。
    /// - edition: 替换范围的修改类别。
    /// 返回：候选区间完整合法时替换；长度或区间数量超量时拒绝。
    private mutating func replace(position: Int, removed: Int, inserted: Int, edition: Int) throws {
        try work.check()
        guard position >= 0, removed >= 0, inserted >= 0, position <= length,
            removed <= length - position, inserted <= Int.max / 2 - (length - removed)
        else {
            throw NateError.message("修改历史范围或正文长度无效，未采用部分记录。")
        }
        let end = position + removed
        let delta = inserted - removed
        var result: [ChangeHistoryRun] = []
        result.reserveCapacity(min(65_536, values.count + 2))
        for (index, run) in values.enumerated() {
            if index & 255 == 0 {
                try work.check()
            }
            guard run.lower < position else {
                continue
            }
            Self.append(
                ChangeHistoryRun(lower: run.lower, upper: min(run.upper, position), edition: run.edition),
                to: &result
            )
        }
        Self.append(
            ChangeHistoryRun(lower: position, upper: position + inserted, edition: edition),
            to: &result
        )
        for (index, run) in values.enumerated() {
            if index & 255 == 0 {
                try work.check()
            }
            guard run.upper > end else {
                continue
            }
            Self.append(
                ChangeHistoryRun(
                    lower: max(run.lower, end) + delta,
                    upper: run.upper + delta,
                    edition: run.edition
                ),
                to: &result
            )
        }
        guard result.count <= 65_536 else {
            throw NateError.message("修改历史连续区间超过 65536 项，未采用部分记录。")
        }
        length += delta
        values = result
    }

    /// 业务作用：合并相邻同类修改，区间数量随修改边界增长而不随正文长度增长。
    /// 参数说明:
    /// - run: 已验证的下一个有序候选区间。
    /// - result: 本次完整候选的已建立区间。
    /// 返回：空范围被忽略，其余范围完整加入或与相邻同类区间合并。
    private static func append(_ run: ChangeHistoryRun, to result: inout [ChangeHistoryRun]) {
        guard run.lower < run.upper else {
            return
        }
        if let last = result.last, last.upper == run.lower, last.edition == run.edition {
            result[result.count - 1].upper = run.upper
        }
        else {
            result.append(run)
        }
    }
}
