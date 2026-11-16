import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：高亮基于固定快照在后台传播，身份或资源变化后拒绝迟到结果。
    /// 参数说明:
    /// - line: 当前请求呈现的逻辑行。
    /// 返回：已验证的缓存；缺少结果时暂用中性样式并安排后台计算。
    func syntaxTokens(for line: Int) -> [SyntaxToken] {
        guard composition == nil, let language else {
            return []
        }
        let resource = language.id + ":" + (userLanguage?.name ?? "")
        if syntaxDocument != document.id || syntaxLanguage != resource || syntaxRevision != document.revision
        {
            syntaxTask?.cancel()
            syntaxTask = nil
            syntaxGeneration = UUID()
            if syntaxDocument == document.id, syntaxLanguage == resource,
                syntaxRevision + 1 == document.revision,
                let changed = document.lastEdits.map(\.range.lower).min()
            {
                let line = document.text.lineNumber(at: min(changed, document.text.byteCount))
                syntaxCheckpoints = syntaxCheckpoints.filter {
                    $0.key < line
                }
                syntaxCache = syntaxCache.filter {
                    $0.key < line
                }
            }
            else {
                syntaxCheckpoints = [:]
                syntaxCache = [:]
            }
            syntaxDocument = document.id
            syntaxLanguage = resource
            syntaxRevision = document.revision
        }
        if let tokens = syntaxCache[line] {
            return tokens
        }
        guard syntaxTask == nil else {
            return []
        }
        let first = min(line, projection.line(at: max(0, visibleRect.minY - 8)))
        let visible = first..<min(document.text.lineCount, max(line + 1, first + 256))
        let start =
            syntaxCheckpoints.keys.filter {
                $0 <= first
            }.max() ?? 0
        let state = syntaxCheckpoints[start]
        let snapshot = document.snapshot
        let udl = userLanguage
        let generation = syntaxGeneration
        syntaxTask = Task {
            [weak self] in
            let worker = Task.detached(priority: .utility) {
                try SyntaxAnalysis.analyze(
                    snapshot: snapshot,
                    language: language,
                    udl: udl,
                    visible: visible,
                    startLine: start,
                    initial: state
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
                guard let self, self.syntaxGeneration == generation, self.document.id == snapshot.id,
                    self.document.revision == snapshot.revision
                else {
                    return
                }
                self.syntaxCache = result.tokens
                self.syntaxCheckpoints.merge(result.checkpoints) {
                    _,
                    latest in latest
                }
                self.layouts.removeAll()
                self.syntaxTask = nil
                self.needsDisplay = true
            }
            catch {
                guard let self, self.syntaxGeneration == generation else {
                    return
                }
                self.syntaxTask = nil
                self.syntaxCache[line] = []
                if !(error is CancellationError) {
                    self.onStatus?(error.localizedDescription)
                }
            }
        }
        return []
    }

    /// 业务作用：规则热更新与主题切换使旧高亮失效，正文仍保留原修订。
    /// 参数说明: 无。
    /// 返回：取消旧任务并清空呈现缓存。
    public func invalidateSyntax() {
        syntaxTask?.cancel()
        syntaxTask = nil
        syntaxGeneration = UUID()
        syntaxLanguage = ""
        syntaxCache = [:]
        syntaxCheckpoints = [:]
        refresh()
    }
}
