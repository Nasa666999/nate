import AppKit
import NateCore

extension TabStrip {
    /// 业务作用：标题跨过阈值后取得当前栏和原顺序的唯一移动资格，正文焦点保持原状。
    /// 参数说明:
    /// - source: 当前真实标题按钮。
    /// - event: 手势最初的鼠标按下事件。
    /// 返回：来源仍有效时建立栏内手势，否则不取得移动资格。
    func beginTitleDrag(_ source: TabButton, event: NSEvent) -> Bool {
        // 旧按钮和其它窗口不能借相同名称取得当前栏的顺序发布权。
        guard activeDrag == nil, source.owner === self, let native = window, native.isVisible,
            source.window === native, event.windowNumber == native.windowNumber,
            source.orderIdentity == orderIdentity, let id = source.documentID,
            current.contains(where: {
                $0.id == id
            })
        else {
            return false
        }
        activeDrag = TabDragGesture(
            owner: dragOwner,
            gesture: UUID(),
            documentID: id,
            order: orderIdentity
        )
        dragSource = source
        dragLocation = event.locationInWindow
        source.alphaValue = 0.55
        dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] key in
            guard let self, let active = self.activeDrag else {
                return key
            }
            let belongsToWindow = key.windowNumber == self.window?.windowNumber
            self.endTitleDrag(active.gesture)
            // Esc 只取消当前移动，不能同时撤去正文里的输入法候选。
            return belongsToWindow && key.keyCode == 53 ? nil : key
        }
        let timer = Timer(
            timeInterval: 0.05,
            repeats: true
        ) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.continueTitleDrag()
            }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    /// 业务作用：后续独立鼠标事件更新插入反馈，不阻塞保存或其它主线程任务。
    /// 参数说明:
    /// - source: 持有原始按下序列的标题。
    /// - gesture: 该序列取得的手势身份。
    /// - event: 当前原生拖动事件。
    /// 返回：完整来源仍相符时更新反馈；失权则取消整个手势。
    func updateTitleDrag(_ source: TabButton, gesture: UUID?, event: NSEvent) {
        guard let gesture, activeDrag?.gesture == gesture else {
            return
        }
        guard validTitleDrag(source), event.windowNumber == window?.windowNumber else {
            endTitleDrag(gesture)
            return
        }
        dragLocation = event.locationInWindow
        displayTitleDrop()
    }

    /// 业务作用：鼠标释放时完整复验来源和栏内位置，再发布一次纯顺序计划。
    /// 参数说明:
    /// - source: 原始标题实例。
    /// - gesture: 按下序列的唯一手势身份。
    /// - event: 实际释放事件。
    /// 返回：合法栏内投放提交计划，外部释放、旧顺序或旧窗口只解除反馈。
    func finishTitleDrag(_ source: TabButton, gesture: UUID?, event: NSEvent) {
        guard let gesture, let active = activeDrag, active.gesture == gesture else {
            return
        }
        defer {
            endTitleDrag(gesture)
        }
        // 释放发生在别的窗口或栏外时不能使用最后一次合法悬停位置代为移动。
        guard validTitleDrag(source), event.windowNumber == window?.windowNumber,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else {
            return
        }
        do {
            let move = try DocumentOrderMove(
                original: current.map(\.id),
                documentID: active.documentID,
                before: targetBefore(event.locationInWindow),
                sourceGeneration: orderIdentity
            )
            // 先收回手势再发布排列，界面重建不能让迟到释放重复消费同一意图。
            endTitleDrag(gesture)
            _ = onReorder?(move)
        }
        catch {
            return
        }
    }

    /// 业务作用：匹配的结束或取消路径释放反馈和周期任务，旧回调不能清除后来手势。
    /// 参数说明:
    /// - gesture: 明确结束的唯一手势。
    /// 返回：只清理匹配手势，不切换正文或确认输入。
    func endTitleDrag(_ gesture: UUID) {
        guard activeDrag?.gesture == gesture else {
            return
        }
        activeDrag = nil
        dragTimer?.invalidate()
        dragTimer = nil
        if let monitor = dragKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        dragKeyMonitor = nil
        dragSource?.alphaValue = 1
        dragSource = nil
        dropIndicator.isHidden = true
    }

    /// 业务作用：静止悬停时继续推进边缘滚动，失去窗口、来源或鼠标后及时解除手势。
    /// 参数说明: 无。
    /// 返回：当前合法按住序列刷新反馈，其它情况收回全部移动资格。
    private func continueTitleDrag() {
        guard let active = activeDrag else {
            return
        }
        guard let source = dragSource, validTitleDrag(source), NSEvent.pressedMouseButtons & 1 != 0 else {
            endTitleDrag(active.gesture)
            return
        }
        displayTitleDrop()
    }

    /// 业务作用：栏内拖动只信任原按钮、当前窗口和未改变的顺序代次。
    /// 参数说明:
    /// - source: 当前序列真实来源。
    /// 返回：完整证据一致时为真，文本、名称和外部载荷均不参与授权。
    private func validTitleDrag(_ source: TabButton) -> Bool {
        guard let active = activeDrag, let native = window else {
            return false
        }
        return dragSource === source && source.owner === self && source.window === native && native.isVisible
            && active.owner == dragOwner && active.order == orderIdentity
            && source.orderIdentity == orderIdentity && source.documentID == active.documentID
            && current.contains {
                $0.id == active.documentID
            }
    }

    /// 业务作用：按照当前真实布局显示插入位置，栏外移动隐藏反馈并停止边缘推进。
    /// 参数说明: 无。
    /// 返回：只改变标签视口与标记，正文及活动身份保持原状。
    private func displayTitleDrop() {
        let point = convert(dragLocation, from: nil)
        guard bounds.contains(point) else {
            dropIndicator.isHidden = true
            return
        }
        scrollForDrag(point)
        stack.layoutSubtreeIfNeeded()
        let before = targetBefore(dragLocation)
        let index = before.flatMap {
            id in
            current.firstIndex {
                $0.id == id
            }
        }
        let x =
            index.flatMap {
                stack.arrangedSubviews.indices.contains($0) ? stack.arrangedSubviews[$0].frame.minX : nil
            }
            ?? max(4, stack.bounds.maxX - 4)
        dropIndicator.frame = NSRect(
            x: x - 1,
            y: 3,
            width: 2,
            height: 26
        )
        dropIndicator.isHidden = false
    }

    /// 业务作用：实际标签中点决定插入参考，滚动偏移不被误当文档序号。
    /// 参数说明:
    /// - windowPoint: 当前窗口中的鼠标位置。
    /// 返回：目标身份，越过最后标签时为空表示末尾。
    private func targetBefore(_ windowPoint: NSPoint) -> UUID? {
        let point = stack.convert(windowPoint, from: nil)
        for (index, view) in stack.arrangedSubviews.enumerated() where current.indices.contains(index) {
            if point.x < view.frame.midX {
                return current[index].id
            }
        }
        return nil
    }

    /// 业务作用：边缘悬停仅滚动标签视口，正文视口与选择保持原状。
    /// 参数说明:
    /// - point: 标签栏内鼠标位置。
    /// 返回：在实际可滚动范围内平滑推进，不直接移动任何标签。
    private func scrollForDrag(_ point: NSPoint) {
        let clip = contentView.bounds
        let maximum = max(0, stack.bounds.width - clip.width)
        let delta: CGFloat = point.x < 24 ? -12 : (point.x > bounds.maxX - 24 ? 12 : 0)
        let position = min(maximum, max(0, clip.minX + delta))
        if position != clip.minX {
            contentView.scroll(
                to: NSPoint(
                    x: position,
                    y: clip.minY
                )
            )
            reflectScrolledClipView(contentView)
        }
    }
}
