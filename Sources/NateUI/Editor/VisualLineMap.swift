import AppKit

struct VisualLineMap {
    var count = 1
    var defaultHeight: CGFloat = 20
    var measured: [Int: CGFloat] = [:]
    var measurementsChanged = false
    var hidden = HiddenLineRanges()

    /// 业务作用：未访问行使用估计高度，只有视口中经过排版的行保留实际高度。
    /// 参数说明:
    /// - line: 真实逻辑行号。
    /// 返回：该行在视图投影中的纵向起点。
    func y(of line: Int) -> CGFloat {
        var value = CGFloat(line) * defaultHeight
        for (index, height) in measured where index < line && !hidden.contains(index) {
            value += height - defaultHeight
        }
        value -= CGFloat(hidden.count(before: line)) * defaultHeight
        return value
    }

    /// 业务作用：像素命中通过投影索引返回真实行，软换行不创建磁盘行号。
    /// 参数说明:
    /// - y: 文档视图中的纵坐标。
    /// 返回：合法且未隐藏的逻辑行。
    func line(at y: CGFloat) -> Int {
        var lower = 0
        var upper = max(1, count)
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if self.y(of: middle) <= y {
                lower = middle
            }
            else {
                upper = middle
            }
        }
        return hidden.visibleAfterOrAt(lower, count: count)
    }

    /// 业务作用：绘制与矩形拖选只枚举可见真实行，跨过巨大折叠区不展开逐行循环。
    /// 参数说明:
    /// - range: 当前视口覆盖的真实行闭区间。
    /// 返回：按文档顺序排列的可见行号。
    func visibleLines(in range: ClosedRange<Int>) -> [Int] {
        var output: [Int] = []
        var line = hidden.visibleAfterOrAt(range.lowerBound, count: count)
        while line >= range.lowerBound && line <= range.upperBound && line < count {
            output.append(line)
            guard line < count - 1 else {
                break
            }
            let next = hidden.visibleAfterOrAt(line + 1, count: count)
            guard next > line else {
                break
            }
            line = next
        }
        return output
    }

    /// 业务作用：上下键按可见行移动，不陷入折叠正文或错误命中其它逻辑行。
    /// 参数说明:
    /// - line: 当前真实行。
    /// - direction: 向上为负，向下为正。
    /// 返回：相邻可见行，文档边界保持当前位置。
    func adjacentLine(to line: Int, direction: Int) -> Int {
        if direction < 0 {
            return hidden.visibleBeforeOrAt(max(0, line - 1))
        }
        return hidden.visibleAfterOrAt(min(count - 1, line + 1), count: count)
    }

    /// 业务作用：只在实际高度改变时调整滚动投影，正文位置保持不变。
    /// 参数说明:
    /// - line: 已排版逻辑行。
    /// - height: 当前视图的实际排版高度。
    /// 返回：记录有界的视图测量状态。
    mutating func measure(_ line: Int, height: CGFloat) {
        let height = max(defaultHeight, height)
        if abs(height - defaultHeight) < 0.5 {
            if measured.removeValue(forKey: line) != nil {
                measurementsChanged = true
            }
        }
        else if measured[line] != height {
            measurementsChanged = true
            measured[line] = height
            if measured.count > 2048,
                let farthest = measured.keys.max(by: {
                    abs($0 - line) < abs($1 - line)
                })
            {
                measured.removeValue(forKey: farthest)
            }
        }
    }
}
