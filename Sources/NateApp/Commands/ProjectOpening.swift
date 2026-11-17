import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：撤销原项目文件打开意图，换面板、隐藏、改定义或退出后不能由迟到读取抢占焦点。
    /// 参数说明: 无。
    /// 返回：原请求身份先失效，随后取消读取并收回句柄。
    func cancelProjectOpen() {
        // 先撤销发布资格再取消底层等待，已经返回但仍等待主执行域的结果同样失权。
        projectOpenGeneration = UUID()
        projectOpenTask?.cancel()
        projectOpenTask = nil
    }

    /// 业务作用：用户激活项目文件时先解析当前引用与位置授权，再通过统一工作区读取并复验后激活。
    /// 参数说明:
    /// - id: 当前定义中的稳定文件节点。
    /// - index: 用户正在使用的独立项目面板。
    /// 返回：完整当前引用进入唯一打开通道；候选、换面板、改定义、移动光标或退出使旧请求失效。
    func openProjectNode(_ id: UUID, panel index: Int) {
        cancelProjectOpen()
        // 隐藏面板和未确认输入都不拥有新文件的焦点交接权。
        guard !closing, projectPanelStates.indices.contains(index), let window = mainWindow,
            !window.projectPanels.isHidden, window.projectPanels.selectedIndex == index,
            !window.hasMarkedEditorInput, findWindow?.isEditingInput != true,
            projectPanelStates[index].operation == nil,
            let node = projectPanelStates[index].workspace?.nodes.first(where: {
                $0.id == id
            }),
            node.kind == .file, node.path != nil
        else {
            return
        }
        let state = projectPanelStates[index]
        let generation = state.generation
        let request = projectOpenGeneration
        projectOpenTask = Task {
            [weak self, weak window] in
            guard let self, let window else {
                return
            }
            defer {
                if request == self.projectOpenGeneration {
                    self.projectOpenTask = nil
                }
            }
            do {
                let url = try self.resolveProjectReference(node, panel: index)
                // 位置确认可运行嵌套事件循环，原定义与激活意图必须同时仍然成立。
                guard !self.closing, request == self.projectOpenGeneration,
                    state.generation == generation, self.mainWindow === window,
                    state.operation == nil,
                    window.projectPanels.selectedIndex == index, !window.projectPanels.isHidden
                else {
                    return
                }
                let movement = self.searchNavigationGeneration
                let revision = self.active?.buffer.revision
                let selections = window.editor.viewSelections
                let documentSelections = self.active?.buffer.selections
                let permitted: @MainActor () -> Bool = {
                    [weak self, weak window, weak origin = self.active?.buffer, weak editor = window.editor]
                    in
                    guard let self, let window, !self.closing, !Task.isCancelled,
                        self.projectOpenGeneration == request, state.generation == generation,
                        state.operation == nil,
                        state.workspace?.nodes.first(where: {
                            $0.id == id
                        }) == node,
                        self.mainWindow === window, !window.projectPanels.isHidden,
                        window.projectPanels.selectedIndex == index,
                        self.searchNavigationGeneration == movement,
                        self.active?.buffer === origin, origin?.revision == revision,
                        origin?.selections == documentSelections,
                        window.editor === editor, editor?.viewSelections == selections,
                        !window.hasMarkedEditorInput, self.findWindow?.isEditingInput != true
                    else {
                        return false
                    }
                    return true
                }
                guard permitted(),
                    let opened = await self.openFile(url, activateOnOpen: false, permit: permitted),
                    permitted()
                else {
                    return
                }
                // 读取与引用权威全部确认后，在同一执行域内完成激活，不再跨越等待边界。
                self.activate(opened.buffer.id)
                window.window?.makeFirstResponder(window.editor)
                state.feedback = "已打开当前文件引用。"
                self.refreshProjectPanel(index)
            }
            catch {
                // 旧引用的位置错误不属于新面板或新定义，不能覆盖当前操作的反馈。
                if request == self.projectOpenGeneration, state.generation == generation, !self.closing {
                    state.feedback = error.localizedDescription
                    self.refreshProjectPanel(index)
                }
            }
        }
    }

    /// 业务作用：引用路径只在用户显式激活时解释，外来 URI、UNC 和 Windows 位置须重新选择本机文件。
    /// 参数说明:
    /// - node: 原始完整文件引用。
    /// - index: 该引用所属面板。
    /// 返回：已明确允许访问的本机文件 URL；未知位置、未保存的相对引用或取消确认明确失败。
    func resolveProjectReference(_ node: ProjectNode, panel index: Int) throws -> URL {
        guard let path = node.path else {
            throw NateError.message("该节点没有文件引用。")
        }
        let state = projectPanelStates[index]
        let absolute = try ProjectReferencePath.absolute(path, relativeTo: state.url?.path)
        if ProjectReferencePath.referencesVolume(absolute),
            !state.selectedPaths.contains(Data(absolute.utf8))
        {
            let alert = NSAlert()
            alert.messageText = "访问外置或网络卷中的项目文件？"
            alert.informativeText = absolute
            alert.addButton(withTitle: "访问此文件")
            alert.addButton(withTitle: "取消")
            // 未经本次明确确认不执行类型探测、存在性检查或正文读取。
            guard alert.runModal() == .alertFirstButtonReturn else {
                throw NateError.message("已取消访问，该引用位置尚未检查。")
            }
        }
        let url = URL(
            fileURLWithPath: absolute,
            isDirectory: false
        )
        try FileStorage.validateFileURL(url)
        return url
    }
}
