import AppKit
import NateCore
import NateSyntax

@MainActor
public final class ThemePreferencesWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    public typealias Importer = @MainActor (URL) async throws -> EditorThemeImportResult
    public typealias Exporter = @MainActor (EditorThemeDefinition, URL) async throws -> Void

    let importer: Importer
    let exporter: Exporter
    let languages: [LanguageDefinition]
    let userLanguages: [String: UDLDefinition]
    let styleNames: [String: [String: String]]
    var entries: [EditorThemeEntry]
    var selectedID: UUID?
    var editingID: UUID?
    var editingScope = "surface"
    var editingKey: String?
    var choices: [SyntaxThemeChoice] = []
    var updating = false
    var isRunning = false
    var completion: CheckedContinuation<EditorThemeLibrary?, Never>?
    var operation: Task<Void, Never>?
    var operationID: UUID?
    var savedLibrary: EditorThemeLibrary?
    var compatibilityReports: [String] = []
    let themes = NSPopUpButton()
    let scopes = NSPopUpButton()
    let nameField = NSTextField(string: "")
    let styleTable = NSTableView()
    let fields = ThemeStyleFields()
    let watch = NSButton(checkboxWithTitle: "跟随本地导入来源的配色变化", target: nil, action: nil)
    let sourceLabel = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let reportsButton = NSButton(title: "查看导入说明…", target: nil, action: nil)
    var managedButtons: [NSButton] = []

    /// 业务作用：主题窗口维护完整独立草稿，管理、导入和样式编辑不直接取得偏好写入权。
    /// 参数说明:
    /// - library: 打开窗口时的完整主题库与当前选择。
    /// - languages: 当前可选择的内置及已安装语言。
    /// - userLanguages: 当前完整用户语言及真实样式名称。
    /// - styleNames: 当前完整原生样式名称资源。
    /// - warning: 当前原归档的持续说明。
    /// - importer: 用户明确选择文件后的受保护读取入口。
    /// - exporter: 用户明确选择目标后的受保护独立导出入口。
    /// 返回：完整主题管理与属性编辑窗口，尚不写入偏好或改变正文。
    public init(
        library: EditorThemeLibrary,
        languages: [LanguageDefinition],
        userLanguages: [String: UDLDefinition],
        styleNames: [String: [String: String]] = [:],
        warning: String? = nil,
        importer: @escaping Importer,
        exporter: @escaping Exporter
    ) {
        self.importer = importer
        self.exporter = exporter
        self.languages = languages.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        self.userLanguages = userLanguages
        self.styleNames = styleNames
        entries = library.entries
        selectedID = library.selectedID
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "样式与主题"
        window.minSize = NSSize(width: 860, height: 580)
        window.delegate = self
        window.setFrameAutosaveName("")
        buildContent(warning: warning)
        reloadThemes()
    }

    /// 业务作用：主题窗口只通过完整主题库构造，不从任意界面归档恢复资源权限。
    /// 参数说明:
    /// - coder: 系统归档来源。
    /// 返回：不支持此初始化路径。
    public required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：主题表单沿异步 sheet 保持事件循环，文件读取和热更新不能被同步模态等待阻塞。
    /// 参数说明:
    /// - parent: 当前明确来源窗口，为空时采用独立设置窗口。
    /// 返回：明确应用且全部字段合法时提供完整库；取消或关闭返回空。
    public func present(for parent: NSWindow?) async -> EditorThemeLibrary? {
        guard let window, !Task.isCancelled else {
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation in
                completion = continuation
                isRunning = true
                if let parent {
                    parent.beginSheet(window) {
                        [weak self] response in
                        self?.finishDialog(response == .OK ? self?.savedLibrary : nil)
                    }
                }
                else {
                    window.center()
                    showWindow(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelEditing()
            }
        }
    }

    /// 业务作用：表单结果只交付一次，结束 sheet 之前先撤销文件任务和旧草稿发布资格。
    /// 参数说明:
    /// - library: 已完整校验并明确应用的库；为空表示取消。
    /// 返回：窗口结束且等待方取得唯一结果，重复结束回调不再次发布。
    func finishDialog(_ library: EditorThemeLibrary?) {
        guard isRunning else {
            return
        }
        isRunning = false
        savedLibrary = library
        operationID = nil
        operation?.cancel()
        operation = nil
        if let window {
            window.sheetParent?.endSheet(window, returnCode: library == nil ? .cancel : .OK)
            window.orderOut(nil)
        }
        let pending = completion
        completion = nil
        pending?.resume(returning: library)
    }

    /// 业务作用：应用关闭或偏好来源撤销时明确结束模态草稿，不能只隐藏窗口而留下后台文件动作。
    /// 参数说明: 无。
    /// 返回：取消当前草稿及文件任务，窗口退出模态编辑。
    public func cancelEditing() {
        cancelDialog(nil)
        window?.orderOut(nil)
    }

    /// 业务作用：关闭主题窗口等同取消草稿，不能把窗口位置或输入中间态当作完整应用。
    /// 参数说明:
    /// - sender: 当前主题窗口。
    /// 返回：结束当前模态草稿并允许关闭，不改变保存结果。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isRunning {
            cancelDialog(nil)
        }
        return true
    }

    /// 业务作用：样式列表只呈现当前明确作用范围，不把其它主题的字段混入当前草稿。
    /// 参数说明:
    /// - tableView: 当前原生样式列表。
    /// 返回：当前完整有限目录的行数。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        choices.count
    }

    /// 业务作用：列表文字使用稳定样式目录，身份与显示名称分别持有。
    /// 参数说明:
    /// - tableView: 当前样式列表。
    /// - tableColumn: 当前文字列。
    /// - row: 当前合法目录位置。
    /// 返回：对应原生标签；越界时为空。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard choices.indices.contains(row) else {
            return nil
        }
        return NSTextField(labelWithString: choices[row].name)
    }

    /// 业务作用：切换样式前先确认旧项草稿，非法输入不能因选中另一行而丢失。
    /// 参数说明:
    /// - notification: 当前原生列表的选择变化。
    /// 返回：合法旧草稿保存到内存后安装新项，否则保留旧编辑目标并说明原因。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else {
            return
        }
        let next = styleTable.selectedRow
        do {
            try saveEditingStyle()
            loadStyle(at: next)
        }
        catch {
            showFailure(error)
            updating = true
            if let editingKey,
                let old = choices.firstIndex(where: {
                    $0.key == editingKey
                })
            {
                styleTable.selectRowIndexes(IndexSet(integer: old), byExtendingSelection: false)
            }
            updating = false
        }
    }

    /// 业务作用：主题管理和属性控件按语义分组，应用与取消始终具有明确独立入口。
    /// 参数说明:
    /// - warning: 原偏好不能解释时保留的持续说明。
    /// 返回：完整原生主题选择、管理、作用范围和样式编辑控件建立。
    private func buildContent(warning: String?) {
        themes.identifier = NSUserInterfaceItemIdentifier("themeChoice")
        themes.target = self
        themes.widthAnchor.constraint(equalToConstant: 220).isActive = true
        themes.action = #selector(themeChanged(_:))
        scopes.identifier = NSUserInterfaceItemIdentifier("themeScope")
        scopes.target = self
        scopes.action = #selector(scopeChanged(_:))
        scopes.addItem(withTitle: "整体界面")
        scopes.lastItem?.representedObject = "surface"
        scopes.addItem(withTitle: "通用语法类别")
        scopes.lastItem?.representedObject = "kinds"
        for language in languages {
            scopes.addItem(withTitle: language.name + "（" + language.id + "）")
            scopes.lastItem?.representedObject = "language:" + language.id
        }
        nameField.identifier = NSUserInterfaceItemIdentifier("themeName")
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let top = NSStackView(views: [NSTextField(labelWithString: "当前主题"), themes, nameField])
        top.spacing = 10
        let management = NSStackView(views: [
            button("新建", action: #selector(newTheme(_:))),
            button("复制", action: #selector(duplicateTheme(_:))),
            button("删除", action: #selector(deleteTheme(_:))),
            button("导入主题…", action: #selector(importTheme(_:))),
            button("导出 Nate 主题…", action: #selector(exportTheme(_:))),
        ])
        management.spacing = 8
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("style"))
        column.title = "样式"
        column.width = 220
        styleTable.addTableColumn(column)
        styleTable.headerView = nil
        styleTable.dataSource = self
        styleTable.delegate = self
        styleTable.allowsEmptySelection = false
        styleTable.identifier = NSUserInterfaceItemIdentifier("themeStyleList")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = styleTable
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 230).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        let body = NSStackView(views: [scroll, fields])
        body.spacing = 20
        body.alignment = .top
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        sourceLabel.preferredMaxLayoutWidth = 810
        sourceLabel.maximumNumberOfLines = 2
        sourceLabel.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 810
        status.maximumNumberOfLines = 3
        status.stringValue = warning ?? "主题只改变显示；留空或选中继承可沿用原字体和颜色。同名导入保存为新副本。"
        status.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        reportsButton.target = self
        reportsButton.action = #selector(showReports(_:))
        reportsButton.isEnabled = false
        let apply = button("应用并关闭", action: #selector(applyDialog(_:)))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelDialog(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let footer = NSStackView(views: [reportsButton, NSView(), cancel, apply])
        footer.spacing = 12
        let content = NSStackView(views: [top, management, scopes, body, sourceLabel, watch, status, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(content)
        window?.contentView = host
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -20),
            top.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    /// 业务作用：草稿管理动作统一绑定控制器，文件任务期间能统一撤销可变操作资格。
    /// 参数说明:
    /// - title: 当前用户可见动作名称。
    /// - action: 当前完整主题草稿动作。
    /// 返回：已记录在任务保护集合中的原生按钮。
    private func button(_ title: String, action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        managedButtons.append(value)
        return value
    }

    /// 业务作用：非法主题草稿只显示当前字段原因，不关闭窗口或发布部分定义。
    /// 参数说明:
    /// - error: 当前完整校验或文件操作失败原因。
    /// 返回：窗口保留原草稿并显示可处理说明。
    func showFailure(_ error: Error) {
        status.textColor = .systemRed
        status.stringValue = error.localizedDescription
    }
}
