import AppKit
import NateCore
import NateSyntax

public enum FoldAction: Sendable, Equatable {
    case toggle
    case collapse
    case expand
    case collapseAll
    case expandAll
    case level(Int)
}

struct FoldRequest {
    let context: BracketContext
    let selections: [TextSelection]
    let action: FoldAction
    let line: Int
    let wasKeyWindow: Bool
    let wasApplicationActive: Bool
}

struct EditorStructureResult: Sendable {
    let brackets: BracketIndex
    let folds: FoldIndex?
    let foldFailure: String?
}

@MainActor
final class FoldViewState {
    var context: BracketContext?
    var index: FoldIndex?
    var collapsed: Set<ByteRange> = []
    var pending: FoldRequest?
    var failure: String?
}

extension EditorView {
    /// 业务作用：报告本视图当前折叠数量，克隆视图不共享显示状态。
    /// 参数说明: 无。
    /// 返回：当前完整结构证据下已收起的区域数量。
    public var foldedRegionCount: Int {
        synchronizeBracketContext()
        return folds.index == nil ? 0 : folds.collapsed.count
    }

    /// 业务作用：将结构计算的等待或预算边界保留在状态栏，正文保持可访问。
    /// 参数说明: 无。
    /// 返回：当前语言需要折叠分析时的进度或原因，其它情况为空。
    public var foldingAnalysisStatus: String? {
        synchronizeBracketContext()
        guard FoldIndex.supports(language: language, udl: userLanguage), composition == nil else {
            return nil
        }
        if let failure = folds.failure ?? brackets.failure {
            return failure
        }
        return folds.index == nil && brackets.task != nil ? "正在解析折叠结构" : nil
    }

    /// 业务作用：正文变化后先解除旧隐藏投影，再凭完整修订链映射用户收起的端点。
    /// 参数说明:
    /// - context: 当前文档、修订和资源身份。
    /// 返回：仅保留可追踪的折叠意图；新结构确认前全部行可见。
    func synchronizeFoldContext(_ context: BracketContext) {
        guard folds.context != context else {
            return
        }
        if let previous = folds.context, previous.documentID == context.documentID,
            previous.resource == context.resource,
            // 折叠端点必须保持完整 UTF-8 边界，末尾多字节字符的续字节不能充当位置锚点。
            let mapped = document.mapSelections(
                folds.collapsed.map {
                    TextSelection(anchor: $0.lower, head: $0.upper)
                },
                from: previous.revision
            )
        {
            folds.collapsed = Set(
                mapped.filter {
                    $0.anchor < $0.head && document.text.isBoundary($0.anchor)
                        && document.text.isBoundary($0.head)
                }.map {
                    ByteRange($0.anchor, $0.head)
                }
            )
        }
        else {
            // 文档重绑、规则变化或修订链缺席时，不猜测旧折叠属于当前的哪个代码块。
            folds.collapsed.removeAll()
        }
        folds.context = context
        folds.index = nil
        folds.pending = nil
        folds.failure = nil
        hiddenLines.removeAll()
        projection.hidden = hiddenLines
    }

    /// 业务作用：菜单、边栏和快捷命令共用同一动作资格，未定义的语言不显示伪造折叠。
    /// 参数说明:
    /// - action: 当前块、全部或指定层级动作。
    /// 返回：当前文档允许导航且动作具有可用范围时为真；尚在解析时允许用户发出明确意图。
    public func foldingAvailable(_ action: FoldAction) -> Bool {
        synchronizeBracketContext()
        if case .level(let level) = action, level <= 0 || level > 65_536 {
            return false
        }
        guard !document.isEditingSuspended, FoldIndex.supports(language: language, udl: userLanguage),
            let selection = primarySelection
        else {
            return false
        }
        guard let index = folds.index else {
            return action != .expandAll
        }
        switch action {
        case .expandAll: return !folds.collapsed.isEmpty
        case .collapseAll:
            return index.regions.contains {
                !folds.collapsed.contains($0.range)
            }
        case .level(let level):
            return index.regions.contains {
                $0.level == level && !folds.collapsed.contains($0.range)
            }
        case .toggle, .collapse, .expand:
            guard let region = index.region(at: document.text.lineNumber(at: selection.head)) else {
                return false
            }
            return action == .toggle || (action == .expand) == folds.collapsed.contains(region.range)
        }
    }

