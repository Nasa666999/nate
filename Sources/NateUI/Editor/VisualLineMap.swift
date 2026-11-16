import AppKit

struct VisualLineMap {
    var count = 1
    var defaultHeight: CGFloat = 20
    var measured: [Int: CGFloat] = [:]
    var hidden: Set<Int> = []

    /// 业务作用：未访问行使用估计高度，只有视口中经过排版的行保留实际高度。
    /// 参数说明:
    /// - line: 真实逻辑行号。
    /// 返回：该行在视图投影中的纵向起点。
    func y(of line: Int) -> CGFloat {
        var value = CGFloat(line) * defaultHeight
        for (index, height) in measured where index < line && !hidden.contains(index) {
            value += height - defaultHeight
        }
        value -=
            CGFloat(
                hidden.filter {
                    $0 < line
                }.count
            ) * defaultHeight
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
        while lower < count - 1 && hidden.contains(lower) {
            lower += 1
        }
        return lower
    }

    /// 业务作用：只在实际高度改变时调整滚动投影，正文位置保持不变。
    /// 参数说明:
    /// - line: 已排版逻辑行。
    /// - height: 当前视图的实际排版高度。
    /// 返回：记录有界的视图测量状态。
    mutating func measure(_ line: Int, height: CGFloat) {
        let height = max(defaultHeight, height)
        if abs(height - defaultHeight) < 0.5 {
            measured.removeValue(forKey: line)
        }
        else {
            measured[line] = height
        }
    }
}
