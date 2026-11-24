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
                    let start = snapshot.text.lineStart(snapshot.text.lineNumber(at: caret))
                    // 路径引号可能在此前任何位置开启，截断行首会使另一段文本取得目录读取资格。
                    guard caret - start <= CompletionInputCommand.maximumPrefixBytes else {
                        throw NateError.message("路径补全的当前行前缀超过 64 KiB。")
                    }
                    let preceding = snapshot.text.text(in: ByteRange(start, caret))
                    var quote: Character?
                    var segment = ""
                    for (index, character) in preceding.enumerated() {
                        if index % 4096 == 0 {
                            try token.check()
                        }
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
                    guard !typed.utf8.contains(0) else {
                        throw NateError.message("路径前缀含有 NUL，无法解析本地目录。")
                    }
                    let bytes = typed.utf8
                    let separator = bytes.lastIndex(of: 47).map { bytes.index(after: $0) } ?? bytes.startIndex
                    // 展开及规范化仅用于访问目录，确认候选仍采用用户正文中的父路径原字节。
                    let writtenParent = String(decoding: bytes[..<separator], as: UTF8.self)
                    let namePrefix = String(decoding: bytes[separator...], as: UTF8.self)
                    let expanded = (writtenParent as NSString).expandingTildeInPath
                    let directory =
                        expanded.hasPrefix("/")
                        ? URL(fileURLWithPath: expanded, isDirectory: true)
                        : base.appendingPathComponent(expanded, isDirectory: true)
                    let result = try PathCompletionDirectory.read(
                        directory: directory,
                        namePrefix: namePrefix,
                        writtenParent: writtenParent,
                        entryLimit: PathCompletionDirectory.maximumEntries,
                        check: token.check
                    )
                    return CompletionResult(
                        documentID: snapshot.id,
                        revision: snapshot.revision,
                        context: CompletionContext(
                            range: ByteRange(caret - typed.utf8.count, caret),
                            prefix: typed
                        ),
                        candidates: result.candidates,
                        limited: result.limited
                    )
                }
                guard current() else {
                    return
                }
                if result.candidates.isEmpty {
                    self.mainWindow?.status.stringValue =
                        result.limited
                        ? "路径补全达到目录扫描上限，已扫描范围没有匹配。"
                        : "当前路径前缀没有候选 · 相对基准：" + base.path
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
