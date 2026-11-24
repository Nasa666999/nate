import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateSyntax
import NateUI
import UniformTypeIdentifiers

enum CompletionOverrideCommand: String, CaseIterable {
    case insert = "importCompletionXML"
    case edit = "editCompletionXML"
    case export = "exportCompletionXML"
    case reload = "reloadCompletionXML"
    case restore = "restoreBundledCompletionXML"

    /// 业务作用：补全资源入口说明用户即将执行的实际操作，当前语言由菜单范围决定。
    /// 参数说明: 无。
    /// 返回：对应 AppKit 菜单的标题。
    var title: String {
        switch self {
        case .insert: return "导入补全 XML…"
        case .edit: return "编辑补全 XML…"
        case .export: return "导出当前补全 XML…"
        case .reload: return "重新载入用户补全"
        case .restore: return "恢复随包补全…"
        }
    }
}

extension ApplicationController {
    /// 业务作用：菜单只向有实际持久化资格的语言开放，资源管理不能占用未提交的输入法状态。
    /// 参数说明:
    /// - action: 当前补全资源管理动作。
    /// 返回：该动作可对当前实际语言执行时为真。
    func canManageCompletionOverride(_ action: CompletionOverrideCommand) -> Bool {
        guard !closing, !completionOverrides.busy, completionOverrides.ready, applicationSupport != nil,
            mainWindow?.hasMarkedEditorInput != true,
            let id = active?.language, id != "searchResult", registry?.language(id) != nil
        else {
            return false
        }
        if action == .export {
            return completionOverrides.entries[id]?.xml != nil
                || completionCatalog?.originalXML(for: id) != nil
        }
        if action == .restore {
            let entry = completionOverrides.entries[id]
            return entry?.xml != nil || entry?.diagnostic != nil
        }
        return true
    }

    /// 业务作用：将用户当前选择明确绑定到同一语言，打开对话框期间切换标签不会重定向资源修改。
    /// 参数说明:
    /// - action: 已从菜单分发的真实资源操作。
    /// 返回：只对所选语言打开表单、验证持久化或导出，失败保留完整原定义。
    func manageCompletionOverride(_ action: CompletionOverrideCommand) {
        guard canManageCompletionOverride(action), let id = active?.language,
            let language = registry?.language(id)
        else {
            return
        }
        let entry = completionOverrides.entries[id]
        switch action {
        case .edit:
            editCompletionXML(language, entry: entry)
        case .insert:
            importCompletionXML(language, generation: entry?.generation)
        case .export:
            let original = entry?.xml ?? completionCatalog?.originalXML(for: id)
            if let original {
                exportCompletionXML(original)
            }
        case .reload:
            Task {
                do {
                    try await reloadCompletionOverride(language: id)
                    mainWindow?.status.stringValue = "已重新载入 \(language.name) 补全。"
                }
                catch {
                    SystemIntegration.alert("无法重新载入补全", error.localizedDescription)
                }
            }
        case .restore:
            let prompt = NSAlert()
            prompt.messageText = "恢复 \(language.name) 的随包补全？"
            prompt.informativeText = "这会替换现有的用户补全定义。已打开文档中的文字不会改变。"
            prompt.addButton(withTitle: "恢复")
            prompt.addButton(withTitle: "取消")
            guard prompt.runModal() == .alertFirstButtonReturn else {
                return
            }
            Task {
                do {
                    try await saveCompletionOverride(nil, language: id, generation: entry?.generation)
                    mainWindow?.status.stringValue = "已恢复 \(language.name) 的随包补全。"
                }
                catch {
                    SystemIntegration.alert("无法恢复随包补全", error.localizedDescription)
                }
            }
        }
    }

    /// 业务作用：用同一校验入口编辑原始定义，表单持续持有最后一次成功应用的代次。
    /// 参数说明:
    /// - language: 此表单固定对应的真实语言。
    /// - entry: 打开时确认的用户补全及原来源。
    /// 返回：打开 XML 编辑窗，验证失败或关闭草稿时继续使用原规则。
    private func editCompletionXML(_ language: LanguageDefinition, entry: CompletionOverridesRuntime.Entry?) {
        let original = entry?.xml ?? completionCatalog?.originalXML(for: language.id)
        let template = """
            <?xml version="1.0" encoding="UTF-8"?>
            <NotepadPlus>
                <AutoComplete>
                    <Environment ignoreCase="no"/>
                </AutoComplete>
            </NotepadPlus>
            """
        let source = original.flatMap { String(data: $0, encoding: .utf8) } ?? template
        let editor = ResourceEditor(title: "补全 XML · " + language.name, source: source)
        var generation = entry?.generation
        if let diagnostic = entry?.diagnostic {
            editor.setDiagnostics([diagnostic])
        }
        editor.onSave = { [weak self, weak editor] source in
            Task {
                guard let self else {
                    return
                }
                do {
                    try await self.saveCompletionOverride(
                        Data(source.utf8),
                        language: language.id,
                        generation: generation
                    )
                    generation = self.completionOverrides.entries[language.id]?.generation
                    editor?.applyValidation(for: source, diagnostics: [], status: "补全已保存并生效。")
                }
                catch {
                    editor?.applyValidation(
                        for: source,
                        diagnostics: [error.localizedDescription],
                        status: "补全未应用。"
                    )
                }
            }
        }
        retainedWindows.append(editor)
        editor.showWindow(nil)
    }

    /// 业务作用：用户从文件导入时读取确切原字节，文件名不会影响它所属的语言或写入目标。
    /// 参数说明:
    /// - language: 对话框展示且固定的当前语言。
    /// - generation: 打开对话框时确认的用户规则代次。
    /// 返回：读取和完整校验成功后启用该份规则，取消或失败保留原定义。
    private func importCompletionXML(_ language: LanguageDefinition, generation: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "为 \(language.name) 导入补全 XML"
        panel.message = "导入会更新当前语言的补全和函数参数提示。"
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            do {
                let xml = try await readIO.readCancellable { token in
                    try self.fileAccess.readData(
                        url,
                        maximumBytes: CompletionOverrideStore.maximumXMLBytes,
                        permit: { !token.isCancelled }
                    ).data
                }
                try await saveCompletionOverride(xml, language: language.id, generation: generation)
                mainWindow?.status.stringValue = "已导入 \(language.name) 的补全 XML。"
            }
            catch {
                SystemIntegration.alert("补全 XML 未导入", error.localizedDescription)
            }
        }
    }

    /// 业务作用：导出当前有效的规则原字节，文件存在时须复验所选磁盘证据。
    /// 参数说明:
    /// - xml: 随包或用户资源的完整原 XML。
    /// 返回：原字节安全保存到用户明确选择的位置，取消或失败不改变任何有效规则。
    private func exportCompletionXML(_ xml: Data) {
        guard let url = SystemIntegration.chooseSave(name: "completion.xml") else {
            return
        }
        Task {
            do {
                try await fileIO.run {
                    let expected =
                        FileManager.default.fileExists(atPath: url.path)
                        ? try self.fileAccess.baseline(url) : nil
                    _ = try self.fileOperations.save(
                        using: self.fileAccess,
                        xml,
                        to: url,
                        expected: expected,
                        replacing: true
                    )
                }
            }
            catch {
                SystemIntegration.alert("补全 XML 未导出", error.localizedDescription)
            }
        }
    }
}
