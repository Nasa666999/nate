import AppKit
import NateCore
import NateSyntax

public enum BracketNavigation: Sendable {
    case jump
    case selectPair
    case selectInside
}

struct BracketContext: Equatable {
    let documentID: UUID
    let revision: UInt64
    let resource: UUID
}

struct BracketNavigationRequest {
    let context: BracketContext
    let selections: [TextSelection]
    let action: BracketNavigation
    let wasKeyWindow: Bool
    let wasApplicationActive: Bool
}

@MainActor
final class BracketViewState {
    var resource = UUID()
    var context: BracketContext?
    var index: BracketIndex?
    var task: Task<Void, Never>?
    var taskID: UUID?
    var attempted = false
    var failure: String?
    var pending: BracketNavigationRequest?
}

extension EditorView {
    /// 业务作用：将待执行导航绑定到当前视图的焦点生命周期，跨窗口或应用失焦后不恢复旧意图。
    /// 参数说明: 无。
    /// 返回：视图在窗口内时观察失焦事件，移出窗口后解除观察。
    func observeBracketFocus() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        guard window != nil else {
            return
        }
        center.addObserver(
            self,
            selector: #selector(bracketFocusLost(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(bracketFocusLost(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    /// 业务作用：失去焦点立即撤销尚未执行的导航，重新激活不重新授予旧请求执行资格。
    /// 参数说明:
    /// - notification: 当前窗口或应用的失焦通知。
    /// 返回：属于本视图的焦点身份与导航意图失效，已确认的结构缓存仍可复用。
    @objc func bracketFocusLost(_ notification: Notification) {
        // 其它窗口的焦点事件不属于本视图，不能撤销当前用户的导航动作。
        if notification.name == NSWindow.didResignKeyNotification,
            (notification.object as? NSWindow) !== window
        {
            return
        }
        focusGeneration = UUID()
        brackets.pending = nil
        folds.pending = nil
    }

    /// 业务作用：保存状态刷新时同时保留括号分析的真实进度或预算边界。
    /// 参数说明: 无。
    /// 返回：当前文档仍适用的分析说明，无等待或失败时为空。
    public var bracketAnalysisStatus: String? {
        synchronizeBracketContext()
        guard composition == nil else {
            return nil
        }
        if let failure = brackets.failure {
            return failure
        }
        if brackets.index == nil && brackets.task != nil
            && (brackets.pending != nil
                || BracketIndex.isAdjacent(in: document.text, caret: primarySelection?.head ?? 0))
        {
            return "正在解析括号"
        }
        return nil
    }

    /// 业务作用：菜单只在主光标邻接可识别括号时提供跳转或整对选择入口。
    /// 参数说明: 无。
    /// 返回：当前提交正文的主光标附近存在圆、方或花括号时为真。
    public var hasAdjacentBracket: Bool {
        BracketIndex.isAdjacent(in: document.text, caret: primarySelection?.head ?? 0)
    }

    /// 业务作用：菜单和快捷键共用当前结构证据决定动作资格，已确认无匹配时不提供无效跳转。
    /// 参数说明:
    /// - action: 跳转、整对选择或内部选择。
    /// 返回：保护态拒绝导航；尚未分析时允许明确请求，完整结果已知时按实际匹配启用。
    public func bracketNavigationAvailable(_ action: BracketNavigation) -> Bool {
        synchronizeBracketContext()
        guard !document.isEditingSuspended, let caret = primarySelection?.head else {
            return false
        }
        switch action {
        case .jump, .selectPair:
            guard hasAdjacentBracket else {
                return false
            }
            if let index = brackets.index {
                return index.match(at: caret)?.partner != nil
            }
            return true
        case .selectInside:
            if let index = brackets.index {
                return index.interior(at: caret) != nil
            }
            return document.text.byteCount > 0
        }
    }

    /// 业务作用：语言、UDL 或分析预算变化时撤销旧结果，实际未返回的解析仍占用本视图唯一任务位。
    /// 参数说明: 无。
    /// 返回：旧导航意图失效；后续需要时按新资源重新分析，不积压并发解析任务。
    public func invalidateBracketAnalysis() {
        brackets.resource = UUID()
        brackets.context = nil
        brackets.index = nil
        brackets.attempted = false
        brackets.failure = nil
        brackets.pending = nil
        folds.context = nil
        folds.index = nil
        folds.collapsed.removeAll()
        folds.pending = nil
        folds.failure = nil
        hiddenLines.removeAll()
        projection.hidden = hiddenLines
        // 取消不能冒充后台已经停止，任务位在真正返回后才释放。
        brackets.task?.cancel()
        needsDisplay = true
    }

    /// 业务作用：按文档生命周期、正文修订和资源身份区分结构结果，不复用旧正文的范围。
    /// 参数说明: 无。
    /// 返回：当前上下文变化时取消旧任务并清空旧结果，实际在途任务仍可观察。
    func synchronizeBracketContext() {
        let context = BracketContext(
            documentID: document.id,
            revision: document.revision,
            resource: brackets.resource
        )
        guard brackets.context != context else {
            return
        }
        brackets.context = context
        synchronizeFoldContext(context)
        brackets.index = nil
        brackets.attempted = false
        brackets.failure = nil
        brackets.pending = nil
        brackets.task?.cancel()
    }

    /// 业务作用：当前语言需要折叠、光标邻接括号或用户明确导航时安排共享结构分析，不复制全文供界面使用。
    /// 参数说明: 无。
    /// 返回：每个视图最多有一个实际在途任务；取消后等待其返回，再按最新正文继续。
    func prepareBracketAnalysis() {
        synchronizeBracketContext()
        let needsFolds = FoldIndex.supports(language: language, udl: userLanguage) && folds.index == nil
        guard composition == nil, window != nil, brackets.index == nil, brackets.task == nil,
            !brackets.attempted,
            hasAdjacentBracket || brackets.pending != nil || needsFolds || folds.pending != nil,
            let context = brackets.context
        else {
            return
        }
        let snapshot = document.snapshot
        let language = language
        let udl = userLanguage
        let limits = bracketLimits
        let state = brackets
        let identity = UUID()
        state.attempted = true
        state.failure = nil
        state.taskID = identity
        state.task = Task {
            [weak self] in
            defer {
                if state.taskID == identity {
                    state.task = nil
                    state.taskID = nil
                    // 显式的新导航不能依赖窗口下一次重绘，旧分析真正返回后立即接续最新有效请求。
                    if state.pending != nil || self?.folds.pending != nil {
                        self?.prepareBracketAnalysis()
                    }
                    self?.needsDisplay = true
                }
            }
            let worker = Task.detached(priority: .utility) {
                let brackets = try BracketIndex(
                    snapshot: snapshot,
                    language: language,
                    udl: udl,
                    limits: limits
                )
                var folds: FoldIndex?
                var failure: String?
                if FoldIndex.supports(language: language, udl: udl) {
                    do {
                        folds = try FoldIndex(
                            snapshot: snapshot,
                            brackets: brackets,
                            language: language,
                            udl: udl
                        )
                    }
                    catch {
                        if Task.isCancelled || error is CancellationError {
                            throw error
                        }
                        failure = error.localizedDescription
                    }
                }
                return EditorStructureResult(
                    brackets: brackets,
                    folds: folds,
                    foldFailure: failure
                )
            }
            do {
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                try Task.checkCancellation()
                // 后台等待期间正文、文档或资源都可能变化，旧范围不能影响当前光标或呈现。
                guard let self, self.document.id == context.documentID,
                    self.document.revision == context.revision, state.resource == context.resource,
                    state.context == context
                else {
                    return
                }
                state.index = result.brackets
                self.publishFolds(result.folds, failure: result.foldFailure)
                if let pending = state.pending {
                    state.pending = nil
                    self.applyBracketNavigation(pending, index: result.brackets)
                }
                self.needsDisplay = true
            }
            catch {
                // 失败说明同样属于原分析上下文，不能覆盖新文档或新规则的结构状态。
                guard let self, self.document.id == context.documentID,
                    self.document.revision == context.revision, state.resource == context.resource,
                    state.context == context
                else {
                    return
                }
                if Task.isCancelled || error is CancellationError {
                    // 取消来源已撤销旧意图；晚到的取消结果不能删除此后创建的有效新请求。
                    state.attempted = false
                }
                else {
                    state.pending = nil
                    self.folds.pending = nil
                    state.failure = error.localizedDescription
                    self.onStatus?(error.localizedDescription)
                }
            }
        }
    }

    /// 业务作用：显式括号导航固定当前主光标和词法资源，未完成分析的动作在结果到达后重新复验。
    /// 参数说明:
    /// - action: 跳转、包含两端的选择或仅内部文本选择。
    /// 返回：完整索引有效时更新主选区；等待、无匹配或上下文变化时保留现有正文和选区。
    public func navigateBracket(_ action: BracketNavigation) {
        // 关闭、退出或监视准备已经冻结最终视图时，不再新增可能迟到的导航选择。
        guard !document.isEditingSuspended else {
            return
        }
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return
        }
        synchronizeBracketContext()
        folds.pending = nil
        guard bracketNavigationAvailable(action) else {
            onStatus?("当前位置没有可用于该动作的完整括号。")
            return
        }
        guard let context = brackets.context, !viewSelections.isEmpty else {
            return
        }
        let request = BracketNavigationRequest(
            context: context,
            selections: viewSelections,
            action: action,
            wasKeyWindow: window?.isKeyWindow == true,
            wasApplicationActive: NSApp?.isActive == true
        )
        if let index = brackets.index {
            applyBracketNavigation(request, index: index)
            return
        }
        brackets.pending = request
        if brackets.task == nil {
            brackets.attempted = false
        }
        prepareBracketAnalysis()
        onStatus?("正在识别当前括号，正文与选区保持可用。")
    }

