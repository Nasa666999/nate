import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：在当前视口保留语法计算的等待或容量边界，不让周期保存刷新掩盖失败原因。
    /// 参数说明: 无。
    /// 返回：仅当前文档修订和视口适用的语法状态，其它情况为空。
    public var syntaxAnalysisStatus: String? {
        guard syntaxDocument == document.id, syntaxRevision == document.revision, composition == nil else {
            return nil
        }
        let first = projection.line(at: max(0, visibleRect.minY - 8))
        let last = projection.line(at: visibleRect.maxY)
        if let lines = syntaxFailedLines, lines.lowerBound <= last, lines.upperBound > first {
            return syntaxFailure
        }
        return syntaxTask != nil && syntaxCache[first] == nil ? "正在解析语法" : nil
    }

    /// 业务作用：以语言定义的精确编码字节识别资源变化，同标识的新规则不能复用旧高亮或括号结果。
    /// 参数说明: 无。
    /// 返回：资源实际变化时撤销旧分析；重复装配同一定义不重启后台任务。
    func updateLanguageResource() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded: Data?
        if let language {
            guard let bytes = try? encoder.encode(language) else {
                languageResource = nil
                invalidateSyntax()
                return
            }
            encoded = bytes
        }
        else {
            encoded = nil
        }
        if encoded != languageResource {
            languageResource = encoded
            invalidateSyntax()
        }
    }

    /// 业务作用：高亮基于固定快照在后台传播，身份或资源变化后拒绝迟到结果。
    /// 参数说明:
    /// - line: 当前请求呈现的逻辑行。
    /// 返回：已验证的缓存；缺少结果时暂用中性样式并安排后台计算。
    func syntaxTokens(for line: Int) -> [SyntaxToken] {
        guard composition == nil || confirmingComposition, let language else {
            return []
        }
        let resource = language.id + ":" + (userLanguage?.name ?? "")
        if syntaxDocument != document.id || syntaxLanguage != resource || syntaxRevision != document.revision
        {
            syntaxTask?.cancel()
            syntaxGeneration = UUID()
            syntaxFailure = nil
            syntaxFailedLines = nil
            // 续行、UDL 短语及原生词法前瞻依赖后续原文，正文变化后须重新确认完整前缀与修订。
            if !language.usesSharedCLexer,
                ![
                    "python", "registry", "latex", "rust", "yaml", "powershell", "objc", "r", "lua", "mssql",
                    "sql", "css", "batch",
                ]
                .contains(
                    language.id
                ),
                userLanguage?.requiresSourceLookahead != true,
                syntaxDocument == document.id,
                syntaxLanguage == resource,
                syntaxRevision < UInt64.max,
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
        // 同一视口已经缺少完整词法证据时，重绘不能不断重新执行相同的超预算任务。
        if syntaxFailedLines?.contains(line) == true {
            return []
        }
        guard syntaxTask == nil else {
            return []
        }
        let viewportFirst = projection.line(at: max(0, visibleRect.minY - 8))
        let first = line >= viewportFirst && line - viewportFirst < 256 ? viewportFirst : line
        let visible = first..<(first + min(256, document.text.lineCount - first))
        let start =
            syntaxCheckpoints.keys.filter {
                $0 <= first
            }.max() ?? 0
        let state = syntaxCheckpoints[start]
        let snapshot = document.snapshot
        let udl = userLanguage
        let generation = syntaxGeneration
        let identity = UUID()
        syntaxFailure = nil
        syntaxFailedLines = nil
        syntaxTaskID = identity
        syntaxTask = Task {
            [weak self] in
            defer {
                if let self, self.syntaxTaskID == identity {
                    // 取消只撤销结果资格，实际解析返回后才能允许下一个任务取得唯一任务位。
                    self.syntaxTask = nil
                    self.syntaxTaskID = nil
                    self.layouts.removeAll()
                    self.needsDisplay = true
                }
            }
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
                try Task.checkCancellation()
                // 正文相同仍可能属于新的文档绑定或规则代次，旧结果不能重新取得呈现资格。
                guard let self, self.syntaxGeneration == generation, self.document.id == snapshot.id,
                    self.document.revision == snapshot.revision
                else {
                    return
                }
                self.installSyntaxAnalysis(result, near: first)
            }
            catch {
                guard let self, self.syntaxGeneration == generation else {
                    return
                }
                if !Task.isCancelled && !(error is CancellationError) {
                    self.syntaxFailure = error.localizedDescription
                    self.syntaxFailedLines = visible
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
        invalidateBracketAnalysis()
        syntaxTask?.cancel()
        syntaxGeneration = UUID()
        syntaxLanguage = ""
        syntaxCache = [:]
        syntaxCheckpoints = [:]
        syntaxFailure = nil
        syntaxFailedLines = nil
        refresh()
    }
}
