import AppKit
import NateCore
import NateSyntax

extension EditorView {
    /// 业务作用：比例字体及资源字号会改变视觉边缘，原生几何只能读取当前完整语法结果。
    /// 参数说明:
    /// - row: 本次视觉计算涉及的真实逻辑行。
    /// 返回：没有语法资源或当前行样式完整时继续；等待与失败均保留原选择和正文。
    func requireGeometrySyntax(row: Int) throws {
        guard geometrySyntaxRequired else {
            return
        }
        _ = syntaxTokens(for: row)
        // 中性等待样式不能取得视觉写入权，否则异步字号到达后会把同一像素解释为另一段正文。
        guard hasGeometrySyntax(row: row) else {
            throw NateError.message(syntaxFailure ?? "正在准备当前行的完整语法，请在呈现完成后继续列操作。")
        }
    }

    /// 业务作用：块粘贴的临时视图在后台准备有界样式页，不能按未着色的基础字体计算其它行的插入位置。
    /// 参数说明:
    /// - row: 当前准备涉及的真实逻辑行。
    /// - lastRow: 本次操作实际需要的最末行，为空时只准备当前行，不扫描无关后继。
    /// - deadline: 解码、几何与事务构建共同持有的截止。
    /// 返回：当前行样式完整后继续；取消、来源变化或容量不足时拒绝本次整份动作。
    func prepareGeometrySyntax(
        row: Int,
        lastRow: Int? = nil,
        deadline: ContinuousClock.Instant
    ) async throws {
        guard geometrySyntaxRequired else {
            return
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline, (0..<document.text.lineCount).contains(row),
            let language
        else {
            throw NateError.message("原生几何缺少有效语言、行范围或共同执行时间。")
        }
        if hasGeometrySyntax(row: row) {
            return
        }
        let snapshot = document.snapshot
        let resource = language.id + ":" + (userLanguage?.name ?? "")
        let matching =
            syntaxDocument == snapshot.id && syntaxRevision == snapshot.revision
            && syntaxLanguage == resource
        let start =
            matching
            ? syntaxCheckpoints.keys.filter {
                $0 <= row
            }.max() ?? 0 : 0
        let state = matching ? syntaxCheckpoints[start] : nil
        let udl = userLanguage
        // 几何动作接管本轮样式准备，先收回旧视口任务的结果资格，再沿同一正文与资源计算。
        syntaxTask?.cancel()
        syntaxGeneration = UUID()
        let generation = syntaxGeneration
        if !matching {
            syntaxCache = [:]
            syntaxCheckpoints = [:]
        }
        syntaxDocument = snapshot.id
        syntaxRevision = snapshot.revision
        syntaxLanguage = resource
        let end = min(snapshot.text.lineCount - 1, max(row, lastRow ?? row))
        let visible = row..<(row + min(256, end - row + 1))
        let worker = Task.detached(priority: .userInitiated) {
            try SyntaxAnalysis.analyze(
                snapshot: snapshot,
                language: language,
                udl: udl,
                visible: visible,
                startLine: start,
                initial: state,
                deadline: deadline
            )
        }
        let result = try await withTaskCancellationHandler(
            operation: {
                try await worker.value
            },
            onCancel: {
                worker.cancel()
            }
        )
        try Task.checkCancellation()
        // 等待期间正文、语言或用户意图已改变时，旧样式不能重新取得当前像素的解释权。
        guard ContinuousClock.now < deadline, syntaxGeneration == generation,
            document.id == snapshot.id, document.revision == snapshot.revision,
            document.text.sourceIdentity == snapshot.text.sourceIdentity
        else {
            throw CancellationError()
        }
        installSyntaxAnalysis(result, near: row)
    }

    /// 业务作用：普通视口与显式几何动作共用有界样式发布，缓存不能随逐页块粘贴无界累积。
    /// 参数说明:
    /// - result: 已经复验同一正文与资源权限的完整分析。
    /// - row: 当前实际需要保留的附近逻辑行。
    /// 返回：替换有界呈现页、合并有限检查点并撤销旧字形缓存；不改变正文和选择。
    func installSyntaxAnalysis(_ result: SyntaxAnalysis, near row: Int) {
        syntaxCache = result.tokens
        syntaxCheckpoints.merge(result.checkpoints) {
            _,
            latest in
            latest
        }
        if syntaxCheckpoints.count > 4096 {
            var keep = Set(
                syntaxCheckpoints.keys.sorted {
                    abs($0 - row) < abs($1 - row)
                }.prefix(4095)
            )
            if let earliest = syntaxCheckpoints.keys.min() {
                keep.insert(earliest)
            }
            syntaxCheckpoints = syntaxCheckpoints.filter {
                keep.contains($0.key)
            }
        }
        syntaxFailure = nil
        syntaxFailedLines = nil
        layouts.removeAll()
        needsDisplay = true
    }

    /// 业务作用：已知只有颜色的内置资源直接使用基础字形，用户语言、字体与隐藏序列须取得完整样式。
    /// 参数说明: 无。
    /// 返回：当前资源可能改变字体或字形属性时为真。
    private var geometrySyntaxRequired: Bool {
        userLanguage != nil || language?.requiresLexicalGeometry == true
    }

    /// 业务作用：样式页必须属于当前完整正文和语言，缓存中存在同一行号并不足以证明几何身份。
    /// 参数说明:
    /// - row: 当前真实逻辑行。
    /// 返回：原文档、修订、资源和完整样式页均一致时为真。
    private func hasGeometrySyntax(row: Int) -> Bool {
        guard let language else {
            return false
        }
        return syntaxDocument == document.id && syntaxRevision == document.revision
            && syntaxLanguage == language.id + ":" + (userLanguage?.name ?? "") && syntaxCache[row] != nil
    }
}
