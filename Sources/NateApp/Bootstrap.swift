import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage
import NateSyntax
import NateUI

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate {
    nonisolated let fileAccess = CoordinatedFileAccess(coordinator: WorkspaceFileCoordinator())
    nonisolated let fileOperations = FileOperationLedger()
    var documents: [WorkspaceDocument] = []
    var activeID: UUID?
    var active: WorkspaceDocument? {
        documents.first {
            $0.buffer.id == activeID
        }
    }
    var mainWindow: EditorWindow?
    var registry: LanguageRegistry?
    var completionCatalog: CompletionCatalog?
    var functionListCatalog: FunctionListCatalog?
    var structureTask: Task<Void, Never>?
    var directoryWorkspace: DirectoryWorkspaceController?
    let sidebarRecovery = SidebarRecoveryRuntime()
    let pausedWorkspace = PausedWorkspaceRuntime()
    let multipleSelection = MultipleSelectionRuntime()
    let columnEditing = ColumnEditingRuntime()
    let historyAction = HistoryActionRuntime()
    let projectPanelStates = [
        ProjectPanelState(),
        ProjectPanelState(),
        ProjectPanelState(),
    ]
    var projectOpenTask: Task<Void, Never>?
    var projectOpenGeneration = UUID()
    var structureGeneration = UUID()
    var structureRequestKey: String?
    var completionTask: Task<Void, Never>?
    var completionGeneration = UUID()
    var codecs: LegacyCodecCatalog?
    var userLanguages: [String: UDLDefinition] = [:]
    var userLanguageSources: [String: URL] = [:]
    var userLanguageBaselines: [String: DiskBaseline] = [:]
    var publishingResources = false
    var findWindow: FindReplaceWindow?
    let searchSettingsIO = IOExecutor(
        name: "nate.search.settings",
        concurrency: 1,
        maximumStalled: 0
    )
    var searchSettingsURL: URL?
    var searchSettingsState = SearchWindowState()
    var searchSettingsBaseline: DiskBaseline?
    var searchSettingsReady = false
    var searchSettingsError: String?
    var pendingSearchSettings: SearchWindowState?
    var searchSettingsTask: Task<Void, Never>?
    var fileTasksWindow: FileTasksWindow?
    var savedBackupsWindow: SavedBackupsWindow?
    var savedBackupRecords: [SavedFileBackup] = []
    var backupBrowserTask: Task<Void, Never>?
    var backupBrowserGeneration = UUID()
    let fileIO = IOExecutor(name: "nate.files", concurrency: 2)
    let readIO = IOExecutor(name: "nate.reads", concurrency: 2)
    let recoveryIO = IOExecutor(name: "nate.recovery", concurrency: 1, maximumStalled: 0)
    let commandIO = IOExecutor(name: "nate.commands", concurrency: 1, maximumStalled: 0)
    var externalCommandTask: Task<Void, Never>?
    var lastExternalOutput: String?
    var recovery: RecoveryStore?
    var saveBackupStore: SaveBackupStore?
    var saveBackupPolicy = SaveBackupPolicy()
    var saveBackupSettingsError: String?
    var recoveryReady = false
    var instanceLease: InstanceLease?
    var instanceInbox: InstanceInbox?
    var processingInstanceRequests = false
    var instanceRequestTask: Task<Void, Never>?
    var startupArguments: CLIArguments?
    var applicationSupport: URL?
    var autosaveTask: Task<Void, Never>?
    var recoveryTask: Task<Bool, Never>?
    var lastRecoverySucceeded = false
    var nextRecoveryRetry = ContinuousClock.now
    var recoveryFailureCount = 0
    var nextRecoveryCollection = ContinuousClock.now
    var initialRecoveryConfirmation = true
    var publishedRecoveryWorkspace: RecoveryWorkspaceState?
    var searchTask: Task<Void, Never>?
    var incrementalTask: Task<Void, Never>?
    var incrementalOrigin: IncrementalSearchOrigin?
    var incrementalGeneration = UUID()
    var incrementalOptions = IncrementalSearchOptions()
    var incrementalDefaults: UserDefaults?
    let incrementalHighlights = IncrementalHighlightRuntime()
    let selectedTextPreferences = SelectedTextHighlightPreferencesRuntime()
    var searchNavigationEvidence: SearchNavigationEvidence?
    var searchNavigationGeneration = UUID()
    var externalObservationTask: Task<Void, Never>?
    var externalStamps: [UUID: FileStamp] = [:]
    var targetReservations: [String: UUID] = [:]
    var queryGeneration = UUID()
    var quickFindGeneration: UUID?
    var closing = false
    var closingDocumentIDs: Set<UUID> = []
    var initialized = false
    var pendingURLs: [URL] = []
    var recentClosed: [ClosedTab] = []
    var clipboardHistory: [String] = []
    var autosaveEnabled = true
    var macroRecording = false
    var macroActions: [MacroAction] = []
    var macroPlaying = false
    var previousTextForMacro = PieceTree()
    var retainedWindows: [NSWindowController] = []
    var resultNavigation: [ResultNavigation] = []
    var resultBatches: [SearchResultBatchState] = []
    var projectSearchScope: (generation: UUID, panels: Set<Int>)?
    var resultNavigationTask: Task<Void, Never>?
    var resultNavigationGeneration = UUID()
    var resultExportTask: Task<Void, Never>?
    var resultExportGeneration = UUID()
    var resultPathOpenTask: Task<Void, Never>?
    var resultPathOpenGeneration = UUID()
    var markCopyTask: Task<Void, Never>?
    var markCopyGeneration = UUID()
    var markSearchGeneration: UUID?
    let styleMarks = StyleMarkRuntime()
    let bookmarkActions = BookmarkActionRuntime()
    var recentFiles: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        }
        set {
            UserDefaults.standard.set(Array(newValue.prefix(30)), forKey: "recentFiles")
        }
    }

    /// 业务作用：完成资源与恢复装配后显示可输入窗口，冷启动打开事件先排队。
    /// 参数说明:
    /// - notification: 系统启动完成通知。
    /// 返回：异步装配，主事件循环保持可响应。
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveInstanceRequest(_:)),
            name: InstanceInbox.notification,
            object: nil
        )
        Task {
            await bootstrap()
        }
    }

    /// 业务作用：固定应用数据目录并恢复可靠索引，冲突内容不自动覆盖原路径。
    /// 参数说明: 无。
    /// 返回：窗口、命令与每秒调度全部启动。
    func bootstrap() async {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Nate", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            applicationSupport = support
            let arguments = try CLIArguments(Array(CommandLine.arguments.dropFirst()))
            startupArguments = arguments
            let inbox = try await fileIO.run {
                try InstanceInbox(directory: support.appendingPathComponent("Requests", isDirectory: true))
            }
            instanceInbox = inbox
            guard let lease = InstanceLease(path: support.appendingPathComponent("workspace.lock").path)
            else {
                let payload = try JSONEncoder().encode(arguments)
                _ = try await fileIO.run {
                    try inbox.enqueue(payload)
                }
                DistributedNotificationCenter.default().postNotificationName(
                    InstanceInbox.notification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                let existing = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "io.github.Nasa666999.nate"
                )
                .first {
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                }
                existing?.activate(options: [])
                NSApp.terminate(nil)
                return
            }
            instanceLease = lease
            saveBackupStore = SaveBackupStore(directory: support.appendingPathComponent("SavedBackups"))
            loadSaveBackupPolicy()
            loadIncrementalOptions(from: .standard)
            loadSelectedTextHighlightOptions(from: .standard)
            loadMultipleSelectionOptions(from: .standard)
            await loadSearchSettings()
            if arguments.noRestore {
                // 跳过恢复时先保留整个旧工作区，不能用空索引覆盖其唯一正文引用。
                try await recoveryIO.run {
                    let old = support.appendingPathComponent("Recovery", isDirectory: true)
                    if FileManager.default.fileExists(atPath: old.path) {
                        try FileManager.default.moveItem(
                            at: old,
                            to: support.appendingPathComponent(
                                "Recovery-paused-" + UUID().uuidString,
                                isDirectory: true
                            )
                        )
                    }
                }
            }
            let store = RecoveryStore(
                directory: support.appendingPathComponent("Recovery", isDirectory: true)
            )
            recovery = store
            codecs = try LegacyCodecCatalog(
                directory: SystemIntegration.resourceDirectory().appendingPathComponent("encodings")
            )
            registry = try LanguageRegistry(
                directory: SystemIntegration.resourceDirectory().appendingPathComponent("languages")
            )
            let restored = try await recoveryIO.read {
                let result = try store.restoreSnapshots()
                return (
                    documents: result.documents.map {
                        (record: $0.metadata, tree: $0.text, reference: $0.reference)
                    }, active: result.active
                )
            }
            recoveryReady = true
            do {
                let directory = SystemIntegration.resourceDirectory().appendingPathComponent("completion")
                completionCatalog = try await fileIO.run {
                    try CompletionCatalog(directory: directory)
                }
            }
            catch {
                SystemIntegration.alert("补全资源未载入", error.localizedDescription)
            }
            do {
                let directory = SystemIntegration.resourceDirectory().appendingPathComponent("function-list")
                functionListCatalog = try await fileIO.run {
                    try FunctionListCatalog(directory: directory)
                }
            }
            catch {
                SystemIntegration.alert("函数列表资源未载入", error.localizedDescription)
            }
            await loadUserLanguages()
            for (record, tree, reference) in restored.documents {
                let document = WorkspaceDocument(
                    name: record.name,
                    text: record.text,
                    textTree: tree,
                    id: record.id,
                    encoding: record.encoding,
                    lineEnding: record.lineEnding ?? .lf,
                    revision: record.revision
                )
                document.savedEncoding = record.encoding
                document.language = record.language
                document.pinned = record.pinned ?? false
                document.buffer.selections = record.selections.filter {
                    document.buffer.text.isBoundary($0.anchor) && document.buffer.text.isBoundary($0.head)
                }
                if document.buffer.selections.isEmpty {
                    document.buffer.selections = [TextSelection(anchor: 0, head: 0)]
                }
                document.buffer.bookmarks = record.bookmarks
                document.buffer.isReadOnly = record.readOnly
                document.recoveryReference = reference
                document.recoveryRevision = record.revision
                // 已恢复引用已经通过完整依赖校验；按原元数据记账，不能把随后默认化的视图状态冒充持久化。
                document.lastRecoveryMetadata = record.metadataKey
                document.state = "恢复正文已载入 · 尚未选择原文件"
                if let path = record.path {
                    // 恢复正文先显示，原路径核验完成前不授予自动写入权。
                    document.pendingOriginalPath = path
                    document.pendingOriginalBaseline = record.baseline
                    document.state = "恢复内容已载入 · 原路径正在核验"
                }
                documents.append(document)
            }
            activeID = restored.active
            publishedRecoveryWorkspace = RecoveryWorkspaceState(
                documentIDs: documents.map {
                    $0.buffer.id
                },
                activeID: restored.active
            )
        }
        catch {
            SystemIntegration.alert("启动信息", error.localizedDescription)
            // 未取得进程级写入权时不得退化成另一个可自动写盘的工作区。
            if instanceLease == nil {
                NSApp.terminate(nil)
                return
            }
        }
        if documents.isEmpty {
            _ = newDocument()
        }
        if active == nil {
            activeID = documents.first?.buffer.id
        }
        guard let active else {
            return
        }
        let window = EditorWindow(document: active.buffer)
        let defaults = UserDefaults.standard
        autosaveEnabled =
            defaults.object(forKey: "autosaveEnabled") == nil || defaults.bool(forKey: "autosaveEnabled")
        let size = defaults.double(forKey: "fontSize")
        if (7...72).contains(size) {
            window.editor.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        window.editor.wrapLines = defaults.bool(forKey: "wrapLines")
        window.editor.showSymbols = defaults.bool(forKey: "showSymbols")
        mainWindow = window
        connect(window)
        await loadSidebarRecovery()
        buildMenus()
        refreshUI()
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        window.window?.makeFirstResponder(window.editor)
        NSApp.activate(ignoringOtherApps: true)
        initialized = true
        startAutosave()
        for document in documents where document.pendingOriginalPath != nil {
            verifyRecoveryBinding(document)
        }
        let paths = pendingURLs
        pendingURLs.removeAll()
        for url in paths {
            await openFile(url)
        }
        await handleCLI(startupArguments)
        await drainInstanceRequests()
    }

    /// 业务作用：所有界面入口统一委派给应用命令与文件协调。
    /// 参数说明:
    /// - window: 待连接主窗口。
    /// 返回：窗口只发出意图，不执行磁盘访问。
    func connect(_ window: EditorWindow) {
        window.projectPanels.onAction = {
            [weak self] index, action, node in
            self?.routeProjectAction(action, panel: index, node: node)
        }
        window.projectPanels.onOpen = {
            [weak self] index, node in self?.openProjectNode(node, panel: index)
        }
        window.projectPanels.onSelectionChange = {
            [weak self] _ in self?.cancelProjectOpen()
        }
        window.projectPanels.onHide = {
            [weak self, weak window] in
            self?.cancelProjectOpen()
            window?.setProjectsVisible(false)
        }
        window.onIncrementalQuery = {
            [weak self] query, options in self?.searchIncrementally(query, options: options)
        }
        window.selectedTextHighlightSettings = {
            [weak self, weak window] target in
            guard let self, let window else {
                return nil
            }
            return self.selectedTextHighlightSettings(for: target, in: window)
        }
        window.onIncrementalOptions = {
            [weak self] options in self?.saveIncrementalOptions(options)
        }
        window.incrementalSearch.onHighlightChange = {
            [weak self] query, options in self?.refreshIncrementalHighlights(query, options: options)
        }
        window.onIncrementalSuspend = {
            [weak self] in
            guard let self else {
                return false
            }
            let pending = self.incrementalTask != nil || self.incrementalHighlights.key != nil
            self.cancelIncrementalSearch()
            self.cancelIncrementalHighlights()
            return pending
        }
        window.onCommand = {
            [weak self] in self?.route($0)
        }
        window.onSelect = {
            [weak self] in self?.activate($0)
        }
        window.onCloseTab = {
            [weak self] id in
            Task {
                await self?.closeDocument(id)
            }
        }
        window.onTabAction = {
            [weak self] id, action in self?.tabAction(id, action)
        }
        window.onEdit = {
            [weak self] in self?.didEdit()
        }
        window.onWindowClose = {
            NSApp.terminate(nil)
        }
        window.onOpenURLs = {
            [weak self] urls in
            Task {
                for url in urls {
                    await self?.openFile(url)
                }
            }
        }
        window.onResult = {
            [weak self] index in self?.navigateResult(index)
        }
        window.searchResults.onActivate = {
            [weak self, weak window] batch, hit in
            guard let self, self.mainWindow === window else {
                return
            }
            self.navigateSearchResult(batch: batch, hit: hit)
        }
        window.searchResults.onRemoveBatches = {
            [weak self, weak window] ids in
            guard let self, self.mainWindow === window else {
                return
            }
            self.removeSearchResultBatches(ids)
        }
        window.searchResults.onRemove = {
            [weak self, weak window] requests in
            guard let self, self.mainWindow === window else {
                return
            }
            self.removeSearchResults(requests)
        }
        connectSearchResultSources(window)
        window.searchResults.setPreferences(searchSettingsState.results)
        window.searchResults.onPreferencesChange = {
            [weak self, weak window] preferences in
            guard let self, self.mainWindow === window else {
                return
            }
            self.setSearchResultPreferences(preferences)
        }
    }

    /// 业务作用：建立临时文档，不在用户尚未选择路径时擅自创建文件。
    /// 参数说明: 无。
    /// 返回：新文档进入工作区和恢复保护。
    @discardableResult
    func newDocument() -> WorkspaceDocument {
        let document = WorkspaceDocument(name: "新文档 \(documents.count + 1)")
        if closing {
            // 已开始的关闭可能需要替代空标签，退出收束期间新标签同样不能重新开放正文输入。
            document.setEditingSuspension(.applicationTermination, active: true)
        }
        if !recoveryReady {
            document.recoveryError = "恢复索引尚未完成校验，现有记录保持原状。"
        }
        documents.append(document)
        activate(document.buffer.id)
        return document
    }

    /// 业务作用：激活既有文档并同步当前语言和保存状态。
    /// 参数说明:
    /// - id: 稳定文档身份。
    /// 返回：正常工作区中切换正文视口；退出收束期间拒绝新的活动身份。
    func activate(_ id: UUID) {
        // 退出已经固定工作区保护集合，标签选择不能在最终索引发布期间改变活动身份。
        guard !closing else {
            return
        }
        guard
            let document = documents.first(where: {
                $0.buffer.id == id
            })
        else {
            return
        }
        // 切换标签结束原视图的增量会话，旧计算不能沿稳定 UUID 导航到新活动正文。
        cancelIncrementalSearch(resetOrigin: true)
        mainWindow?.editor.finishComposition()
        cancelCompletion()
        activeID = id
        mainWindow?.showDocument(document.buffer)
        if mainWindow?.isIncrementalSearchVisible == true {
            mainWindow?.incrementalSearch.feedback.stringValue = "文档已切换，可继续查找。"
        }
        previousTextForMacro = document.buffer.text
        refreshUI()
    }

    /// 业务作用：编辑通知只标记待保存，不把每次输入排成全文 I/O。
    /// 参数说明: 无。
    /// 返回：标签立即反映修改，保存周期独立推进。
    func didEdit() {
        guard let active else {
            return
        }
        cancelBookmarkAction()
        cancelMultipleSelection()
        cancelQuickFind()
        cancelColumnInsertion()
        cancelHistoryAction()
        // 新正文撤销旧源行复制，等待读取不能再发布先前修订的剪贴板内容。
        cancelSearchResultExport()
        cancelSearchResultPathOpen()
        cancelDocumentMarkCopy()
        cancelSearchMarking()
        // 新正文已提交，原目录打开不再拥有旧修订与原光标的发布资格。
        directoryWorkspace?.cancelOpen()
        cancelCompletion()
        // 正文已经进入新修订，原增量快照和起点都不能继续发布。
        cancelIncrementalSearch(resetOrigin: true)
        if mainWindow?.isIncrementalSearchVisible == true {
            mainWindow?.incrementalSearch.feedback.stringValue = "正文已改变，可继续查找。"
        }
        active.dirtyHint = true
        if macroRecording && !macroPlaying {
            recordTextChange(active)
        }
        previousTextForMacro = active.buffer.text
        mainWindow?.refreshEditors()
        refreshUI()
        refreshVisibleIncrementalHighlights()
    }

}