    /// 业务作用：只有用户发起动作时的同一光标仍有效，异步配对才可发布导航选择。
    /// 参数说明:
    /// - request: 原始动作及其正文和选区证据。
    /// - index: 与同一正文修订对应的完整配对。
    /// 返回：定位或选中匹配内容；焦点、正文或选区已变化时不移动新的用户位置。
    func applyBracketNavigation(_ request: BracketNavigationRequest, index: BracketIndex) {
        // 光标移动、输入法组合或焦点交接后，旧点击意图不能覆盖新的用户选择。
        guard window?.firstResponder === self, composition == nil, !document.isEditingSuspended,
            (window?.isKeyWindow == true) == request.wasKeyWindow,
            (NSApp?.isActive == true) == request.wasApplicationActive,
            document.id == request.context.documentID, document.revision == request.context.revision,
            brackets.resource == request.context.resource, viewSelections == request.selections,
            index.documentID == document.id, index.revision == document.revision,
            let caret = primarySelection?.head
        else {
            return
        }
        let selection: TextSelection
        switch request.action {
        case .jump:
            guard let partner = index.match(at: caret)?.partner else {
                onStatus?("当前位置没有完整的匹配括号。")
                return
            }
            selection = TextSelection(
                anchor: partner,
                head: partner
            )
        case .selectPair:
            guard let match = index.match(at: caret), let partner = match.partner else {
                onStatus?("当前位置没有完整的匹配括号。")
                return
            }
            selection = TextSelection(
                anchor: min(match.position, partner),
                head: max(match.position, partner) + 1
            )
        case .selectInside:
            guard let range = index.interior(at: caret) else {
                onStatus?("当前光标没有完整的包围括号。")
                return
            }
            selection = TextSelection(
                anchor: range.lower,
                head: range.upper
            )
        }
        viewSelections = [selection]
        needsDisplay = true
        revealSelection()
        onSelection?()
    }

