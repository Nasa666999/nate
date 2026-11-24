import AppKit
import NateCore
import NateSyntax

extension ApplicationController {
    /// 业务作用：仅用户手动请求时枚举路径，未命名文档明确以用户主目录为相对基准。
    /// 参数说明: 无。
    /// 返回：候选绑定当前文档和按键偏好，确认时执行可撤销的前缀替换。
    func requestPathCompletion() {
        guard let document = active, let editor = mainWindow?.editor, !closing, !document.closing,
            editor.document === document.buffer, !document.bindingChange,
            let source = editor.completionSource(), let selection = editor.primarySelection
        else {
            return
        }
        cancelCompletion()
        let generation = completionGeneration
        let snapshot = document.buffer.snapshot
        let confirmation = CompletionConfirmationOptions(defaults: configurationDefaults())
        let url = document.url
        let binding = document.targetGeneration
        let base =
            url?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        let current: @MainActor () -> Bool = { [weak self, weak document] in
            // 路径从原磁盘位置解析，另存或改绑即使没有改动正文也不能沿旧基准提交候选。
            guard let self, let document, !self.closing, !document.closing, !Task.isCancelled,
                self.completionGeneration == generation, self.active === document, source.isCurrent(),
                document.targetGeneration == binding, document.url == url, !document.bindingChange
            else {
                return false
            }
            return true
        }
        let caret = selection.head
        let executor = fileIO
        mainWindow?.status.stringValue = "正在补全路径 · 相对基准：" + base.path
        completionTask = Task {
            [weak self, weak editor] in
            guard let self, let editor else {
                return
            }
            do {
                let result = try await executor.runCancellable {
                    token in
                    var start = max(
                        snapshot.text.lineStart(snapshot.text.lineNumber(at: caret)),
                        caret - 65_536
                    )
                    while !snapshot.text.isBoundary(start) {
                        start += 1
                    }
                    let preceding = snapshot.text.text(in: ByteRange(start, caret))
                    var quote: Character?
                    var segment = ""
                    for character in preceding {
                        if character == "\"" || character == "'" {
                            if quote == character {
                                quote = nil
                                segment = ""
                            }
                            else if quote == nil {
                                quote = character
                                segment = ""
                            }
                            else {
                                segment.append(character)
                            }
                        }
                        else if character.isWhitespace && quote == nil {
                            segment = ""
                        }
                        else {
                            segment.append(character)
                        }
                    }
                    let typed = segment
                    let parentText =
                        typed.hasSuffix("/") ? typed : ((typed as NSString).deletingLastPathComponent)
                    let namePrefix = typed.hasSuffix("/") ? "" : (typed as NSString).lastPathComponent
                    let expanded = (parentText as NSString).expandingTildeInPath
                    let directory =
                        expanded.hasPrefix("/")
                        ? URL(fileURLWithPath: expanded, isDirectory: true)
                        : base.appendingPathComponent(expanded, isDirectory: true)
                    let files = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey]
                    )
                    var values: [CompletionCandidate] = []
                    for file in files.sorted(by: {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                            == .orderedAscending
                    }) {
                        try token.check()
                        guard file.lastPathComponent.lowercased().hasPrefix(namePrefix.lowercased()) else {
                            continue
                        }
                        let folder = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                        let prefix =
                            parentText.isEmpty
                            ? "" : parentText.hasSuffix("/") ? parentText : parentText + "/"
                        values.append(
                            CompletionCandidate(
                                text: prefix + file.lastPathComponent + (folder ? "/" : ""),
                                detail: (folder ? "目录 · " : "文件 · ") + directory.path
                            )
                        )
                        if values.count == 201 {
                            break
                        }
                    }
                    return CompletionResult(
                        documentID: snapshot.id,
                        revision: snapshot.revision,
                        context: CompletionContext(
                            range: ByteRange(caret - typed.utf8.count, caret),
                            prefix: typed
                        ),
                        candidates: Array(values.prefix(200)),
                        limited: values.count > 200
                    )
                }
                guard current() else {
                    return
                }
                if result.candidates.isEmpty {
                    self.mainWindow?.status.stringValue = "当前路径前缀没有候选 · 相对基准：" + base.path
                }
                editor.presentCompletions(
                    result,
                    signature: nil,
                    tab: confirmation.tab,
                    enter: confirmation.enter,
                    stillCurrent: current
                )
            }
            catch is CancellationError {}
            catch {
                if current() {
                    self.mainWindow?.status.stringValue = "路径补全失败：" + error.localizedDescription
                }
            }
        }
    }
}
