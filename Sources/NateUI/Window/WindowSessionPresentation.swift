import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：从实际窗口和分屏控件固定各自的正文、选择、视口及布局，而不取得写入原文件的权限。
    /// 参数说明:
    /// - tabs: 此窗口已登记的完整标签顺序。
    /// 返回：原生窗口和主编辑视图齐备时的窗口快照，尚未创建完整控件时为空。
    public func windowSession(tabs: [UUID]) -> WindowSession? {
        guard let window, let primary = scroll.documentView as? EditorView else {
            return nil
        }
        let secondary =
            (editorSplit.arrangedSubviews.dropFirst().first as? NSScrollView)?.documentView as? EditorView
        let vertical = editorSplit.isVertical
        let extent = vertical ? editorSplit.bounds.width : editorSplit.bounds.height
        let primaryExtent = vertical ? scroll.frame.width : scroll.frame.height
        let available = max(1, extent - editorSplit.dividerThickness)
        let frame = window.frame
        return WindowSession(
            tabs: tabs,
            frame: WindowSessionFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            primary: primary.sessionView(),
            secondary: secondary?.sessionView(),
            verticalSplit: vertical,
            splitFraction: min(1, max(0, primaryExtent / available)),
            secondaryFocused: editor === secondary
        )
    }

    /// 业务作用：在窗口仍由启动流程持有时安装已通过身份核验的分屏及各自的位置。
    /// 参数说明:
    /// - session: 此窗口的原几何、分割比例和视图状态。
    /// - secondaryDocument: 第二视图对应的现有共享正文，单视图时为空。
    /// 返回：当前窗口建立原视图排列，失效修订的位置仍沿用该正文的当前合法状态。
    public func restoreWindowSession(_ session: WindowSession, secondaryDocument: DocumentBuffer?) {
        guard let window, let primary = scroll.documentView as? EditorView,
            primary.document.id == session.primary.documentID
        else {
            return
        }
        let frame = session.frame
        window.setFrame(
            visibleRecoveryFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)),
            display: false
        )
        window.contentView?.layoutSubtreeIfNeeded()
        if let secondary = session.secondary, let secondaryDocument,
            secondary.documentID == secondaryDocument.id
        {
            splitEditor(vertical: session.verticalSplit)
            if let container = editorSplit.arrangedSubviews.last as? NSScrollView,
                let clone = container.documentView as? EditorView, clone !== primary
            {
                clone.document = secondaryDocument
                let extent = session.verticalSplit ? editorSplit.bounds.width : editorSplit.bounds.height
                let available = max(1, extent - editorSplit.dividerThickness)
                editorSplit.setPosition(available * session.splitFraction, ofDividerAt: 0)
                clone.restoreSessionView(secondary)
                if session.secondaryFocused {
                    editor = clone
                }
            }
        }
        primary.restoreSessionView(session.primary)
        window.initialFirstResponder = editor
    }

    /// 业务作用：显示器断开或缩小后仍让还原的窗口出现于当前可访问屏幕。
    /// 参数说明:
    /// - frame: 已验证的原屏幕坐标。
    /// 返回：尽量保持原位置和尺寸，超出可见区域时在最相关屏幕限位。
    private func visibleRecoveryFrame(_ frame: NSRect) -> NSRect {
        let displays = NSScreen.screens.map(\.visibleFrame)
        let enclosing = displays.first { $0.contains(frame) }
        if enclosing != nil {
            return frame
        }
        let display =
            displays.max {
                $0.intersection(frame).recoveryOverlap < $1.intersection(frame).recoveryOverlap
            } ?? NSScreen.main?.visibleFrame
        guard let display else {
            return frame
        }
        let width = min(frame.width, display.width)
        let height = min(frame.height, display.height)
        return NSRect(
            x: max(display.minX, min(frame.minX, display.maxX - width)),
            y: max(display.minY, min(frame.minY, display.maxY - height)),
            width: width,
            height: height
        )
    }
}

extension EditorView {
    /// 业务作用：会话捕获此视图独立的完整选择与真实行锚点，预编辑文本不进入恢复数据。
    /// 参数说明: 无。
    /// 返回：属于实际提交修订的视图状态，组合输入期间不记录临时像素位置。
    fileprivate func sessionView() -> WindowSessionView {
        synchronizeViewSelectionRevision()
        let anchor = hasComposition ? nil : viewportAnchor()
        return WindowSessionView(
            documentID: document.id,
            revision: document.revision,
            selection: viewSelectionState,
            viewport: anchor.map { WindowSessionViewport(line: $0.line, offset: $0.offset, x: $0.x) },
            wrapLines: wrapLines,
            rightToLeft: rtl
        )
    }

    /// 业务作用：只有同一已提交修订能接管原坐标，恢复的视图设置不授予旧像素或字符的写入权限。
    /// 参数说明:
    /// - state: 所属原分屏的已验证视图记录。
    /// 返回：应用显示设置和仍可复验的独立位置；原正文、历史与保存点保持。
    fileprivate func restoreSessionView(_ state: WindowSessionView) {
        wrapLines = state.wrapLines
        rtl = state.rightToLeft
        refresh()
        // 恢复可能选用了更早的正文记录，只有完全相同的修订才允许使用原坐标。
        guard state.revision == document.revision else {
            return
        }
        if let selection = state.selection, let valid = try? selection.validated(in: document.text) {
            adoptViewSelectionState(valid)
        }
        if let viewport = state.viewport {
            restoreViewportAnchor(
                EditorViewportAnchor(line: viewport.line, offset: viewport.offset, x: viewport.x)
            )
        }
    }
}

extension NSRect {
    /// 业务作用：以真实重叠面积选择还原窗口原本所在的屏幕。
    /// 参数说明: 无。
    /// 返回：相交区域面积，空交集为零。
    fileprivate var recoveryOverlap: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}