    /// 业务作用：在原始正文坐标上标出当前括号及其配对，未匹配字符具有独立提示颜色。
    /// 参数说明:
    /// - layout: 当前可见真实行的原生布局。
    /// - y: 该行在视图投影中的纵坐标。
    /// 返回：只绘制匹配边框和背景，不改变语法色、选区或正文。
    func drawBracketMatch(in layout: LineLayout, y: CGFloat) {
        guard composition == nil, window?.firstResponder === self,
            let index = brackets.index, index.documentID == document.id, index.revision == document.revision,
            let caret = primarySelection?.head, let match = index.match(at: caret)
        else {
            return
        }
        var positions = [match.position]
        if let partner = match.partner {
            positions.append(partner)
        }
        let color = match.partner == nil ? NSColor.systemRed : NSColor.systemTeal
        for position in positions where position >= layout.range.lower && position < layout.range.upper {
            let range = ByteRange(
                position,
                position + 1
            )
            for rect in layout.selectionRects(range) {
                let rect = rect.offsetBy(dx: gutterWidth, dy: y).insetBy(dx: -1, dy: 0)
                let outline = NSBezierPath(
                    roundedRect: rect,
                    xRadius: 2,
                    yRadius: 2
                )
                themeColor(
                    match.partner == nil ? .bracketMismatchBackground : .bracketMatchBackground,
                    fallback: color.withAlphaComponent(0.12)
                ).setFill()
                outline.fill()
                color.withAlphaComponent(0.9).setStroke()
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }
}
