import AppKit
import NatePlatform
import NateUI
import UniformTypeIdentifiers

enum FunctionListAssociationCommand: String, CaseIterable {
    case importing = "importFunctionListAssociations"
    case edit = "editFunctionListAssociations"
    case export = "exportFunctionListAssociations"
    case reload = "reloadFunctionListAssociations"
    case restore = "restoreFunctionListAssociations"

    /// 业务作用：菜单标题对应全局关联的实际操作范围。
    /// 参数说明: 无。
    /// 返回：本次操作的原生菜单名称。
    var title: String {
        switch self {
        case .importing: return "导入 overrideMap.xml…"
        case .edit: return "编辑关联 XML…"
        case .export: return "导出当前 overrideMap.xml…"
        case .reload: return "重新载入用户关联"
        case .restore: return "恢复随包关联…"
        }
    }
}

extension ApplicationController {
    /// 业务作用：全局关联独立于当前语言，输入法未确认或当前关联正发布时不抢占编辑状态。
    /// 参数说明:
    /// - command: 当前原生菜单所请求的具体操作。
    /// 返回：已有必要来源和操作资格时为真。
    func canManageFunctionListAssociations(_ command: FunctionListAssociationCommand) -> Bool {
        guard applicationSupport != nil, functionListAssociations.ready, !functionListAssociations.busy,
            !closing, mainWindow?.hasMarkedEditorInput != true
        else {
            return false
        }
        let entry = functionListAssociations.entry
        switch command {
        case .export:
            return entry.value != nil || functionListCatalog?.associations != nil
        case .restore:
            return entry.value != nil || entry.diagnostic != nil
        case .importing, .edit, .reload:
            return true
        }
    }

    /// 业务作用：应用级关联经原生文件和编辑窗口完成，已有规则仅在整组校验及保存成功时更新。
    /// 参数说明:
    /// - command: 已通过命令路由的全局关联操作。
    /// 返回：显示原生表单、提示或启动原代次固定的后台操作，取消保持实际映射。
    func manageFunctionListAssociations(_ command: FunctionListAssociationCommand) {
        guard canManageFunctionListAssociations(command) else {
            return
        }
        let entry = functionListAssociations.entry
        let xml = entry.value?.archive.map ?? functionListCatalog?.associations?.originalXML
        switch command {
        case .importing:
            let panel = NSOpenPanel()
            panel.title = "导入函数列表关联"
            panel.message = "选择 overrideMap.xml。引用的规则文件应位于同一目录，也可使用同名随包规则。"
            panel.allowedContentTypes = [.xml]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            performFunctionListAssociationChange(.importing(url, expecting: entry.generation))
        case .edit:
            editFunctionListAssociations(xml: xml, entry: entry)
        case .export:
            guard let xml else {
                return
            }
            exportRuleXML(xml, name: "overrideMap.xml", errorTitle: "函数列表关联 XML 未导出")
        case .reload:
            performFunctionListAssociationChange(.reload)
        case .restore:
            let prompt = NSAlert()
            prompt.messageText = "恢复随包函数列表关联？"
            prompt.informativeText = "这会清除用户关联及其同层规则。每种语言单独保存的规则继续优先。"
            prompt.addButton(withTitle: "恢复")
            prompt.addButton(withTitle: "取消")
            guard prompt.runModal() == .alertFirstButtonReturn else {
                return
            }
            performFunctionListAssociationChange(.restore(expecting: entry.generation))
        }
    }

    /// 业务作用：原生编辑窗固定上次确认的映射代次，并按实际输入更新说明。
    /// 参数说明:
    /// - xml: 当前匹配到的有效原始关联 XML。
    /// - entry: 打开表单时绑定的持久化状态和代次。
    /// 返回：独立资源窗口；同一次成功保存后继续编辑会取得本窗口新的代次。
    private func editFunctionListAssociations(xml: Data?, entry: FunctionListAssociationRuntime.Entry) {
        let template = """
            <?xml version="1.0" encoding="UTF-8"?>
            <NotepadPlus><functionList><associationMap/></functionList></NotepadPlus>
            """
        let source = xml.flatMap { String(data: $0, encoding: .utf8) } ?? template
        let editor = ResourceEditor(title: "函数列表关联 · overrideMap.xml", source: source)
        if let diagnostic = entry.diagnostic {
            editor.setDiagnostics([diagnostic])
        }
        var generation = entry.generation
        editor.onSave = { [weak self, weak editor] source in
            Task {
                guard let self else {
                    return
                }
                do {
                    try await self.changeFunctionListAssociations(
                        .edit(Data(source.utf8), expecting: generation)
                    )
                    generation = self.functionListAssociations.entry.generation
                    editor?.applyValidation(for: source, diagnostics: [], status: "函数列表关联已保存并生效。")
                }
                catch {
                    editor?.applyValidation(
                        for: source,
                        diagnostics: [error.localizedDescription],
                        status: "函数列表关联未应用。"
                    )
                }
            }
        }
        retainedWindows.append(editor)
        editor.showWindow(nil)
    }

    /// 业务作用：文件菜单和确认对话框报告实际应用状态，原有效映射在失败时继续提供导航。
    /// 参数说明:
    /// - change: 用户确认且已固定来源的关联动作。
    /// 返回：启动后台操作及原生反馈，不同步阻塞编辑窗口。
    private func performFunctionListAssociationChange(_ change: FunctionListAssociationRuntime.Change) {
        Task {
            do {
                try await changeFunctionListAssociations(change)
                mainWindow?.status.stringValue = "已应用函数列表关联。"
            }
            catch is CancellationError {}
            catch {
                SystemIntegration.alert("函数列表关联未应用", error.localizedDescription)
            }
        }
    }
}
