import AppKit
import NateCore
import NatePlatform
import NateSyntax

extension ApplicationController {
    /// 业务作用：取消旧候选任务并释放面板，过期语言与光标不能继续发布建议。
    /// 参数说明: 无。
    /// 返回：当前候选代次失效。
    func cancelCompletion() {
        completionTask?.cancel()
        completionTask = nil
        completionGeneration = UUID()
        mainWindow?.editor.dismissCompletion()
    }

    /// 业务作用：文档单词、语言补全和参数提示基于固定快照后台计算，手动入口不受自动阈值限制。
    /// 参数说明:
    /// - mode: 全部、文档单词、语言表或参数提示。
    /// - automatic: 是否由已提交输入触发。
    /// 返回：复验身份、修订、语言与焦点后呈现候选，失败不改变正文。
    func requestCompletion(_ mode: String = "complete", automatic: Bool = false) {
        guard let document = active, let editor = mainWindow?.editor, !closing, !document.closing,
            editor.document === document.buffer, let source = editor.completionSource()
        else {
            return
        }
        let defaults = configurationDefaults()
        let enabled =
            defaults.object(forKey: "completion.enabled") == nil
            || defaults.bool(forKey: "completion.enabled")
        guard !automatic || enabled else {
            cancelCompletion()
            return
        }
        cancelCompletion()
        let generation = completionGeneration
        let snapshot = document.buffer.snapshot
        let selections = editor.viewSelections
        let languageID = document.language
        let current: @MainActor () -> Bool = { [weak self, weak document] in
            guard let self, let document, !self.closing, !document.closing, !Task.isCancelled,
                self.completionGeneration == generation, self.active === document,
                document.language == languageID, source.isCurrent()
            else {
                return false
            }
            return true
        }
        let definition = completionCatalog?.definition(for: languageID)
        let keywords = registry?.language(languageID)?.keywords ?? []
        let threshold = max(
            1,
            defaults.object(forKey: "completion.threshold") == nil
                ? 2 : min(20, defaults.integer(forKey: "completion.threshold"))
        )
        let tab = defaults.object(forKey: "completion.tab") == nil || defaults.bool(forKey: "completion.tab")
        let enter =
            defaults.object(forKey: "completion.enter") == nil || defaults.bool(forKey: "completion.enter")
        let documentWords =
            !automatic || defaults.object(forKey: "completion.words") == nil
            || defaults.bool(forKey: "completion.words")
        let languageWords =
            !automatic || defaults.object(forKey: "completion.language") == nil
            || defaults.bool(forKey: "completion.language")
        completionTask = Task {
            [weak self, weak editor] in
            guard let self, let editor else {
                return
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let context = try CompletionEngine.context(
                        in: snapshot,
                        selections: selections,
                        additional: definition?.additionalWordCharacters ?? ""
                    )
                    let showWords = mode != "signature" && (!automatic || context.prefix.count >= threshold)
                    let result = try CompletionEngine.suggest(
                        snapshot: snapshot,
                        context: context,
                        definition: definition,
                        keywords: keywords,
                        documentWords: showWords && mode != "completeLanguage" && documentWords,
                        languageWords: showWords && mode != "completeWords" && languageWords
                    )
                    let hint = try definition.flatMap {
                        try CompletionEngine.signature(
                            snapshot: snapshot,
                            caret: context.range.upper,
                            definition: $0
                        )
                    }
                    return (result, hint)
                }
                let (result, hint) = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 后台只负责候选内容，发布和最终确认均须持有此次原正文与请求的真实资格。
                guard current() else {
                    return
                }
                if !automatic && result.candidates.isEmpty && hint == nil {
                    self.mainWindow?.status.stringValue = "没有匹配的补全或函数参数规则。"
                }
                editor.presentCompletions(
                    result,
                    signature: hint,
                    tab: tab,
                    enter: enter,
                    stillCurrent: current
                )
            }
            catch is CancellationError {}
            catch {
                if !automatic && current() {
                    self.mainWindow?.status.stringValue = error.localizedDescription
                }
            }
        }
    }
}
