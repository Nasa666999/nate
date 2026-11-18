import Foundation

public enum DocumentMarkStyle: Int, Sendable, CaseIterable {
    case search
    case style1
    case style2
    case style3
    case style4
    case style5
}

struct DocumentMarkIndex: Sendable, Equatable {
    let ranges: [ByteRange]
    let painting: [ByteRange]

    /// 业务作用：匹配范围保留独立导航身份，绘制范围合并交叠，重复覆盖不放大每帧着色工作量。
    /// 参数说明:
    /// - ranges: 已按起点、终点排序并去重的合法范围，允许零长度匹配。
    /// 返回：只含位置的匹配与不交叠绘制索引，不保留正文。
    init(ranges: [ByteRange]) {
        self.ranges = ranges
        var merged: [ByteRange] = []
        for range in ranges {
            if let last = merged.last, range.lower <= last.upper {
                merged[merged.count - 1] = ByteRange(last.lower, max(last.upper, range.upper))
            }
            else {
                merged.append(range)
            }
        }
        painting = merged
    }
}

public struct DocumentMarkState: Sendable, Equatable {
    var groups: [DocumentMarkStyle: DocumentMarkIndex] = [:]

    /// 业务作用：文档颜色标记从独立空集合开始，普通搜索与语法分析不能隐式创建或共享用户标记。
    /// 参数说明: 无。
    /// 返回：查找及五组样式均为空的状态。
    public init() {}

    /// 业务作用：为容量、清除和状态反馈提供实际独立标记总数。
    /// 参数说明: 无。
    /// 返回：查找与五组样式内去重后的范围数量，最多十万项。
    public var count: Int {
        groups.values.reduce(0) {
            $0 + $1.ranges.count
        }
    }

    /// 业务作用：颜色组独立保留每条匹配，用于导航与复制而不借用合并后的绘制范围。
    /// 参数说明:
    /// - style: 查找标记或五组持久样式之一。
    /// 返回：按源位置排序并去重的完整匹配范围，未设置样式为空。
    public func ranges(for style: DocumentMarkStyle) -> [ByteRange] {
        groups[style]?.ranges ?? []
    }

    /// 业务作用：视口只查询相交的合并绘制范围，文档外的标记不增加当前行的线性扫描。
    /// 参数说明:
    /// - style: 当前要绘制的独立颜色组。
    /// - range: 已提交正文中的视口或逻辑行范围。
    /// - limit: 本次查询允许返回的完整范围数量。
    /// 返回：有界相交范围，密度超限整体失败而不冒充完整绘制集合。
    public func displayRanges(
        for style: DocumentMarkStyle,
        intersecting range: ByteRange,
        limit: Int = 4096
    ) throws -> [ByteRange] {
        guard limit >= 0, range.lower >= 0, range.upper >= range.lower else {
            throw NateError.invalidRange
        }
        let ranges = groups[style]?.painting ?? []
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upper < range.lower {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        var output: [ByteRange] = []
        for value in ranges.dropFirst(lower) {
            if value.lower > range.upper {
                break
            }
            if !value.isEmpty && (value.upper <= range.lower || value.lower >= range.upper) {
                continue
            }
            guard output.count < limit else {
                throw NateError.message("当前可见标记过密，标记数据保留；请缩小视口或清除部分样式。")
            }
            output.append(value)
        }
        return output
    }

    /// 业务作用：用户清除只移除指定颜色或全部持久标记，不影响正文和书签。
    /// 参数说明:
    /// - style: 单个颜色组，空值表示全部组。
    /// 返回：移除指定组后的独立值，未涉及组原样保留。
    func removing(_ style: DocumentMarkStyle?) -> DocumentMarkState {
        var result = self
        if let style {
            result.groups.removeValue(forKey: style)
        }
        else {
            result.groups.removeAll()
        }
        return result
    }

    /// 业务作用：颜色范围按事务锚点映射，边界插入排除在范围外，内部插入扩张范围，完全替换的原范围移除。
    /// 参数说明:
    /// - positions: 当前提交、撤销或重做的完整位置映射。
    /// 返回：映射后的去重状态，零长度标记保持后侧锚点，不从历史恢复用户后来清除的颜色组。
    func mapped(through positions: PositionMap) -> DocumentMarkState {
        var result = DocumentMarkState()
        for (style, index) in groups {
            var distinct: Set<ByteRange> = []
            for range in index.ranges {
                let start = positions.map(range.lower, affinity: .after)
                if range.isEmpty {
                    distinct.insert(ByteRange(start, start))
                }
                else {
                    let end = positions.map(range.upper, affinity: .before)
                    if start < end {
                        distinct.insert(ByteRange(start, end))
                    }
                }
            }
            if !distinct.isEmpty {
                result.groups[style] = DocumentMarkIndex(
                    ranges: distinct.sorted {
                        $0.lower == $1.lower ? $0.upper < $1.upper : $0.lower < $1.lower
                    }
                )
            }
        }
        return result
    }
}
