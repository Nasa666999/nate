import AppKit
import NateCore
import NatePlatform
import NateUI

@MainActor
struct RunCommandSourceProof {
    let document: WorkspaceDocument
    let window: EditorWindow
    let editor: EditorView
    let revision: UInt64
    let documentSelection: UUID
    let viewSelection: UUID
    let editing: UUID
    let target: UInt64
    let name: String
    let file: URL?

    /// 业务作用：固定实际变量来源，确认期间的正文、选择或路径往返不能继续使用旧预览。
    /// 参数说明:
    /// - document: 原活动文档实例。
    /// - window: 原工作区窗口。
    /// - editor: 原实际正文视图。
    /// 返回：不依赖后来界面焦点重读变量的完整来源证据。
    init(document: WorkspaceDocument, window: EditorWindow, editor: EditorView) {
        self.document = document
        self.window = window
        self.editor = editor
        revision = document.buffer.revision
        documentSelection = document.buffer.selectionGeneration
        viewSelection = editor.selectionGeneration
        editing = document.buffer.editingAuthorityGeneration
        target = document.targetGeneration
        name = document.name
        file = document.url
    }

    /// 业务作用：预览与执行之间只接受同一文档实例及控制代次，返回相同文字或光标也不能恢复旧资格。
    /// 参数说明:
    /// - application: 当前实际工作区。
    /// 返回：原文档、视图、正文、选择、路径及权限证据均未改变且没有候选时为真。
    func matches(_ application: ApplicationController) -> Bool {
        !application.closing && !document.closing && application.active === document
            && application.mainWindow === window && window.editor === editor
            && editor.document === document.buffer && document.buffer.revision == revision
            && document.buffer.selectionGeneration == documentSelection
            && editor.selectionGeneration == viewSelection && document.targetGeneration == target
            && document.buffer.editingAuthorityGeneration == editing
            && document.name.utf8.elementsEqual(name.utf8) && document.url == file
            && !window.hasMarkedEditorInput
    }
}

@MainActor
struct PreparedRunCommand {
    let request: UUID
    let libraryGeneration: UUID
    let definition: NamedRunCommand
    let plan: PreparedExternalCommand
    let proof: RunCommandSourceProof
}

extension ApplicationController {
    /// 业务作用：命名运行入口只准备当前真实定义，菜单和快捷键不能跳过实际参数确认。
    /// 参数说明:
    /// - id: 当前命令库实际提供的稳定身份。
    /// 返回：存在且准备通道空闲时请求完整预览，不启动进程。
    func prepareNamedRunCommand(_ id: UUID) {
        guard
            let definition = runCommands.library.commands.first(where: {
                $0.id == id
            })
        else {
            return
        }
        beginRunCommandPreparation {
            definition
        }
    }

    /// 业务作用：当前表单完整解析后再生成实际参数，预览未保存草稿仍不改写已保存配置。
    /// 参数说明:
    /// - draft: 点击时固定的全部原文输入。
    /// 返回：完整合法草稿进入同一预览流程，空名称只在临时预览时使用明确名称。
    func prepareRunCommandDraft(_ draft: RunCommandDraft) {
        beginRunCommandPreparation {
            try Self.runCommandDefinition(draft, temporary: true)
        }
    }

