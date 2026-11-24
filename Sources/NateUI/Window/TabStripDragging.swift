import AppKit
import NateCore

extension TabStrip {
    /// 业务作用：标题跨过阈值后取得当前栏和原顺序的唯一移动资格，正文焦点保持原状。
    /// 参数说明:
    /// - source: 当前真实标题按钮。
    /// - event: 手势最初的鼠标按下事件。
    /// 返回：来源仍有效时建立栏内手势，否则不取得移动资格。
    func beginTitleDrag(_ source: TabButton, event: NSEvent) -> Bool {
        layoutTabs()
        // 旧按钮和其它窗口不能借相同名称取得当前栏的顺序发布权。
        guard activeDrag == nil, layoutPlan?.cells.map(\.documentID) == current.map(\.id),
            source.owner === self, let native = window, native.isVisible,
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
            let belongsToWindow =
                key.windowNumber == self.window?.windowNumber
                || key.windowNumber == self.crossDropTarget?.window?.windowNumber
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
        guard validTitleDrag(source), let location = titleDragLocation(event) else {
            endTitleDrag(gesture)
            return
        }
        dragLocation = location
        displayTitleDrop()
    }

    /// 业务作用：释放时复验真实鼠标落点与原顺序，各窗口只接受一次有效拖放。
    /// 参数说明:
    /// - source: 原始标题实例。
    /// - gesture: 按下序列的唯一手势身份。
    /// - event: 实际释放事件。
    /// 返回：栏内重排或跨窗移动成功时发布一次计划，旧顺序和栏外释放只解除反馈。
    func finishTitleDrag(_ source: TabButton, gesture: UUID?, event: NSEvent) {
        layoutTabs()
        guard let gesture, let active = activeDrag, active.gesture == gesture else {
            return
        }
        defer {
            endTitleDrag(gesture)
        }
        // 鼠标释放必须用本次真实落点，不能借最后一次合法悬停代为提交。
        guard validTitleDrag(source), let location = titleDragLocation(event), let window
        else {
            return
        }
        let point = window.convertPoint(toScreen: location)
        if let destination = tabDropTarget(at: point), let targetWindow = destination.windowOwner,
            let targetNative = destination.window
        {
            // 布局、顺序或目标变化后，旧插入提示不能成为新窗口的移动授权。
            guard crossDropTarget === destination, crossDropGeneration == destination.orderIdentity else {
                return
            }
            destination.layoutTabs()
            let transfer = WindowTabTransfer(
                documentID: active.documentID,
                sourceGeneration: active.order,
                destinationGeneration: destination.orderIdentity,
                before: destination.targetBefore(targetNative.convertPoint(fromScreen: point))
            )
            endTitleDrag(gesture)
            _ = windowOwner?.onTabTransfer?(transfer, targetWindow)
            return
        }
        guard event.windowNumber == window.windowNumber, bounds.contains(convert(location, from: nil)),
            !canTransferTabs
                || NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber
        else {
            return
        }
        do {
            let move = try DocumentOrderMove(
                original: current.map(\.id),
                documentID: active.documentID,
                before: targetBefore(location),
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
        clearCrossDrop()
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

    /// 业务作用：按屏幕落点选择当前栏或另一已登记标签栏，只有当前有效目标显示插入提示。
    /// 参数说明: 无。
    /// 返回：只改变标签视口与标记，正文及活动身份保持原状。
    private func displayTitleDrop() {
        if let window {
            let point = window.convertPoint(toScreen: dragLocation)
            if let destination = tabDropTarget(at: point), let targetWindow = destination.window {
                dropIndicator.isHidden = true
                if crossDropTarget !== destination {
                    clearCrossDrop()
                    crossDropTarget = destination
                    crossDropGeneration = destination.orderIdentity
                }
                // 同一栏在悬停时换代，先隐藏旧提示，离开并重新进入后才能取得新目标。
                if crossDropGeneration == destination.orderIdentity {
                    destination.layoutTabs()
                    destination.showTitleDrop(at: targetWindow.convertPoint(fromScreen: point))
                }
                else {
                    destination.dropIndicator.isHidden = true
                }
                return
            }
        }
        clearCrossDrop()
        // 目标可能被其它面板或应用的窗口盖住，不能在下方标签栏继续显示可投放提示。
        if canTransferTabs, let window,
            NSWindow.windowNumber(
                at: window.convertPoint(toScreen: dragLocation),
                belowWindowWithWindowNumber: 0
            )
                != window.windowNumber
        {
            dropIndicator.isHidden = true
            return
        }
        showTitleDrop(at: dragLocation)
    }

    /// 业务作用：把当前原生鼠标事件换算成来源栏的窗口坐标，支持 AppKit 将事件关联到不同窗口。
    /// 参数说明:
    /// - event: 本次实际鼠标拖动或释放事件。
    /// 返回：本应用可识别的原生窗口坐标，无法定位外部事件时为空。
    func titleDragLocation(_ event: NSEvent) -> NSPoint? {
        guard let window else {
            return nil
        }
        if event.windowNumber == window.windowNumber {
            return event.locationInWindow
        }
        guard canTransferTabs, let eventWindow = event.window,
            NSApp.windows.contains(where: { $0 === eventWindow })
        else {
            return nil
        }
        return window.convertPoint(fromScreen: eventWindow.convertPoint(toScreen: event.locationInWindow))
    }

    /// 业务作用：将鼠标交给应用登记的最前方真实目标，源栏和临时控件不能接收跨窗移动。
    /// 参数说明:
    /// - point: 鼠标当前屏幕坐标。
    /// 返回：当前可见且没有其它拖动的实际目标栏。
    private func tabDropTarget(at point: NSPoint) -> TabStrip? {
        guard canTransferTabs, let target = windowOwner?.onTabDropTarget?(point)?.tabs,
            target !== self, target.activeDrag == nil
        else {
            return nil
        }
        return target
    }

    /// 业务作用：离开、取消或完成拖动时清理另一窗口的临时插入提示。
    /// 参数说明: 无。
    /// 返回：撤销原悬停证据和对应提示。
    private func clearCrossDrop() {
        crossDropTarget?.dropIndicator.isHidden = true
        crossDropTarget = nil
        crossDropGeneration = nil
    }

    /// 业务作用：按目标栏的实际布局及滚动位置绘制插入提示。
    /// 参数说明:
    /// - windowPoint: 当前目标窗口的原生坐标。
    /// 返回：合法落点显示插入线，栏外隐藏提示并停止滚动。
    private func showTitleDrop(at windowPoint: NSPoint) {
        guard bounds.contains(convert(windowPoint, from: nil)) else {
            dropIndicator.isHidden = true
            return
        }
        scrollForDrag(windowPoint)
        stack.layoutSubtreeIfNeeded()
        let before = targetBefore(windowPoint)
        let index = before.flatMap {
            id in
            current.firstIndex {
                $0.id == id
            }
        }
        guard let plan = layoutPlan,
            let cell = index.flatMap({
                plan.cells.indices.contains($0) ? plan.cells[$0] : nil
            }) ?? plan.cells.last
        else {
            dropIndicator.isHidden = true
            return
        }
        if layoutMode == .vertical {
            dropIndicator.frame = NSRect(
                x: cell.x,
                y: index == nil ? cell.y + cell.height : cell.y,
                width: cell.width,
                height: 2
            )
        }
        else {
            dropIndicator.frame = NSRect(
                x: index == nil ? cell.x + cell.width : cell.x - 1,
                y: cell.y + 3,
                width: 2,
                height: 26
            )
        }
        dropIndicator.isHidden = false
    }

    /// 业务作用：实际标签中点决定插入参考，滚动偏移不被误当文档序号。
    /// 参数说明:
    /// - windowPoint: 当前窗口中的鼠标位置。
    /// 返回：目标身份，越过最后标签时为空表示末尾。
    private func targetBefore(_ windowPoint: NSPoint) -> UUID? {
        let point = stack.convert(windowPoint, from: nil)
        guard let plan = layoutPlan, let index = try? plan.insertionIndex(x: point.x, y: point.y),
            current.indices.contains(index)
        else {
            return nil
        }
        return current[index].id
    }

    /// 业务作用：边缘悬停仅滚动标签视口，正文视口与选择保持原状。
    /// 参数说明:
    /// - windowPoint: 当前窗口中的真实鼠标位置。
    /// 返回：在实际可滚动范围内平滑推进，不直接移动任何标签。
    private func scrollForDrag(_ windowPoint: NSPoint) {
        let clip = contentView.bounds
        let point = contentView.convert(windowPoint, from: nil)
        let horizontal = layoutMode == .horizontal
        let lower = horizontal ? clip.minX : clip.minY
        let upper = horizontal ? clip.maxX : clip.maxY
        let coordinate = horizontal ? point.x : point.y
        let maximum =
            horizontal ? max(0, stack.bounds.width - clip.width) : max(0, stack.bounds.height - clip.height)
        let delta: CGFloat = coordinate < lower + 24 ? -12 : (coordinate > upper - 24 ? 12 : 0)
        let position = min(maximum, max(0, lower + delta))
        if position != lower {
            contentView.scroll(
                to: NSPoint(
                    x: horizontal ? position : clip.minX,
                    y: horizontal ? clip.minY : position
                )
            )
            reflectScrolledClipView(contentView)
        }
    }
}
