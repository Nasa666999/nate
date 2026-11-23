import AppKit
import NateCore

@MainActor
struct EditorModificationFrame {
    let snapshot: DocumentModificationSnapshot
    var remaining: Duration = .milliseconds(8)
    var ranges = 4096
}

extension EditorView {
    /// 业务作用：当前帧只使用同一正文修订的完整修改分类，输入法投影不冒用提交正文的字节坐标。
    /// 参数说明: 无。
    /// 返回：分类开启且来源完整时的共享预算，关闭、候选或分类暂停时不绘制历史。
    func modificationFrame() -> EditorModificationFrame? {
        guard showModificationHistory, composition == nil, let snapshot = document.modificationSnapshot,
            snapshot.documentID == document.id, snapshot.revision == document.revision
        else {
            return nil
        }
        return EditorModificationFrame(snapshot: snapshot)
    }

    /// 业务作用：正文修改沿实际字形绘制下划线与删除锚点，全部几何确认后才发布本行路径。
    /// 参数说明:
    /// - layout: 当前正文行的完整可用原生排版。
    /// - y: 该逻辑行的实际视图纵坐标。
    /// - frame: 当前帧共享的固定分类、时间及结果容量。
    /// - context: 当前绘图上下文。
    /// 返回：只改变可见正文的呈现；超量或定位失败时暂停后续指示并保留正文与选择。
    func drawModificationIndicators(
        in layout: LineLayout,
        y: CGFloat,
        frame: inout EditorModificationFrame?,
        context: CGContext
    ) {
        guard let source = frame else {
            return
        }
        let started = ContinuousClock.now
        defer {
            frame?.remaining -= ContinuousClock.now - started
        }
        do {
            let deadline = started.advanced(by: max(.zero, source.remaining))
            var body = visibleRect
            body.origin.x += gutterWidth
            body.size.width = max(0, body.width - gutterWidth)
            let viewport = body.offsetBy(dx: -gutterWidth, dy: -y)
            let parts = layout.range.isEmpty ? [layout.range] : layout.visibleByteRanges(in: viewport)
            var paths: [ModificationEdition: CGMutablePath] = [:]
            var remaining = source.ranges
            let scale = max(1, window?.backingScaleFactor ?? 1)
            for part in parts {
                guard remaining > 0 else {
                    throw NateError.message("修改历史指示超过当前帧 4096 项容量。")
                }
                let runs = try source.snapshot.runs(in: part, maximumCount: remaining, deadline: deadline)
                remaining -= runs.count
                let deleted = try source.snapshot.deletions(
                    in: part,
                    maximumCount: max(1, remaining),
                    deadline: deadline
                )
                guard deleted.count <= remaining else {
                    throw NateError.message("修改历史删除锚点超过当前帧剩余容量。")
                }
                remaining -= deleted.count
                for run in runs {
                    guard ContinuousClock.now < deadline else {
                        throw NateError.message("修改历史字形定位超过当前帧计算截止。")
                    }
                    let path = paths[run.edition] ?? CGMutablePath()
                    for rect in layout.selectionRects(run.range) {
                        path.move(to: CGPoint(x: gutterWidth + rect.minX, y: y + rect.maxY - 2 / scale))
                        path.addLine(to: CGPoint(x: gutterWidth + rect.maxX, y: y + rect.maxY - 2 / scale))
                    }
                    paths[run.edition] = path
                }
                for point in deleted {
                    guard ContinuousClock.now < deadline,
                        point.position >= layout.renderedRange.lower,
                        point.position <= layout.renderedRange.upper,
                        let offset = displayTree.utf16Offset(byte: point.position)
                    else {
                        throw NateError.message("修改历史删除锚点缺少当前字形证据或超过截止。")
                    }
                    let caret = layout.caret(at: offset - layout.originUTF16)
                    for (index, edition) in point.editions.enumerated() {
                        let path = paths[edition] ?? CGMutablePath()
                        let x = gutterWidth + caret.minX + CGFloat(index) * 2 / scale
                        let bottom = y + caret.maxY - 2 / scale
                        path.move(to: CGPoint(x: x, y: bottom - 4))
                        path.addLine(to: CGPoint(x: x, y: bottom))
                        path.addLine(to: CGPoint(x: x + 3, y: bottom - 2))
                        paths[edition] = path
                    }
                }
            }
            guard ContinuousClock.now < deadline else {
                throw NateError.message("修改历史指示超过当前帧计算截止。")
            }
            context.saveGState()
            context.clip(to: body)
            context.setLineWidth(1 / scale)
            for edition in ModificationEdition.allCases {
                if let path = paths[edition] {
                    modificationColor(edition).setStroke()
                    context.addPath(path)
                    context.strokePath()
                }
            }
            context.restoreGState()
            frame?.ranges = remaining
        }
        catch {
            frame = nil
            modificationDisplayStatus = "修改历史指示已暂停，正文保持：" + error.localizedDescription
        }
    }

    /// 业务作用：边栏联合该逻辑行的插入和删除类别，多种状态并列显示且不占用折叠与书签命中范围。
    /// 参数说明:
    /// - line: 当前可见真实逻辑行。
    /// - frame: 当前帧的固定分类及共享计算余量。
    /// 返回：完整分类在四个固定细栏中显示；来源或预算不足时不猜测该行颜色。
    func drawModificationMarker(line: Int, frame: inout EditorModificationFrame?) {
        guard let source = frame else {
            return
        }
        let started = ContinuousClock.now
        defer {
            frame?.remaining -= ContinuousClock.now - started
        }
        do {
            let deadline = started.advanced(by: max(.zero, source.remaining))
            let tree = document.text
            let editions = try source.snapshot.editions(
                in: tree.lineRange(line, includeEnding: true),
                bodyEnd: tree.lineRange(line, includeEnding: false).upper,
                deadline: deadline
            )
            themeColor(
                .modificationBackground,
                fallback: themeColor(.gutterBackground, fallback: .windowBackgroundColor)
            ).setFill()
            NSRect(
                x: visibleRect.minX + gutterWidth - 24,
                y: projection.y(of: line) + 8,
                width: 8,
                height: lineHeight
            ).fill()
            for edition in editions {
                modificationColor(edition).setFill()
                NSRect(
                    x: visibleRect.minX + gutterWidth - 24 + CGFloat(edition.rawValue - 1) * 2,
                    y: projection.y(of: line) + 8,
                    width: 2,
                    height: lineHeight
                ).fill()
            }
        }
        catch {
            frame = nil
            modificationDisplayStatus = "修改历史边栏已暂停，正文保持：" + error.localizedDescription
        }
    }

    /// 业务作用：正文和边栏采用同一修改类别配色，已保存与两种撤销状态分别保留自己的主题角色。
    /// 参数说明:
    /// - edition: 已验证的原生修改类别。
    /// 返回：当前主题明确颜色或对应系统默认颜色。
    func modificationColor(_ edition: ModificationEdition) -> NSColor {
        switch edition {
        case .revertedOriginal: themeColor(.modificationRevertedOriginal, fallback: .systemTeal)
        case .saved: themeColor(.modificationSaved, fallback: .systemGreen)
        case .unsaved: themeColor(.modificationUnsaved, fallback: .systemOrange)
        case .revertedChange: themeColor(.modificationRevertedChange, fallback: .systemYellow)
        }
    }
}
