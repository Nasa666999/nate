import AppKit
import NatePlatform
import NateStorage
import NateSyntax
import NateUI
import UniformTypeIdentifiers

struct LanguageXMLOverrideCommand {
    enum Action: String, CaseIterable {
        case insert = "import"
        case edit
        case export
        case reload
        case restore = "restoreBundled"
    }

    let kind: LanguageXMLOverrideStore.Kind
    let action: Action

    /// 业务作用：稳定命令标识沿用已发布的补全入口，并使函数列表操作属于独立资源。
    /// 参数说明: 无。
    /// 返回：可用于菜单、配置或快捷键映射的实际命令标识。
    var id: String {
        action.rawValue + (kind == .completion ? "CompletionXML" : "FunctionListXML")
    }

    /// 业务作用：原生菜单为同一组持久化操作按实际资源提供名称。
    /// 参数说明: 无。
    /// 返回：清晰对应用户将要执行的动作。
    var title: String {
        let resource = kind == .completion ? "补全" : "函数列表"
        switch action {
        case .insert: return "导入\(resource) XML…"
        case .edit: return "编辑\(resource) XML…"
        case .export: return "导出当前\(resource) XML…"
        case .reload: return "重新载入用户\(resource)"
        case .restore: return kind == .completion ? "恢复随包补全…" : "恢复当前关联的函数列表…"
        }
    }

    /// 业务作用：命令路由只接受实际菜单声明的语言资源操作。
    /// 参数说明:
    /// - id: 统一命令入口收到的稳定标识。
    /// 返回：有实际入口的资源动作，其它标识交给原命令路由。
    static func named(_ id: String) -> Self? {
        let kind: LanguageXMLOverrideStore.Kind
        let suffix: String
        if id.hasSuffix("CompletionXML") {
            kind = .completion
            suffix = "CompletionXML"
        }
        else if id.hasSuffix("FunctionListXML") {
            kind = .functionList
            suffix = "FunctionListXML"
        }
        else {
            return nil
        }
        guard let action = Action(rawValue: String(id.dropLast(suffix.count))) else {
            return nil
        }
        return Self(kind: kind, action: action)
    }
}

extension ApplicationController {
    /// 业务作用：资源菜单跟随当前文档实际语言，系统候选未确认、目录未就绪或操作正在发布时不得抢占输入。
    /// 参数说明:
    /// - command: 对应补全或函数列表的具体动作。
    /// 返回：当前入口具备有效来源时为真，导出和恢复按已存在的定义单独判断。
    func canManageLanguageXML(_ command: LanguageXMLOverrideCommand) -> Bool {
        guard !closing, applicationSupport != nil, mainWindow?.hasMarkedEditorInput != true,
            let id = active?.language, id != "searchResult", registry?.language(id) != nil
        else {
            return false
        }
        switch command.kind {
        case .completion:
            return canManage(
                command.action,
                overrides: completionOverrides,
                id: id,
                original: completionCatalog?.originalXML(for: id)
            )
        case .functionList:
            return canManage(
                command.action,
                overrides: functionListOverrides,
                id: id,
                original: mappedFunctionList(for: id)?.definition.originalXML
            )
        }
    }

    /// 业务作用：文件对话框和草稿都固定到操作打开时的语言，切换文档不会重定向任何写入。
    /// 参数说明:
    /// - command: 已由原生路由分发的确切资源操作。
    /// 返回：只展示或修改所选语言的规则，用户取消和失败继续使用原定义。
    func manageLanguageXML(_ command: LanguageXMLOverrideCommand) {
        guard canManageLanguageXML(command), let active, let language = registry?.language(active.language)
        else {
            return
        }
        switch command.kind {
        case .completion:
            let template = """
                <?xml version="1.0" encoding="UTF-8"?>
                <NotepadPlus><AutoComplete><Environment ignoreCase="no"/></AutoComplete></NotepadPlus>
                """
            manage(
                command.action,
                language: language,
                overrides: completionOverrides,
                original: completionCatalog?.originalXML(for: language.id),
                template: template
            ) { [weak self] change in
                guard let self else {
                    throw CancellationError()
                }
                switch change {
                case .reload:
                    try await self.reloadCompletionOverride(language: language.id)
                case .save(let data, let generation):
                    try await self.saveCompletionOverride(data, language: language.id, generation: generation)
                }
                return []
            }
        case .functionList:
            let original = mappedFunctionList(for: language.id)?.definition
            let template = """
                <?xml version="1.0" encoding="UTF-8"?>
                <NotepadPlus><functionList><parser id="custom">
                    <function mainExpr="^def\\h+\\K[\\w]+"/>
                </parser></functionList></NotepadPlus>
                """
            manage(
                command.action,
                language: language,
                overrides: functionListOverrides,
                original: original?.originalXML,
                template: template
            ) { [weak self] change in
                guard let self else {
                    throw CancellationError()
                }
                let id = try await self.applyLanguageXMLOverride(
                    self.functionListOverrides,
                    language: language.id,
                    change: change
                )
                self.invalidateFunctionLists(for: id)
                return self.functionListOverrides.entries[id]?.definition?.definition.notices ?? []
            }
        }
    }

