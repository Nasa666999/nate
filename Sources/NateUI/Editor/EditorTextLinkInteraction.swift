import AppKit
import NateCore

extension EditorView {
    /// 业务作用：鼠标命中必须同时具有当前正文来源和实际字形证据，行尾空白不继承最近链接。
    /// 参数说明:
    /// - point: 当前正文视图坐标。
    /// 返回：开启且完整验证的真实链接；边栏、候选输入、保护态或陈旧页均为空。
    func textLink(at point: NSPoint) -> EditorTextLinkHover? {
        guard textLinkSettings.mode != .disabled, composition == nil, !document.isEditingSuspended,
            textLinkBodyRect().contains(point)
        else {
            return nil
        }
        let line = projection.line(at: max(0, point.y - 8))
        guard let page = textLinks.pages[line], page.matches(document.snapshot, settings: textLinkSettings)
        else {
            return nil
        }
        let layout = layoutLine(line)
        let local = NSPoint(x: point.x - gutterWidth, y: point.y - projection.y(of: line) - 8)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(8))
        for link in visibleTextLinks(in: page, layout: layout) {
            guard ContinuousClock.now < deadline else {
                return nil
            }
            if textLinkRects(link, in: layout).contains(where: {
                $0.contains(local)
            }) {
                return EditorTextLinkHover(link: link, page: page)
            }
        }
        return nil
    }

    /// 业务作用：悬停只更新本视图的提示和颜色，不读取目标文件或启动外部程序。
    /// 参数说明:
    /// - point: 当前正文视图坐标；离开正文或窗口失去活动状态时为空。
    /// 返回：目标变化才请求重绘和光标重建，正文与选择不变。
    func updateTextLinkHover(at point: NSPoint?) {
        textLinks.hoverWindowPoint = point.map {
            convert($0, to: nil)
        }
        let next = point.flatMap {
            textLink(at: $0)
        }
        let unchanged =
            textLinks.hovered?.link == next?.link
            && textLinks.hovered?.page.revision == next?.page.revision
            && textLinks.hovered?.page.sourceIdentity == next?.page.sourceIdentity
        guard !unchanged else {
            return
        }
        textLinks.hovered = next
        toolTip = next?.link.rawText
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// 业务作用：正文滚动或后台页发布后重新检查静止鼠标，旧位置不能继续提示已经移开的链接。
    /// 参数说明: 无。
    /// 返回：仅活动窗口中的真实鼠标位置拥有悬停效果。
    func refreshTextLinkHover() {
        guard let window, window.isKeyWindow else {
            updateTextLinkHover(at: nil)
            return
        }
        let point = textLinks.hoverWindowPoint ?? window.mouseLocationOutsideOfEventStream
        updateTextLinkHover(at: convert(point, from: nil))
    }

    /// 业务作用：只为当前可见正文注册原生悬停事件，停用链接时撤销该视图的跟踪区域。
    /// 参数说明: 无。
    /// 返回：跟踪区域随滚动视口更新，不覆盖其它编辑器输入机制。
    public override func updateTrackingAreas() {
        if let tracking = textLinks.tracking {
            removeTrackingArea(tracking)
            textLinks.tracking = nil
        }
        super.updateTrackingAreas()
        guard textLinkSettings.mode != .disabled else {
            return
        }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        textLinks.tracking = tracking
        addTrackingArea(tracking)
    }

    /// 业务作用：原生鼠标移动仅刷新真实字形上的链接提示。
    /// 参数说明:
    /// - event: 系统提供的当前鼠标事件。
    /// 返回：更新本视图悬停，不产生外部动作。
    public override func mouseMoved(with event: NSEvent) {
        updateTextLinkHover(at: convert(event.locationInWindow, from: nil))
    }

    /// 业务作用：鼠标离开正文跟踪区域时立即释放旧链接提示。
    /// 参数说明:
    /// - event: 原生区域退出事件。
    /// 返回：撤销悬停和工具提示，正文保持。
    public override func mouseExited(with event: NSEvent) {
        updateTextLinkHover(at: nil)
    }

    /// 业务作用：手形光标只覆盖当前来源完整、已经排版的链接字形，普通正文继续使用插入光标。
    /// 参数说明: 无。
    /// 返回：超过单帧预算时保留普通光标，不把估算范围注册成链接。
    public override func resetCursorRects() {
        super.resetCursorRects()
        let body = textLinkBodyRect()
        if !body.isEmpty {
            addCursorRect(body, cursor: .iBeam)
        }
        guard textLinkSettings.mode != .disabled, composition == nil, !document.isEditingSuspended else {
            return
        }
        let snapshot = document.snapshot
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(8))
        var remaining = 4096
        for line in textLinkVisibleLines() {
            guard ContinuousClock.now < deadline else {
                return
            }
            guard let page = textLinks.pages[line], page.matches(snapshot, settings: textLinkSettings) else {
                continue
            }
            let layout = layoutLine(line)
            for link in visibleTextLinks(in: page, layout: layout) {
                let rects = textLinkRects(link, in: layout)
                guard ContinuousClock.now < deadline, rects.count <= remaining else {
                    return
                }
                remaining -= rects.count
                for rect in rects {
                    let visible = rect.offsetBy(dx: gutterWidth, dy: projection.y(of: line) + 8)
                        .intersection(body)
                    if !visible.isNull, !visible.isEmpty {
                        addCursorRect(visible, cursor: .pointingHand)
                    }
                }
            }
        }
    }

    /// 业务作用：普通双击才把已验证目标交给应用，修饰键双击保留分隔符选择等现有语义。
    /// 参数说明:
    /// - event: 用户当前鼠标按下事件。
    /// 返回：真实链接双击被接管时为真；其它动作继续原正文选择流程。
    func openTextLink(with event: NSEvent) -> Bool {
        guard event.clickCount == 2,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            let onOpenTextLink,
            let hover = textLink(at: convert(event.locationInWindow, from: nil))
        else {
            return false
        }
        // 取得真实输入焦点后再交付外部动作，不能由后台克隆借旧点击取得打开权限。
        guard window?.makeFirstResponder(self) == true else {
            return true
        }
        boundaries.cancelDelimiterSelection()
        clearRectangularSelection()
        let position = bytePosition(at: convert(event.locationInWindow, from: nil))
        viewSelections = [TextSelection(anchor: position, head: position)]
        dragAnchor = nil
        dragColumn = nil
        dragSelectionID = nil
        onSelection?()
        needsDisplay = true
        onOpenTextLink(self, hover.link, hover.page)
        return true
    }
}
