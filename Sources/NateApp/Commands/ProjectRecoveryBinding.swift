import Foundation
import NateCore
import NateStorage

extension ApplicationController {
    /// 业务作用：只在用户明确保存恢复定义时复验原文件，完整原字节和保存点均一致后才取得覆盖资格。
    /// 参数说明:
    /// - index: 已由当前保存动作持有的独立项目面板。
    /// - operation: 本次显式保存的稳定动作身份。
    /// 返回：身份和原文件证据仍完整时解除仅因恢复设置的覆盖暂停；迟到返回为假，读取或不一致失败保留当前定义与原文件。
    func verifyRestoredProjectBinding(_ index: Int, operation: UUID) async throws -> Bool {
        // 未持有当前面板动作就没有原定义读取资格，迟到保存不能借同一索引访问新目标。
        guard projectOperationCurrent(index, operation: operation) else {
            return false
        }
        let state = projectPanelStates[index]
        // 缺少任一持久证据都不能证明原文件属于该保存点，必须保留草稿并重新确认目标。
        guard state.bindingNeedsVerification, state.saveBlocked, let url = state.url,
            let expected = state.baseline, let saved = state.saved, let workspace = state.workspace
        else {
            throw NateError.message("恢复定义没有完整原文件证据，请重新载入或另存为。")
        }
        let generation = state.generation
        let access = fileAccess
        state.feedback = "正在核验原定义文件；项目引用文件保持未访问。"
        refreshProjectPanel(index)
        let loaded = try await readIO.readCancellable {
            token in
            let bytes = try access.readData(
                url,
                maximumBytes: 8 * 1024 * 1024,
                permit: {
                    !token.isCancelled
                }
            )
            let definition = try ProjectWorkspaceArchive.decode(bytes.data)
            try token.check()
            return (definition: definition, baseline: bytes.baseline)
        }
        // 相同原路径不能复活旧动作，定义、保存点、处理身份和恢复暂停原因都必须仍属于此次保存。
        guard !Task.isCancelled, projectOperationCurrent(index, operation: operation),
            state.generation == generation, state.bindingNeedsVerification, state.saveBlocked,
            state.url?.path.utf8.elementsEqual(url.path.utf8) == true,
            state.baseline == expected, state.saved == saved, state.workspace == workspace
        else {
            return false
        }
        // 保存点或原字节证据任一不同都视为外部变化，不能用恢复草稿覆盖另一份定义。
        guard loaded.baseline == expected, loaded.definition == saved else {
            throw NateError.message("原定义文件与恢复保存点不一致，未取得覆盖权；请重新载入或另存为。")
        }
        // 只解除已完成原文件复验的恢复暂停；真正保存仍按相同基线、目标占用和单次发布权限执行。
        state.baseline = loaded.baseline
        state.bindingNeedsVerification = false
        state.saveBlocked = false
        state.feedback = "原定义路径已复验，正在保存当前项目定义。"
        return true
    }
}
