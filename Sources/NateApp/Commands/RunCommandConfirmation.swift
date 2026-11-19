import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：完整实际参数以可复制全文呈现，程序和工作目录用 JSON 字符串显示以区分引号与换行。
    /// 参数说明: 无。
    /// 返回：显示本次有效准备的确认窗口，不启动程序。
    func showRunCommandConfirmation() {
        let runtime = runCommands
        guard !closing, let prepared = runtime.prepared else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let program = String(decoding: try encoder.encode(prepared.plan.executable), as: UTF8.self)
            let directory = String(decoding: try encoder.encode(prepared.plan.directory?.path), as: UTF8.self)
            let arguments = String(decoding: try encoder.encode(prepared.plan.arguments), as: UTF8.self)
            let text =
                "配置：" + prepared.definition.name + "\n身份：" + prepared.definition.id.uuidString
                + "\n\n实际程序：\n" + program + "\n\n实际工作目录：\n" + directory
                + "\n\n完整参数数组：\n" + arguments
            runtime.confirmation?.close()
            let panel = RunCommandPreview(
                request: prepared.request,
                name: prepared.definition.name,
                text: text
            )
            panel.onConfirm = {
                [weak self] in self?.confirmRunCommand($0)
            }
            panel.onClose = {
                [weak self] request in
                guard let self, self.runCommands.prepared?.request == request else {
                    return
                }
                self.cancelRunCommandPreparation()
                self.runCommands.confirmation = nil
            }
            runtime.confirmation = panel
            panel.showWindow(nil)
            panel.window?.makeKeyAndOrderFront(nil)
        }
        catch {
            runtime.preparationFailure = "命令预览未完成：" + error.localizedDescription
            cancelRunCommandPreparation()
        }
    }

    /// 业务作用：明确确认仍须复验同一来源与配置，原预览不能在新正文或后来草稿上启动外部进程。
    /// 参数说明:
    /// - request: 用户当前点击的确认窗口身份。
    /// 返回：全部证据一致才启动同一份固定命令；拒绝时保留完整预览与具体原因。
    func confirmRunCommand(_ request: UUID) {
        let runtime = runCommands
        // 实际进程任务未释放、来源失效或预览代次改变时立即拒绝，不能重读新变量继续执行旧确认。
        guard !closing, externalCommandTask == nil, runtime.prepareTask == nil,
            let prepared = runtime.prepared, prepared.request == request,
            runtime.prepareGeneration == request, runtime.generation == prepared.libraryGeneration,
            prepared.proof.matches(self)
        else {
            runtime.confirmation?.invalidate("本次命令来源或实际任务状态已改变，请重新预览后确认。")
            runtime.prepared = nil
            return
        }
        runtime.prepared = nil
        runtime.confirmation?.close()
        runtime.confirmation = nil
        executeExternalCommand(
            prepared.plan.executable,
            arguments: prepared.plan.arguments,
            directory: prepared.plan.directory
        )
        refreshRunCommandPresentation()
    }
}
