import AppKit

struct LineVisualCaret {
    let offset: Int
    let atLeadingEdge: Bool
}

extension LineLayout {
    /// 业务作用：按实际原生视觉行导航，普通段落、空行和有界软换行共享同一入口。
    /// 参数说明: 无。
    /// 返回：完整逻辑行在当前视图中的视觉行数。
    var visualRowCount: Int {
        if let window = wideLine as? WrappedASCIIWindow {
            return window.rowCount
        }
        return max(1, nativeLines.count)
    }

    /// 业务作用：由原逻辑行的插入位置及当前亲和性确定所属真实视觉行。
    /// 参数说明:
    /// - local: 相对完整逻辑行的 UTF-16 位置。
    /// - downstream: 同一断点是否处于下一视觉行。
    /// 返回：有效的视觉行号；当前几何无效时为空。
    func visualRow(containing local: Int, downstream: Bool) -> Int? {
        guard unavailableReason == nil, (0...characterCount).contains(local) else {
            return nil
        }
        if let window = wideLine as? WrappedASCIIWindow {
            return window.visualRow(containing: local, downstream: downstream)
        }
        if local == characterCount {
            return visualRowCount - 1
        }
        return nativeVisualRow(containing: local, downstream: downstream)
    }

    /// 业务作用：以实际视觉行和目标横坐标选择原生插入端点，超过短行宽度时保留该行自己的末端。
    /// 参数说明:
    /// - row: 当前完整逻辑行的视觉行号。
    /// - x: 当前来源视图实际像素横坐标。
    /// 返回：真实 UTF-16 端点及其所在行的前沿身份；没有布局证据时为空。
    func visualCaret(in row: Int, x: CGFloat) -> LineVisualCaret? {
        guard (0..<visualRowCount).contains(row), x.isFinite, unavailableReason == nil else {
            return nil
        }
        if let window = wideLine as? WrappedASCIIWindow {
            let result = window.visualCaret(in: row, x: x)
            synchronizeWideProjection()
            return result
        }
        if characterCount == 0 {
            return LineVisualCaret(offset: 0, atLeadingEdge: true)
        }
        guard nativeLines.indices.contains(row) else {
            return nil
        }
        let native = nativeLines[row]
        let measured = native.character(at: NSPoint(x: x, y: native.bounds.midY))
        let offset = min(native.upper, max(native.lower, measured))
        return LineVisualCaret(offset: offset, atLeadingEdge: offset == native.lower)
    }

    /// 业务作用：光标和字符标记沿原生端点选择断点的上游或下游行。
    /// 参数说明:
    /// - local: 当前原生段落内的 UTF-16 位置。
    /// - downstream: 在共享端点处使用实际后继视觉行时为真。
    /// 返回：真实原生行索引，系统未给出适用范围时为空。
    func nativeVisualRow(containing local: Int, downstream: Bool) -> Int? {
        guard orderedPositions else {
            return nativeLines.firstIndex {
                local >= $0.lower && (downstream ? local < $0.upper : local <= $0.upper)
            }
        }
        var lower = 0
        var upper = nativeLines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if downstream ? nativeLines[middle].upper <= local : nativeLines[middle].upper < local {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard nativeLines.indices.contains(lower), local >= nativeLines[lower].lower else {
            return nil
        }
        return lower
    }
}
