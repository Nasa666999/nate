import AppKit
import NateCore
import NateStorage
import NateSyntax
import NateUI

@MainActor
struct PreparedPrintJob {
    let view: DocumentPrintView
    let info: NSPrintInfo
    let title: String
}

extension ApplicationController {
    /// 业务作用：固定全文或明确选区、字体、资源和时间，系统打印面板不能借用后来活动文档。
    /// 参数说明:
    /// - selectionOnly: 是否只打印一个实际普通连续选区。
    /// - date: 本次作业固定的日期时间。
    /// 返回：已经完整分页的独立作业；候选、非法范围、损坏样式或容量失败不启动打印。
    func prepareCurrentPrintJob(selectionOnly: Bool, date: Date = Date()) throws -> PreparedPrintJob {
        guard !closing, let document = active, let window = mainWindow,
            window.editor.document === document.buffer, !document.closing,
            !document.buffer.isEditingSuspended, !window.hasMarkedEditorInput
        else {
            throw NateError.message("打印需要有效正文；请先确认或取消输入法候选，并等候当前文档保护完成。")
        }
        let editor = window.editor, snapshot = document.buffer.snapshot
        let range: ByteRange
        if selectionOnly {
            guard let (actual, actualWindow, actualEditor) = quickFindContext(),
                actual === document, actualWindow === window, actualEditor === editor,
                let state = editor.viewSelectionState, state.entries.count == 1,
                case .stream = state.shape, let entry = state.entries.first,
                !entry.selection.range.isEmpty, entry.selection.virtualColumn == 0
            else {
                throw NateError.message("选区打印需要正文中的一个非空普通连续选区。")
            }
            range = entry.selection.range
        }
        else {
            range = ByteRange(0, snapshot.text.byteCount)
        }
        // 完整独立排版必须先受容量限制，不能为一次打印先复制超量正文再决定拒绝。
        guard range.count <= 64 * 1024 * 1024 else {
            throw NateError.message("单次独立打印源范围超过 64 MiB，请明确选择较小的连续范围。")
        }
        if let file = document.url {
            try FileStorage.validateFileURL(file)
        }
        let settings = try currentPrintSettings()
        let plan = try PrintSourcePlan(
            text: snapshot.text,
            range: range,
            formFeedPageBreaks: settings.formFeedPageBreaks
        )
        let styled = try styledPrintSnapshot(
            snapshot: snapshot,
            range: range,
            language: document.language,
            font: editor.font,
            appearance: editor.effectiveAppearance,
            rtl: editor.rtl,
            color: settings.color
        )
        let source = try PrintedSource(
            plan: plan,
            styled: styled,
            settings: settings,
            values: printTemplateValues(document, date: date),
            showControls: editor.showSymbols,
            baseFont: editor.font,
            background: SyntaxPresentation.resolved(
                .textBackgroundColor,
                appearance: editor.effectiveAppearance
            )
        )
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            throw NateError.message("系统没有提供独立打印状态，原纸张设置保持原状。")
        }
        info.topMargin = settings.marginTop * 72 / 25.4
        info.bottomMargin = settings.marginBottom * 72 / 25.4
        info.leftMargin = settings.marginLeft * 72 / 25.4
        info.rightMargin = settings.marginRight * 72 / 25.4
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        let view = DocumentPrintView(source: source)
        try view.prepare(printInfo: info)
        return PreparedPrintJob(
            view: view,
            info: info,
            title: document.name
        )
    }

    /// 业务作用：页眉页脚只展开作业开始时的固定文件与日期时间信息，之后的重命名和时钟变化不串入旧作业。
    /// 参数说明:
    /// - document: 本次真实来源文档。
    /// - date: 本次固定时间。
    /// 返回：全部元数据变量；未保存文档以显示名称作为文件名和路径，目录为空。
    func printTemplateValues(_ document: WorkspaceDocument, date: Date) -> [String: String] {
        let short = DateFormatter()
        short.dateStyle = .short
        short.timeStyle = .none
        let long = DateFormatter()
        long.dateStyle = .long
        long.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .medium
        return [
            "FULL_CURRENT_PATH": document.url?.path ?? document.name,
            "FILE_NAME": document.url?.lastPathComponent ?? document.name,
            "CURRENT_DIRECTORY": document.url?.deletingLastPathComponent().path ?? "",
            "SHORT_DATE": short.string(from: date),
            "LONG_DATE": long.string(from: date),
            "TIME": time.string(from: date),
        ]
    }
}
