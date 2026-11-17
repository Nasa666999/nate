import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage
import NateSyntax
import NateUI

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate {
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
    let fileIO = IOExecutor(name: "nate.files", concurrency: 2)
    let readIO = IOExecutor(name: "nate.reads", concurrency: 2)
    let recoveryIO = IOExecutor(name: "nate.recovery", concurrency: 1)
    let commandIO = IOExecutor(name: "nate.commands", concurrency: 1)
    var externalCommandTask: Task<Void, Never>?
    var lastExternalOutput: String?
    var recovery: RecoveryStore?
    var recoveryReady = false
    var instanceLease: InstanceLease?
    var instanceInbox: InstanceInbox?
    var processingInstanceRequests = false
    var instanceRequestTask: Task<Void, Never>?
    var startupArguments: CLIArguments?
    var applicationSupport: URL?
    var autosaveTask: Task<Void, Never>?
    var recoveryTask: Task<Bool, Never>?
    var searchTask: Task<Void, Never>?
    var externalObservationTask: Task<Void, Never>?
    var externalStamps: [UUID: FileStamp] = [:]
    var targetReservations: [String: UUID] = [:]
    var queryGeneration = UUID()
    var closing = false
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
            let restored = try await recoveryIO.run {
                let result = try store.restore()
                return (
                    documents: result.documents.map {
                        (record: $0, tree: PieceTree($0.text))
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
            for (record, tree) in restored.documents {
                let document = WorkspaceDocument(
                    name: record.name,
                    text: record.text,
                    textTree: tree,
                    id: record.id,
                    encoding: record.encoding,
                    lineEnding: record.lineEnding ?? .lf
                )
                document.savedEncoding = record.encoding
                document.language = record.language
                document.buffer.selections = record.selections.filter {
                    document.buffer.text.isBoundary($0.anchor) && document.buffer.text.isBoundary($0.head)
                }
                if document.buffer.selections.isEmpty {
                    document.buffer.selections = [TextSelection(anchor: 0, head: 0)]
                }
                document.buffer.bookmarks = record.bookmarks
                document.buffer.isReadOnly = record.readOnly
                if let path = record.path {
                    // 恢复正文先显示，原路径核验完成前不授予自动写入权。
                    document.pendingOriginalPath = path
                    document.pendingOriginalBaseline = record.baseline
                    document.state = "恢复内容已载入 · 原路径正在核验"
                }
                documents.append(document)
            }
            activeID = restored.active
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
    }

    /// 业务作用：建立临时文档，不在用户尚未选择路径时擅自创建文件。
    /// 参数说明: 无。
    /// 返回：新文档进入工作区和恢复保护。
    @discardableResult
    func newDocument() -> WorkspaceDocument {
        let document = WorkspaceDocument(name: "新文档 \(documents.count + 1)")
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
    /// 返回：切换正文视口，原文档仍由调度器保护。
    func activate(_ id: UUID) {
        guard
            let document = documents.first(where: {
                $0.buffer.id == id
            })
        else {
            return
        }
        mainWindow?.editor.finishComposition()
        cancelCompletion()
        activeID = id
        mainWindow?.showDocument(document.buffer)
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
        cancelCompletion()
        active.dirtyHint = true
        if macroRecording && !macroPlaying {
            recordTextChange(active)
        }
        previousTextForMacro = active.buffer.text
        mainWindow?.refreshEditors()
        refreshUI()
    }

    /// 业务作用：将实际文档与保存通道状态显示到标签、标题和状态栏。
    /// 参数说明: 无。
    /// 返回：不更改焦点、选区或视口。
    func refreshUI() {
        guard let active, let window = mainWindow else {
            return
        }
        window.updateTabs(
            documents.map {
                TabPresentation(
                    id: $0.buffer.id,
                    title: ($0.buffer.isReadOnly ? "🔒 " : "") + $0.name,
                    path: $0.url?.path,
                    selected: $0.buffer.id == activeID,
                    pinned: $0.pinned,
                    dirty: $0.isDirty,
                    failed: $0.failure != nil
                )
            }
        )
        window.window?.title = active.name + " — Nate"
        window.window?.representedURL = active.url
        window.editor.language = registry?.language(active.language)
        if active.language == "markdown" {
            let dark = window.editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            window.editor.userLanguage =
                userLanguages[dark ? "udl:Markdown (preinstalled dark mode)" : "udl:Markdown (preinstalled)"]
        }
        else {
            window.editor.userLanguage = userLanguages[active.language]
        }
        let head = active.buffer.selections.first?.head ?? 0
        let line = active.buffer.text.lineNumber(at: head)
        let lineStart = active.buffer.text.lineStart(line)
        let column: String
        if head - lineStart > 1_048_576 {
            // 超长行状态更新不能在每次输入时复制整段前缀，单位在界面中明确标出。
            column =
                "\((active.buffer.text.utf16Offset(byte: head) ?? 0) - (active.buffer.text.utf16Offset(byte: lineStart) ?? 0) + 1) UTF-16"
        }
        else {
            column = String(active.buffer.text.text(in: ByteRange(lineStart, head)).count + 1)
        }
        let selectionCount = active.buffer.selections.reduce(0) {
            $0 + $1.range.count
        }
        let state: String
        if let recoveryError = active.recoveryError {
            state =
                "⚠ 恢复保存失败：" + recoveryError
                + (active.failure.map {
                    "；原文件：" + $0
                } ?? "")
        }
        else if let failure = active.failure {
            state = (active.recoveryRevision == active.buffer.revision ? "恢复副本已保存；原文件：" : "⚠ 原文件：") + failure
        }
        else {
            state = active.isDirty ? "待保存" : active.state
        }
        window.status.stringValue =
            "  \(registry?.language(active.language)?.name ?? active.language)  │  Ln \(line + 1), Col \(column)  ·  选区 \(selectionCount) B / \(active.buffer.selections.count)  │  \(active.encoding.name)  │  \(active.buffer.text.lineCount) 行 · \(active.buffer.text.byteCount) B  │  \(window.editor.overwrite ? "OVR" : "INS")  │  \(state)"
        if window.isStructureVisible {
            requestStructure()
        }
    }
}
