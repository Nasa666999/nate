import AppKit
import NateSyntax

extension ApplicationController {
    /// 业务作用：独立输出固定来源视图实际使用的 UDL，预装 Markdown 继续采用来源外观对应的定义。
    /// 参数说明:
    /// - document: 本次输出的完整文档实例。
    /// - appearance: 作业开始时已经固定的来源外观。
    /// 返回：当前实例有效的用户语言；未绑定视图时从同一语言注册表选取，不改变活动文档。
    func outputUserLanguage(_ document: WorkspaceDocument, appearance: NSAppearance) -> UDLDefinition? {
        if let editor = mainWindow?.editor, editor.document === document.buffer,
            editor.language?.id == document.language, let definition = editor.userLanguage
        {
            return definition
        }
        if document.language == "markdown" {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return userLanguages[
                dark ? "udl:Markdown (preinstalled dark mode)" : "udl:Markdown (preinstalled)"
            ]
        }
        return userLanguages[document.language]
    }
}