    /// 业务作用：变量和实际路径检查在独立通道完整完成，后台结果发布前复验原来源与草稿资格。
    /// 参数说明:
    /// - definition: 只捕获固定 Sendable 草稿或定义的完整准备方法。
    /// 返回：唯一有效准备显示完整确认窗口；取消、失效或失败不产生进程副作用。
    func beginRunCommandPreparation(_ definition: @escaping @Sendable () throws -> NamedRunCommand) {
        let runtime = runCommands
        guard !closing, runtime.ready, runtime.task == nil, runtime.importTask == nil,
            runtime.prepareTask == nil, externalCommandTask == nil,
            let document = active, let window = mainWindow,
            window.editor.document === document.buffer, window.finishCompositions()
        else {
            return
        }
        cancelRunCommandPreparation()
        let editor = window.editor
        let proof = RunCommandSourceProof(document: document, window: window, editor: editor)
        let selection: SelectionState
        do {
            selection = try editor.viewSelectionState ?? SelectionState(selections: editor.viewSelections)
        }
        catch {
            runtime.preparationFailure = error.localizedDescription
            refreshRunCommandPresentation()
            return
        }
        let text = document.buffer.text, name = document.name, file = document.url
        let defaultDirectory =
            file?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let request = UUID(), generation = runtime.generation
        let token = CancellationToken()
        runtime.prepareGeneration = request
        runtime.prepareID = request
        runtime.preparationFailure = nil
        runtime.prepareTask = Task {
            [weak self] in
            defer {
                if runtime.prepareID == request {
                    runtime.prepareTask = nil
                    runtime.prepareID = nil
                }
                self?.refreshRunCommandPresentation()
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await runtime.io.run {
                        try token.check()
                        let command = try definition()
                        var referenced: Set<String> = []
                        for template in [command.executable] + command.arguments
                            + (command.directory.map {
                                [$0]
                            } ?? [])
                        {
                            try token.check()
                            referenced.formUnion(try CommandTemplate.referencedValues(in: template))
                        }
                        let values = try RunCommandVariables.values(
                            text: text,
                            selection: selection,
                            displayName: name,
                            file: file,
                            requested: referenced,
                            permit: {
                                !token.isCancelled
                            }
                        )
                        let plan = try PreparedExternalCommand(
                            executableTemplate: command.executable,
                            argumentTemplates: command.arguments,
                            directoryTemplate: command.directory,
                            values: values,
                            defaultDirectory: defaultDirectory
                        )
                        try token.check()
                        var directory = ObjCBool(false)
                        guard
                            FileManager.default.fileExists(atPath: plan.executable, isDirectory: &directory),
                            !directory.boolValue,
                            FileManager.default.isExecutableFile(atPath: plan.executable)
                        else {
                            throw NateError.message("实际程序路径不存在、不是文件或不可执行。")
                        }
                        try token.check()
                        return (command, plan)
                    }
                } onCancel: {
                    token.cancel()
                }
                // 只读准备不拥有后来正文、选区、路径或配置的执行权，也不能重开已关闭的旧预览。
                guard let self, !Task.isCancelled, runtime.prepareGeneration == request,
                    runtime.generation == generation, proof.matches(self)
                else {
                    return
                }
                runtime.prepared = PreparedRunCommand(
                    request: request,
                    libraryGeneration: generation,
                    definition: result.0,
                    plan: result.1,
                    proof: proof
                )
                self.showRunCommandConfirmation()
            }
            catch is CancellationError {
                return
            }
            catch {
                guard !Task.isCancelled, runtime.prepareGeneration == request else {
                    return
                }
                runtime.preparationFailure = "实际命令尚未准备：" + error.localizedDescription
            }
        }
        refreshRunCommandPresentation()
    }

    /// 业务作用：草稿、来源或窗口改变立即撤销旧预览，实际后台占用仍保留到系统检查返回。
    /// 参数说明: 无。
    /// 返回：旧准备和确认按钮失去执行资格，不取消已经明确启动的独立外部命令。
    func cancelRunCommandPreparation() {
        let wasPending = runCommands.prepareTask != nil || runCommands.prepared != nil
        runCommands.prepareGeneration = UUID()
        runCommands.prepareTask?.cancel()
        runCommands.prepared = nil
        if wasPending {
            runCommands.preparationFailure = "实际命令准备已取消，请重新预览后确认。"
        }
        runCommands.confirmation?.invalidate("原文档、选择、草稿或配置已改变，请重新预览实际命令。")
    }
}