    /// 业务作用：读取、编辑、导出和恢复分别按实际保存状态启用，随包定义自身可编辑和导出。
    /// 参数说明:
    /// - action: 当前资源动作。
    /// - overrides: 该类别的独立运行时。
    /// - id: 注册表语言标识。
    /// - original: 当前语言随包的完整 XML，可能缺失。
    /// 返回：存在全部所需来源且没有其它发布时可操作。
    private func canManage<Rule: Sendable>(
        _ action: LanguageXMLOverrideCommand.Action,
        overrides: LanguageXMLOverrides<Rule>,
        id: String,
        original: Data?
    ) -> Bool {
        guard overrides.ready, !overrides.busy else {
            return false
        }
        let entry = overrides.entries[id]
        switch action {
        case .export: return entry?.xml != nil || original != nil
        case .restore: return entry?.xml != nil || entry?.diagnostic != nil
        case .insert, .edit, .reload: return true
        }
    }

    /// 业务作用：不同资源共用原生文件和编辑入口，按各自解析器及表单代次在后台保存。
    /// 参数说明:
    /// - action: 本次用户操作。
    /// - language: 对话框明确展示的固定语言。
    /// - overrides: 对应独立资源的运行状态。
    /// - original: 随包 XML 原字节。
    /// - template: 没有随包规则时可编辑的有效示例。
    /// - apply: 校验、保存和发布当前类别的真实动作，交回兼容说明。
    /// 返回：编辑和文件动作由真实 AppKit 入口处理，失败时保留当前资源。
    private func manage<Rule: Sendable>(
        _ action: LanguageXMLOverrideCommand.Action,
        language: LanguageDefinition,
        overrides: LanguageXMLOverrides<Rule>,
        original: Data?,
        template: String,
        apply: @escaping @MainActor (LanguageXMLOverrides<Rule>.Change) async throws -> [String]
    ) {
        let entry = overrides.entries[language.id]
        let resource = overrides.label
        let xml = entry?.xml ?? original
        var generation = entry?.generation
        switch action {
        case .edit:
            let source = xml.flatMap { String(data: $0, encoding: .utf8) } ?? template
            let editor = ResourceEditor(title: resource + " XML · " + language.name, source: source)
            if let diagnostic = entry?.diagnostic {
                editor.setDiagnostics([diagnostic])
            }
            editor.onSave = { [weak editor] source in
                Task {
                    do {
                        let notices = try await apply(.save(Data(source.utf8), expecting: generation))
                        generation = overrides.entries[language.id]?.generation
                        editor?.applyValidation(
                            for: source,
                            diagnostics: notices,
                            status: resource + "已保存并生效。"
                        )
                    }
                    catch {
                        editor?.applyValidation(
                            for: source,
                            diagnostics: [error.localizedDescription],
                            status: resource + "未应用。"
                        )
                    }
                }
            }
            retainedWindows.append(editor)
            editor.showWindow(nil)
        case .insert:
            let panel = NSOpenPanel()
            panel.title = "为 \(language.name) 导入\(resource) XML"
            panel.message = "校验通过后更新当前语言的\(resource)。"
            panel.allowedContentTypes = [.xml]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            Task {
                do {
                    let data = try await readIO.readCancellable { token in
                        try self.fileAccess.readData(
                            url,
                            maximumBytes: LanguageXMLOverrideStore.maximumXMLBytes,
                            permit: { !token.isCancelled }
                        ).data
                    }
                    let notices = try await apply(.save(data, expecting: generation))
                    mainWindow?.status.stringValue = "已导入 \(language.name) 的\(resource) XML。"
                    if !notices.isEmpty {
                        SystemIntegration.alert("保留原 XML 中的兼容字段", notices.prefix(12).joined(separator: "\n"))
                    }
                }
                catch {
                    SystemIntegration.alert(resource + " XML 未导入", error.localizedDescription)
                }
            }
        case .export:
            guard let xml else {
                return
            }
            exportRuleXML(
                xml,
                name: overrides.kind == .completion ? "completion.xml" : "function-list.xml",
                errorTitle: resource + " XML 未导出"
            )
        case .reload, .restore:
            if action == .restore {
                let prompt = NSAlert()
                if overrides.kind == .completion {
                    prompt.messageText = "恢复 \(language.name) 的随包补全？"
                    prompt.informativeText = "当前用户定义将由随包规则替换。"
                }
                else {
                    prompt.messageText = "恢复 \(language.name) 当前关联的函数列表？"
                    prompt.informativeText = "将删除当前语言单独保存的规则，并按当前函数列表关联选择定义。"
                }
                prompt.addButton(withTitle: "恢复")
                prompt.addButton(withTitle: "取消")
                guard prompt.runModal() == .alertFirstButtonReturn else {
                    return
                }
            }
            Task {
                do {
                    let change: LanguageXMLOverrides<Rule>.Change =
                        action == .restore ? .save(nil, expecting: generation) : .reload
                    let notices = try await apply(change)
                    mainWindow?.status.stringValue = "已应用 \(language.name) 的\(resource)规则。"
                    if !notices.isEmpty {
                        SystemIntegration.alert("保留原 XML 中的兼容字段", notices.prefix(12).joined(separator: "\n"))
                    }
                }
                catch {
                    SystemIntegration.alert("无法应用" + resource, error.localizedDescription)
                }
            }
        }
    }

    /// 业务作用：所有结构与补全导出都写出已选的原始 XML，覆盖目标仍使用实际磁盘证据。
    /// 参数说明:
    /// - xml: 菜单发出时冻结的完整原 XML。
    /// - name: 保存面板的默认文件名。
    /// - errorTitle: 该资源写入失败时的实际标题。
    /// 返回：取消不写入，协作写入、目标变化或失败交由同一文件发布入口处理。
    func exportRuleXML(_ xml: Data, name: String, errorTitle: String) {
        guard let url = SystemIntegration.chooseSave(name: name) else {
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
                SystemIntegration.alert(errorTitle, error.localizedDescription)
            }
        }
    }

}
