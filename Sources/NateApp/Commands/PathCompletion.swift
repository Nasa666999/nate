import AppKit
import NateCore
import NateSyntax

extension ApplicationController {
    /// 业务作用：仅用户手动请求时枚举路径，未命名文档明确以用户主目录为相对基准。
    /// 参数说明: 无。
    /// 返回：候选绑定当前修订，确认仍是普通可撤销文本事务。
    func requestPathCompletion() {
        guard let document = active, let editor = mainWindow?.editor,
            !document.buffer.isReadOnly, !editor.hasComposition, editor.viewSelections.count == 1,
            let selection = editor.primarySelection, selection.range.isEmpty,
            selection.virtualColumn == 0
        else {
            return
        }
        cancelCompletion()
        let generation = completionGeneration
        let snapshot = document.buffer.snapshot
        let base =
            document.url?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
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
                guard generation == self.completionGeneration, self.active === document,
                    document.buffer.revision == snapshot.revision, self.mainWindow?.editor === editor,
                    editor.viewSelections == [selection]
                else {
                    return
                }
                if result.candidates.isEmpty {
                    self.mainWindow?.status.stringValue = "当前路径前缀没有候选 · 相对基准：" + base.path
                }
                editor.presentCompletions(result, signature: nil, tab: true, enter: true)
            }
            catch is CancellationError {}
            catch {
                if generation == self.completionGeneration {
                    self.mainWindow?.status.stringValue = "路径补全失败：" + error.localizedDescription
                }
            }
        }
    }
}
