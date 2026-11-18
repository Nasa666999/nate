import AppKit
import NateCore

struct SearchResultTreeKey: Hashable {
    let batch: UUID
    var file: UUID?
    var hit: UUID?
    var note: Int?
}

enum SearchResultTreeValue {
    case batch(SearchResultBatchPresentation)
    case file(SearchResultFilePresentation)
    case hit(SearchPreviewRow, path: String?)
    case note(String)
}

@MainActor
final class SearchResultTreeItem {
    let key: SearchResultTreeKey
    var value: SearchResultTreeValue
    weak var parent: SearchResultTreeItem?
    var children: [SearchResultTreeItem] = []

    /// 业务作用：原生树表行持有稳定结果身份，父级弱引用避免关闭批次后保留整棵树。
    /// 参数说明:
    /// - key: 批次、文件和命中的稳定组合身份。
    /// - value: 当前完整展示值，不含源正文。
    /// 返回：尚未挂接父子关系的结果行。
    init(key: SearchResultTreeKey, value: SearchResultTreeValue) {
        self.key = key
        self.value = value
    }
}

@MainActor
public final class SearchResultsPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public var onActivate: ((UUID, UUID) -> Void)?
    public var onRemoveBatches: (([UUID]) -> Void)?
    public var onRemove: (([SearchResultRemoval]) -> Void)?
    public var onPreferencesChange: ((SearchResultPreferences) -> Void)?
    public internal(set) var preferences = SearchResultPreferences()
    public var onClose: (() -> Void)?
    public var onCopyLines: (([SearchResultHitSelection]) -> Void)?
    public var onPresentationChange: (() -> Void)?
    public private(set) var batches: [SearchResultBatchPresentation] = []
    public internal(set) var visibleMatchCount = 0
    public internal(set) var visibleRowCount = 0
    /// 业务作用：面板拥有未确认筛选时保留原生输入上下文，拥有者不能隐藏该视图以结束候选。
    /// 参数说明: 无。
    /// 返回：存在候选或全文筛选草稿时为真。
    public var isEditingInput: Bool {
        filter.isEditingInput
    }
    let outline = SearchResultOutline()
    let scroll = NSScrollView()
    let filter = SearchInputBox(frame: .zero)
    let feedback = NSTextField(labelWithString: "搜索结果按批次、文件和命中分组。")
    var roots: [SearchResultTreeItem] = []
    var items: [SearchResultTreeKey: SearchResultTreeItem] = [:]
    var filtered: [FilteredSearchResultBatch] = []
    var hitOrder: [SearchResultTreeKey] = []
    var hitIndices: [SearchResultTreeKey: Int] = [:]
    var hitValues: [SearchPreviewRow] = []
    var hitDisplayKeys: [SearchResultTreeKey: SearchResultTreeKey] = [:]
    var displayMembers: [SearchResultTreeKey: [SearchResultTreeKey]] = [:]
    var fileDisplayCounts: [SearchResultTreeKey: Int] = [:]
    var lastActivatedHit: SearchResultTreeKey?
    var expanded: Set<SearchResultTreeKey> = []
    var presentation = UUID()
    var filterTask: Task<Void, Never>?
    var rebuilding = false
    let clearBatch = NSButton(title: "删除所选", target: nil, action: nil)
    let clearAll = NSButton(title: "清空", target: nil, action: nil)
    let clearPrevious = NSButton(checkboxWithTitle: "清除旧结果", target: nil, action: nil)
    let oneRowPerLine = NSButton(checkboxWithTitle: "每行一项", target: nil, action: nil)

    /// 业务作用：提供独立的多批次结果树和筛选入口，结果呈现不占用文档标签或正文输入。
    /// 参数说明:
    /// - frame: 初始结果区域。
    /// 返回：空原生面板，展开、复制、清除和关闭只作用于结果元数据。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        let toolbar = NSStackView(views: [
            command("↑", "previous", "上一命中"), command("↓", "next", "下一命中"),
            command("复制结果", "copy", "复制所选分组或全部可见结果"),
            command("复制路径", "paths", "复制所选文件的完整原始路径"),
            sourceActions(),
            oneRowPerLine,
            command("展开", "expand", "展开全部结果"), command("折叠", "collapse", "折叠全部结果"),
            clearBatch, clearAll, command("关闭", "close", "隐藏结果并保留已有批次"),
        ])
        toolbar.spacing = 4
        for button in [clearBatch, clearAll] {
            button.target = self
            button.action = #selector(performCommand(_:))
            button.identifier = NSUserInterfaceItemIdentifier(button === clearBatch ? "remove" : "clear")
            button.controlSize = .small
            button.bezelStyle = .rounded
        }
        root.addArrangedSubview(toolbar)
        clearBatch.toolTip = "只删除所选展示条目；批次或文件分组包含被筛选隐藏的后代，不修改源文件。"
        filter.placeholderString = "筛选已有结果的路径和上下文（区分大小写）"
        filter.toolTip = "区分大小写，按原始路径和已显示上下文逐字筛选；最多 16 KiB，不重读源文件。"
        filter.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        filter.onCommittedChange = {
            [weak self] raw in self?.applyFilter(raw)
        }
        filter.onEditingStateChange = {
            [weak self] editing in
            guard let self else {
                return
            }
            if editing {
                self.cancelFilter()
            }
            else {
                self.applyFilter(self.filter.committedStringValue)
            }
        }
        filter.onSubmit = {
            [weak self] _ in self?.activateSelection()
        }
        filter.onCancel = {
            [weak self] in self?.onClose?()
        }
        filter.onFeedback = {
            [weak self] message in self?.feedback.stringValue = message
        }
        clearPrevious.controlSize = .small
        clearPrevious.target = self
        clearPrevious.action = #selector(resultPreferencesChanged)
        clearPrevious.toolTip = "后续查询完整发布时清除旧批次；失败或取消保留历史。"
        clearPrevious.setContentHuggingPriority(.required, for: .horizontal)
        oneRowPerLine.controlSize = .small
        oneRowPerLine.target = self
        oneRowPerLine.action = #selector(resultPreferencesChanged)
        oneRowPerLine.toolTip = "按匹配起始行合并展示；上下命中仍遍历每个完整匹配，删除合并项包含该行全部可见匹配。"
        oneRowPerLine.setContentHuggingPriority(.required, for: .horizontal)
        let filterRow = NSStackView(views: [filter, clearPrevious])
        filterRow.spacing = 6
        root.addArrangedSubview(filterRow)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("search-result"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 21
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateClicked)
        outline.onActivate = {
            [weak self] in self?.activateSelection()
        }
        outline.onCopy = {
            [weak self] in self?.copyResults()
        }
        outline.onRemove = {
            [weak self] in self?.removeSelectedResults()
        }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        root.addArrangedSubview(scroll)
        feedback.font = NSFont.systemFont(ofSize: 10)
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(feedback)
        for view in [toolbar, filterRow, scroll, feedback] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        updateCommands()
    }

    /// 业务作用：搜索结果由运行期模型建立，不从原生视图归档恢复失效定位。
    /// 参数说明:
    /// - coder: 系统视图归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：全部批次通过身份和容量校验后才更新结果来源，未知或超限输入不替换既有树。
    /// 参数说明:
    /// - batches: 按最新在前排列的完整结果历史。
    /// 返回：至多二十批、十万命中及 64 MiB 元数据进入面板，既有已确认筛选条件继续适用。
    public func present(_ batches: [SearchResultBatchPresentation]) throws {
        guard batches.count <= 20, Set(batches.map(\.id)).count == batches.count else {
            throw NateError.message("搜索结果批次超过二十项或身份重复，既有结果保留。")
        }
        var bytes = 0
        var rows = 0
        for batch in batches {
            let footprint = try batch.validatedFootprint()
            guard footprint <= 64 * 1024 * 1024 - bytes else {
                throw NateError.message("结果历史超过 64 MiB，既有结果保留。")
            }
            bytes += footprint
            guard batch.initialMatchCount <= 100_000 - rows else {
                throw NateError.message("结果历史超过十万个匹配，既有结果保留。")
            }
            rows += batch.initialMatchCount
        }
        self.batches = batches
        if batches.isEmpty {
            // 清空立即撤销可见旧树，未确认筛选草稿仍留在字段中而不保留已移除的导航对象。
            cancelFilter()
            publish(SearchResultFilterOutput(batches: [], visibleRows: 0))
            return
        }
        applyFilter(filter.committedStringValue)
    }

    /// 业务作用：批次替换或新筛选开始时先撤销旧计算和导航资格，迟到结果不能重建已经清除的树。
    /// 参数说明: 无。
    /// 返回：运行期呈现身份先改变，随后取消旧任务并收回句柄。
    func cancelFilter() {
        // 先失效再取消，已经算完但尚未回到主执行域的筛选同样不能发布。
        presentation = UUID()
        filterTask?.cancel()
        filterTask = nil
        onPresentationChange?()
    }

    /// 业务作用：筛选只使用已确认原文与不可变结果快照，候选或全文草稿不改变当前完成视图。
    /// 参数说明:
    /// - raw: 最新确认的完整字面筛选。
    /// 返回：后台完整结果通过身份复验后替换可见树，失败保留上一完成视图。
    func applyFilter(_ raw: String) {
        cancelFilter()
        guard !filter.isEditingInput else {
            feedback.stringValue = "请先确认或取消筛选输入，已有结果保持可见。"
            return
        }
        let identity = presentation
        let input = filter.navigationIdentity
        let batches = self.batches
        if raw.isEmpty {
            let visible = batches.map {
                FilteredSearchResultBatch(
                    batch: $0,
                    files: $0.files,
                    notes: $0.notes.enumerated().map {
                        FilteredSearchResultNote(index: $0.offset, text: $0.element)
                    }
                )
            }
            let count = batches.reduce(0) {
                $0
                    + $1.files.reduce(0) {
                        $0 + $1.rows.count
                    }
            }
            publish(SearchResultFilterOutput(batches: visible, visibleRows: count))
            return
        }
        feedback.stringValue = "正在筛选，暂时保留上一完成视图。"
        filterTask = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.presentation == identity {
                    self.filterTask = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try SearchResultFilter.apply(batches, query: raw)
                }
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 字段往返修改、批次清除和新候选都撤销旧筛选，不能借相同展示文字重新获得权限。
                guard !Task.isCancelled, self.presentation == identity,
                    self.filter.navigationIdentity == input, !self.filter.isEditingInput
                else {
                    return
                }
                self.publish(result)
            }
            catch {
                if self.presentation == identity, self.filter.navigationIdentity == input,
                    !self.filter.isEditingInput, !(error is CancellationError)
                {
                    self.feedback.stringValue = error.localizedDescription
                }
            }
        }
    }

    /// 业务作用：结果工具按钮只发出当前内存模型的操作，不向文件系统授予读取或写入权。
    /// 参数说明:
    /// - title: 可见按钮标签。
    /// - id: 稳定动作标识。
    /// - help: 完整业务说明。
    /// 返回：已连接当前面板的原生按钮。
    func command(_ title: String, _ id: String, _ help: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performCommand(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }
}

@MainActor
final class SearchResultOutline: NSOutlineView {
    var onActivate: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRemove: (() -> Void)?

    /// 业务作用：Enter 与双击采用同一稳定结果激活入口，其余导航保留原生树表行为。
    /// 参数说明:
    /// - event: 当前键盘输入。
    /// 返回：Enter 请求当前命中，Delete 删除所选展示条目，其它按键由原生树表处理。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
        }
        else if event.keyCode == 51 || event.keyCode == 117 {
            onRemove?()
        }
        else {
            super.keyDown(with: event)
        }
    }

    /// 业务作用：键盘复制和工具栏复制共用完整结果元数据，不依赖树表的行标题摘要。
    /// 参数说明:
    /// - sender: 原生命令来源。
    /// 返回：拥有者把所选结果写入系统剪贴板。
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
}
