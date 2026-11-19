import AppKit
import NateCore

extension EditorView {
    /// 业务作用：鼠标与键盘在同一真实行投影上准备矩形，所有字形命中和虚拟尾部完成后才发布。
    /// 参数说明:
    /// - anchorRow: 固定的真实逻辑行。
    /// - headRow: 活动的真实逻辑行。
    /// - anchorX: 相对正文左边缘的固定横坐标。
    /// - headX: 相对正文左边缘的活动横坐标。
    /// 返回：完整选择发布时为真；非法跨度、字形证据不足或超时保留原选择。
    @discardableResult
    func setVisualRectangle(anchorRow: Int, headRow: Int, anchorX: Double, headX: Double) -> Bool {
        guard composition == nil, !document.isEditingSuspended,
            (0..<document.text.lineCount).contains(anchorRow),
            (0..<document.text.lineCount).contains(headRow),
            abs(headRow - anchorRow) < 100_000,
            anchorX.isFinite, headX.isFinite,
            (0...1_000_000_000).contains(anchorX), (0...1_000_000_000).contains(headX)
        else {
            onStatus?("矩形选择跨度最多十万行，像素位置必须有效；原选择保留。")
            return false
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            let zero = abs(anchorX - headX) < 0.5
            let width = rectangleColumnWidth
            var selections: [TextSelection] = []
            var trailing: [Int] = []
            for row in projection.visibleLines(in: min(anchorRow, headRow)...max(anchorRow, headRow)) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw NateError.message("矩形字形命中超过两秒，原选择保留。")
                }
                let anchor = try rectangleHit(row: row, x: anchorX)
                let head = try rectangleHit(row: row, x: headX)
                let body = document.text.lineRange(row, includeEnding: false)
                let end = try rectangleCaretX(at: body.upper, virtual: 0)
                let leading = max(0, min(anchorX, headX) - end) / width
                let far = anchorX >= headX ? anchor : head
                let ending = far == body.upper ? max(0, max(anchorX, headX) - end) / width : 0
                guard leading <= 1_000_000, ending <= 1_000_000 else {
                    throw NateError.message("矩形虚拟位置超过一百万列，未建立部分目标。")
                }
                let virtual = anchor == head && head == body.upper ? Int(leading) : 0
                selections.append(TextSelection(anchor: anchor, head: head, virtualColumn: virtual))
                trailing.append(zero ? 0 : max(0, Int(ending) - virtual))
            }
            guard ContinuousClock.now < deadline else {
                throw NateError.message("矩形字形命中超过两秒，原选择保留。")
            }
            return setRectangularSelections(
                selections,
                zeroWidth: zero,
                anchorX: anchorX,
                headX: headX,
                trailingColumns: trailing,
                primaryRow: headRow,
                anchorRow: anchorRow
            )
        }
        catch {
            onStatus?(error.localizedDescription)
            return false
        }
    }

    /// 业务作用：原生命中与相邻完整字形光标共同确定最近视觉边缘，行尾恰好命中也不退回前一个字形。
    /// 参数说明:
    /// - row: 当前可见真实行。
    /// - x: 不含边栏的原生视觉横坐标。
    /// 返回：当前行内完整字形边界；共享上下文不足时失败，不返回近似标量边界。
    func rectangleHit(row: Int, x: Double) throws -> Int {
        let body = document.text.lineRange(row, includeEnding: false)
        let layout = layoutLine(row)
        // 暂停排版的行没有像素到原字节的证据，不能用空布局建立矩形目标。
        if let reason = layout.unavailableReason {
            throw NateError.message(reason)
        }
        let hitY = layout.caret(at: 0).midY
        let raw = min(
            body.upper,
            max(
                body.lower,
                bytePosition(
                    at: NSPoint(
                        x: CGFloat(x) + gutterWidth,
                        y: projection.y(of: row) + 8 + hitY
                    )
                )
            )
        )
        var navigation = try GraphemeNavigation(text: document.text)
        var candidates = [body.lower, body.upper]
        if try navigation.isBoundary(at: raw) {
            candidates.append(raw)
            if raw > body.lower {
                candidates.append(max(body.lower, try navigation.boundary(from: raw, forward: false)))
            }
            if raw < body.upper {
                candidates.append(min(body.upper, try navigation.boundary(from: raw, forward: true)))
            }
        }
        else {
            let cluster = try navigation.range(at: raw, forward: true)
            guard cluster.lower >= body.lower, cluster.upper <= body.upper else {
                throw NateError.invalidRange
            }
            candidates += [cluster.lower, cluster.upper]
        }
        var best: Int?
        var distance = Double.greatestFiniteMagnitude
        for candidate in candidates {
            guard let units = document.text.utf16Offset(byte: candidate) else {
                throw NateError.invalidRange
            }
            let caret = layout.caret(at: units - layout.originUTF16)
            // 一个真实行可能软换行，另一视觉片段的相同横坐标不能把选择跳到段落末尾。
            guard abs(caret.midY - hitY) < max(1, lineHeight / 2) else {
                continue
            }
            let value = abs(Double(caret.minX) - x)
            if value < distance {
                best = candidate
                distance = value
            }
        }
        guard let best else {
            throw NateError.message("当前视觉行没有完整字形边缘，原选择保留。")
        }
        return best
    }
}
