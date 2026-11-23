import AppKit
import NateCore
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：显式链接双击在外部动作前复验活动正文、焦点和完整来源，后台页不能自行打开目标。
    /// 参数说明:
    /// - editor: 实际收到用户双击的正文视图。
    /// - link: 已完整解析的原文范围与系统目标。
    /// - page: 该目标所属不可变正文和链接配置。
    /// 返回：来源保持且本地文件策略通过后交给系统打开；拒绝与系统失败只反馈状态，不修改正文。
    func openTextLink(_ link: DocumentTextLink, page: DocumentTextLinkPage, from editor: EditorView) {
        // 外部打开不可撤销，窗口、输入目标、文档对象和原文根必须在实际动作前同时成立。
        guard !closing, let active, !active.closing, let window = mainWindow,
            window.editor === editor, editor.document === active.buffer,
            documents.contains(where: {
                $0 === active
            }),
            window.window?.isKeyWindow == true, window.window?.firstResponder === editor,
            !active.buffer.isEditingSuspended, !editor.hasComposition,
            page.matches(active.buffer.snapshot, settings: editor.textLinkSettings),
            page.link(containing: link.range.lower) == link
        else {
            mainWindow?.status.stringValue = "链接来源或活动输入目标已改变，未打开旧目标。"
            return
        }
        do {
            if link.target.isFileURL {
                // 文件协议不能把远程主机、凭据或解码 NUL 交给系统形成另一种文件访问。
                try FileStorage.validateFileURL(link.target)
            }
            guard webSearch.openURL(link.target) else {
                window.status.stringValue = "系统没有能够打开此链接的应用，正文保持。"
                return
            }
        }
        catch {
            window.status.stringValue = error.localizedDescription
        }
    }
}
