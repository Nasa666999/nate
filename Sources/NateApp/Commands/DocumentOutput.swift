import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax
import NateUI
import WebKit

extension ApplicationController {
    /// 业务作用：打印使用独立正文与样式快照，不触碰活动编辑器的布局和历史。
    /// 参数说明:
    /// - selectionOnly: 是否仅打印当前一个明确连续选区。
    /// - immediately: 是否使用当前系统打印机及已有纸张设置立即打印。
    /// 返回：完整样式可用时交给系统处理分页和输出；失败显示原因，不启动打印。
    func printDocument(selectionOnly: Bool = false, immediately: Bool = false) {
        guard !closing, !printing.busy else {
            return
        }
        // 打开模态面板本身也会转移输入焦点；候选期间先在原窗口反馈，不让错误弹窗间接确认候选。
        guard mainWindow?.hasMarkedEditorInput == false else {
            mainWindow?.status.stringValue = "请先确认或取消输入法候选，再发起打印。"
            return
        }
        printing.busy = true
        defer {
            printing.busy = false
        }
        do {
            let job = try prepareCurrentPrintJob(selectionOnly: selectionOnly)
            if immediately {
                job.info.jobDisposition = .spool
            }
            let operation = NSPrintOperation(
                view: job.view,
                printInfo: job.info
            )
            operation.jobTitle = job.title
            operation.showsPrintPanel = !immediately
            operation.showsProgressPanel = true
            operation.printPanel.options.formUnion([
                .showsPageRange, .showsCopies, .showsPaperSize, .showsOrientation, .showsScaling,
                .showsPreview,
            ])
            let success = operation.run()
            if let failure = job.view.failure {
                throw NateError.message(failure)
            }
            mainWindow?.status.stringValue = success ? "打印作业已交由系统完成。" : "打印已取消，正文和保存状态保持原状。"
        }
        catch {
            SystemIntegration.alert("无法生成打印内容", error.localizedDescription)
        }
    }

    /// 业务作用：为打印和富文本导出独立建立固定样式，不保存为原文件。
    /// 参数说明:
    /// - document: 要读取的文档。
    /// - snapshot: 本次输出已固定的正文；为空时读取该文档当前快照。
    /// 返回：按来源外观固定语法前景、背景和字体的只读快照；词法预算失效时拒绝部分输出。
    func styledSnapshot(_ document: WorkspaceDocument, snapshot: DocumentSnapshot? = nil) throws
        -> NSAttributedString
    {
        let font = mainWindow?.editor.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let appearance = mainWindow?.editor.effectiveAppearance ?? NSApp.effectiveAppearance
        let source = snapshot ?? document.buffer.snapshot
        return try styledPrintSnapshot(
            snapshot: source,
            range: ByteRange(0, source.text.byteCount),
            language: document.language,
            udl: outputUserLanguage(document, appearance: appearance),
            font: font,
            fontZoomAdjustment: mainWindow?.editor.fontZoomAdjustment ?? 0,
            theme: mainWindow?.editor.editorTheme,
            appearance: appearance,
            rtl: mainWindow?.editor.rtl ?? false,
            color: .document
        )
    }

    /// 业务作用：Markdown 预览只渲染本地被动 HTML，不执行脚本或加载远程资源。
    /// 参数说明: 无。
    /// 返回：独立预览窗口，不改源文本。
    func previewMarkdown() {
        guard let active else {
            return
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 650), configuration: config)
        var code = false
        let body = TextTransforms.lines(active.buffer.text.text()).map {
            line -> String in
            let value = line.body
            if value.hasPrefix("```") {
                code.toggle()
                return code ? "<pre><code>" : "</code></pre>"
            }
            if code {
                return escapeHTML(value) + "\n"
            }
            let hashes = value.prefix {
                $0 == "#"
            }.count
            if hashes > 0 && hashes <= 6 {
                return
                    "<h\(hashes)>\(escapeHTML(String(value.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))</h\(hashes)>"
            }
            if value.hasPrefix("- ") || value.hasPrefix("* ") {
                return "<p>• \(escapeHTML(String(value.dropFirst(2))))</p>"
            }
            if value.hasPrefix("> ") {
                return "<blockquote>\(escapeHTML(String(value.dropFirst(2))))</blockquote>"
            }
            return value.isEmpty ? "<br>" : "<p>\(escapeHTML(value))</p>"
        }.joined(separator: "\n")
        let html = """
            <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
            <style>body{font:16px -apple-system;padding:32px;line-height:1.6;color:#243247}pre{background:#edf2f7;padding:16px;overflow:auto}blockquote{border-left:3px solid #3689df;padding-left:16px;color:#637386}h1,h2{border-bottom:1px solid #dae2ec}</style>
            \(body)\(code ? "</code></pre>" : "")
            """
        web.loadHTMLString(html, baseURL: nil)
        showAuxiliary(title: active.name + " · Markdown 预览", view: web)
    }

    /// 业务作用：将用户内容作为 HTML 文字处理，不能注入标签或脚本。
    /// 参数说明:
    /// - text: 原文。
    /// 返回：转义的 HTML 文字。
    func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 业务作用：保存辅助窗口生命周期，使预览和列表独立于正文视图。
    /// 参数说明:
    /// - title: 窗口名称。
    /// - view: 实际功能视图。
    /// 返回：可调整大小的原生窗口。
    func showAuxiliary(title: String, view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = view
        window.center()
        let controller = NSWindowController(window: window)
        retainedWindows.append(controller)
        controller.showWindow(nil)
    }

}
