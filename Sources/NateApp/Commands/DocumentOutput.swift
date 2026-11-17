import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax
import WebKit

extension ApplicationController {
    /// 业务作用：打印使用独立正文与样式快照，不触碰活动编辑器的布局和历史。
    /// 参数说明: 无。
    /// 返回：由系统打印面板处理分页、页码、份数、方向和 PDF 输出。
    func printDocument() {
        mainWindow?.editor.finishComposition()
        guard let active else {
            return
        }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        let width = max(100, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isRichText = true
        view.textStorage?.setAttributedString(styledSnapshot(active))
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer ?? NSTextContainer())
        if let container = view.textContainer, let layout = view.layoutManager {
            view.setFrameSize(
                NSSize(width: width, height: max(100, layout.usedRect(for: container).height + 30))
            )
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    /// 业务作用：为打印和富文本导出独立建立固定样式，不保存为原文件。
    /// 参数说明:
    /// - document: 要读取的文档。
    /// 返回：只读的带颜色快照。
    func styledSnapshot(_ document: WorkspaceDocument) -> NSAttributedString {
        let tree = document.buffer.text
        let value = NSMutableAttributedString(
            string: tree.text(),
            attributes: [
                .font: mainWindow?.editor.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
        )
        if let language = registry?.language(document.language) {
            var state = SyntaxState()
            for line in 0..<tree.lineCount {
                let range = tree.lineRange(line)
                for token in SyntaxEngine.highlight(
                    tree.text(in: range),
                    base: range.lower,
                    language: language,
                    state: &state
                ) {
                    guard let ns = tree.nsRange(token.range) else {
                        continue
                    }
                    let color: NSColor
                    switch token.kind {
                    case .keyword: color = .systemPurple
                    case .comment: color = .secondaryLabelColor
                    case .string: color = .systemGreen
                    case .number: color = .systemBlue
                    default: color = .systemTeal
                    }
                    value.addAttribute(.foregroundColor, value: color, range: ns)
                }
            }
        }
        return value
    }

    /// 业务作用：HTML/RTF 导出保留语法色，成功不改变原文件关联或保存点。
    /// 参数说明:
    /// - html: 是否导出 HTML，否则 RTF。
    /// 返回：安全写入所选导出目标。
    func exportDocument(html: Bool) {
        guard let active,
            let url = SystemIntegration.chooseSave(name: active.name + (html ? ".html" : ".rtf"))
        else {
            return
        }
        do {
            let styled = styledSnapshot(active)
            let data = try styled.data(
                from: NSRange(location: 0, length: styled.length),
                documentAttributes: [
                    .documentType: html ? NSAttributedString.DocumentType.html : .rtf,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ]
            )
            Task {
                do {
                    try await fileIO.run {
                        let expected =
                            FileManager.default.fileExists(atPath: url.path)
                            ? try self.fileAccess.baseline(url) : nil
                        _ = try self.fileOperations.save(
                            using: self.fileAccess,
                            data,
                            to: url,
                            expected: expected,
                            replacing: true
                        )
                    }
                }
                catch {
                    SystemIntegration.alert("导出失败", error.localizedDescription)
                }
            }
        }
        catch {
            SystemIntegration.alert("导出失败", error.localizedDescription)
        }
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

    /// 业务作用：比较当前文档与明确选择文件，差异输出不覆盖任一正文。
    /// 参数说明: 无。
    /// 返回：逐行增删清单；超出计算预算时保留原文并说明。
    func compareDocuments() {
        guard let active, let url = SystemIntegration.chooseFiles().first else {
            return
        }
        let snapshot = active.buffer.snapshot
        Task {
            do {
                let result = try await readIO.readCancellable {
                    token in
                    let external = try self.fileAccess.load(
                        url,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let before = TextTransforms.lines(snapshot.text.text()).map(\.body)
                    let after = TextTransforms.lines(external.text).map(\.body)
                    guard before.count + after.count <= 100_000 else {
                        throw NateError.message("逐行差异超过 100000 行预算，请先选择较小范围。")
                    }
                    let difference = after.difference(from: before)
                    return difference.map {
                        change in
                        switch change {
                        case .insert(let offset, let element, _): return "+ \(offset + 1)  \(element)"
                        case .remove(let offset, let element, _): return "− \(offset + 1)  \(element)"
                        }
                    }.joined(separator: "\n")
                }
                mainWindow?.showResults(result.isEmpty ? "两个文本逐行相同。" : result)
            }
            catch {
                SystemIntegration.alert("比较失败", error.localizedDescription)
            }
        }
    }

}