    /// 业务作用：固定用户选择和焦点发出折叠请求，后台解析完成后再次复验原意图。
    /// 参数说明:
    /// - action: 要执行的折叠或展开动作。
    /// - line: 边栏点击的真实行；为空时使用当前光标行。
    /// 返回：仅改变本视图投影；保护态、失效上下文或无完整结构时保留原正文。
    public func performFold(_ action: FoldAction, line: Int? = nil) {
        if case .level(let level) = action, level <= 0 || level > 65_536 {
            return
        }
        guard !document.isEditingSuspended, FoldIndex.supports(language: language, udl: userLanguage) else {
            return
        }
        // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
        guard finishComposition() else {
            return
        }
        synchronizeBracketContext()
        brackets.pending = nil
        guard let context = brackets.context, let selection = primarySelection else {
            return
        }
        let line = line ?? document.text.lineNumber(at: selection.head)
        guard line >= 0, line < document.text.lineCount else {
            return
        }
        let request = FoldRequest(
            context: context,
            selections: viewSelections,
            action: action,
            line: line,
            wasKeyWindow: window?.isKeyWindow == true,
            wasApplicationActive: NSApp?.isActive == true
        )
        if let index = folds.index {
            applyFold(request, index: index)
            return
        }
        folds.pending = request
        if brackets.task == nil {
            brackets.attempted = false
            brackets.index = nil
        }
        prepareBracketAnalysis()
        onStatus?("正在解析折叠结构，正文与选区保持可用。")
    }

    /// 业务作用：发布与当前快照一致的折叠结构，只有端点仍完整匹配的收起状态可以恢复。
    /// 参数说明:
    /// - index: 后台确认的完整折叠索引，为空时没有可用规则。
    /// - failure: 本次折叠整理的明确失败原因。
    /// 返回：更新视图结构及有效隐藏区间，失败不隐藏任何正文。
    func publishFolds(_ index: FoldIndex?, failure: String?) {
        folds.index = index
        folds.failure = failure
        if let index {
            folds.collapsed.formIntersection(Set(index.regions.map(\.range)))
        }
        else {
            folds.collapsed.removeAll()
        }
        rebuildFoldVisibility()
        refresh()
        unfoldSelection()
        if let request = folds.pending {
            folds.pending = nil
            if let index {
                applyFold(request, index: index)
            }
        }
    }

    /// 业务作用：只在动作发起时的正文、选区和焦点仍有效时收起或展开范围。
    /// 参数说明:
    /// - request: 原始折叠动作与控制证据。
    /// - index: 当前完整结构索引。
    /// 返回：更新视图并将被隐藏的光标移到可见标题；迟到请求不改变用户新选择。
    func applyFold(_ request: FoldRequest, index: FoldIndex) {
        // 关闭保护、失焦、资源切换或用户已移动光标后，旧动作不能再隐藏当前工作区域。
        guard window?.firstResponder === self, composition == nil, !document.isEditingSuspended,
            request.context == brackets.context, folds.context == request.context,
            document.id == index.documentID, document.revision == index.revision,
            viewSelections == request.selections,
            (window?.isKeyWindow == true) == request.wasKeyWindow,
            (NSApp?.isActive == true) == request.wasApplicationActive
        else {
            return
        }
        let anchor = viewportAnchor()
        switch request.action {
        case .expandAll: folds.collapsed.removeAll()
        case .collapseAll: folds.collapsed = Set(index.regions.map(\.range))
        case .level(let level):
            folds.collapsed.formUnion(
                index.regions.filter {
                    $0.level == level
                }.map(\.range)
            )
        case .toggle, .collapse, .expand:
            guard let region = index.region(at: request.line) else {
                onStatus?("当前行没有完整的多行折叠结构。")
                return
            }
            if request.action == .expand
                || (request.action == .toggle && folds.collapsed.contains(region.range))
            {
                folds.collapsed.remove(region.range)
            }
            else {
                folds.collapsed.insert(region.range)
            }
        }
        rebuildFoldVisibility()
        viewSelections = viewSelections.map {
            let line = document.text.lineNumber(at: $0.head)
            guard hiddenLines.contains(line) else {
                return $0
            }
            let head = document.text.lineStart(hiddenLines.visibleBeforeOrAt(line))
            return TextSelection(anchor: head, head: head)
        }
        refresh()
        restoreViewportAnchor(anchor)
        onSelection?()
    }
}
