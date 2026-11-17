import Foundation

struct HiddenLineRanges {
    private(set) var ranges: [Range<Int>] = []
    private var prefixes: [Int] = []
    var isEmpty: Bool {
        ranges.isEmpty
    }

    /// 业务作用：用合并区间保存隐藏行，折叠百万行不为每行分配一个集合元素。
    /// 参数说明:
    /// - ranges: 待隐藏的真实行半开范围。
    /// 返回：排序、去重且互不相邻的区间及计数前缀。
    init(_ ranges: [Range<Int>] = []) {
        let bounded = ranges.map {
            max(1, $0.lowerBound)..<max(1, $0.upperBound)
        }
        for range in bounded.filter({
            !$0.isEmpty
        }).sorted(by: {
            $0.lowerBound < $1.lowerBound
        }) {
            if let last = self.ranges.last, last.upperBound >= range.lowerBound {
                self.ranges[self.ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            }
            else {
                self.ranges.append(range)
            }
        }
        var count = 0
        for range in self.ranges {
            prefixes.append(count)
            count += range.count
        }
    }

    /// 业务作用：取消折叠投影时同时撤销旧计数，避免新正文复用失效行位置。
    /// 参数说明: 无。
    /// 返回：全部行恢复可见。
    mutating func removeAll() {
        ranges.removeAll()
        prefixes.removeAll()
    }

    /// 业务作用：二分定位可能包含目标行的隐藏区间，不逐行遍历折叠正文。
    /// 参数说明:
    /// - line: 非负真实行号。
    /// 返回：起点不大于该行的最后一个区间索引，没有前驱时为空。
    private func predecessor(_ line: Int) -> Int? {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].lowerBound <= line {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    /// 业务作用：绘制和命中共用同一隐藏判定，避免折叠行仍占用可点击空间。
    /// 参数说明:
    /// - line: 真实行号。
    /// 返回：该行属于当前隐藏区间时为真。
    func contains(_ line: Int) -> Bool {
        predecessor(line).map {
            ranges[$0].contains(line)
        } ?? false
    }

    /// 业务作用：通过区间前缀扣除目标行之前的隐藏高度，不随折叠正文规模增长查询成本。
    /// 参数说明:
    /// - line: 投影目标行或文档末端。
    /// 返回：严格位于目标行之前的隐藏行总数。
    func count(before line: Int) -> Int {
        guard let index = predecessor(line) else {
            return 0
        }
        return prefixes[index] + min(line, ranges[index].upperBound) - ranges[index].lowerBound
    }

    /// 业务作用：向上导航或文档尾部命中时直接跨过整段折叠行。
    /// 参数说明:
    /// - line: 当前有效行或范围内待命中的行。
    /// 返回：不晚于目标的最近可见行；首行保持可见。
    func visibleBeforeOrAt(_ line: Int) -> Int {
        if let index = predecessor(line), ranges[index].contains(line) {
            return max(0, ranges[index].lowerBound - 1)
        }
        return max(0, line)
    }

    /// 业务作用：向下导航或折叠高度边界命中时直接跨过整段隐藏行。
    /// 参数说明:
    /// - line: 待查真实行。
    /// - count: 当前正文的真实行总数。
    /// 返回：存在后继时取最近可见行，折叠延伸到文档尾部时取最后可见行。
    func visibleAfterOrAt(_ line: Int, count: Int) -> Int {
        let line = max(0, min(max(0, count - 1), line))
        if let index = predecessor(line), ranges[index].contains(line) {
            if ranges[index].upperBound < count {
                return ranges[index].upperBound
            }
            return visibleBeforeOrAt(line)
        }
        return line
    }
}
