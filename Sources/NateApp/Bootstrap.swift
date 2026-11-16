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
    var codecs: LegacyCodecCatalog?
    var userLanguages: [String: UDLDefinition] = [:]
    var userLanguageSources: [String: URL] = [:]
    var userLanguageBaselines: [String: DiskBaseline] = [:]
    var publishingResources = false
    var findWindow: FindReplaceWindow?
    let fileIO = IOExecutor(name: "nate.files", concurrency: 2)
    let recoveryIO = IOExecutor(name: "nate.recovery", concurrency: 1)
    var recovery: RecoveryStore?
    var instanceLease: InstanceLease?
    var autosaveTask: Task<Void, Never>?
    var recoveryTask: Task<Bool, Never>?
    var searchTask: Task<Void, Never>?
    var externalObservationTask: Task<Void, Never>?
    var externalStamps: [UUID: FileStamp] = [:]
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
            guard let lease = InstanceLease(path: support.appendingPathComponent("workspace.lock").path)
            else {
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
                try store.restore()
            }
            await loadUserLanguages()
            let catalog = codecs
            for record in restored.documents {
                let document = WorkspaceDocument(
                    name: record.name,
                    text: record.text,
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
                    let url = URL(fileURLWithPath: path)
                    let baseline = try? await fileIO.run {
                        try FileStorage.baseline(url)
                    }
                    if baseline == record.baseline, let baseline {
                        document.url = url
                        document.baseline = baseline
                        let loaded = try? await fileIO.run {
                            try FileStorage.load(url, encoding: record.encoding, catalog: catalog)
                        }
                        document.savedText = PieceTree(loaded?.text ?? "")
                        document.evaluateDirty()
                        document.state = document.isDirty ? "恢复内容 · 待保存到原文件" : "已保存"
                    }
                    else {
                        // 原路径身份不一致时以独立恢复文档呈现，禁止自动覆盖。
                        document.name += "（恢复副本）"
                        document.failure = "原文件已变化或不可用，恢复内容需要另存为。原路径：\(path)"
                        document.state = "恢复副本 · 原文件未改动"
                    }
                }
                documents.append(document)
            }
            activeID = restored.active
        }
        catch {
            SystemIntegration.alert("启动信息", error.localizedDescription)
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
        let paths = pendingURLs
        pendingURLs.removeAll()
        for url in paths {
            await openFile(url)
        }
        await handleCLI()
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
        let column =
            active.buffer.text.text(in: ByteRange(active.buffer.text.lineStart(line), head)).count + 1
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
    }
}
