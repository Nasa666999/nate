import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class MacroLibraryRuntime {
    let io = IOExecutor(name: "nate.macro.library", concurrency: 1, maximumStalled: 0)
    var store: MacroLibraryStore?
    var definitions: [NamedMacro] = []
    var baseline: DiskBaseline?
    var ready = false
    var writable = false
    var failure: String?
    var task: Task<Void, Never>?
    var panel: MacroLibraryPanel?
    var preview: MacroLibraryPanel?
    var previewDefinition: NamedMacro?
    var importTask: Task<Void, Never>?
    var importTaskID: UUID?
    var importGeneration = UUID()

    /// 业务作用：命名宏归档与临时导入各持有独立状态，文件等待不阻塞正文自动保存。
    /// 参数说明: 无。
    /// 返回：尚未载入任何磁盘宏的初始状态。
    init() {}
}

private enum MacroLibraryChange: Sendable {
    case saved(MacroLibrarySnapshot, DiskBaseline)
    case pending(MacroLibrarySnapshot, String)
}

extension ApplicationController {
    /// 业务作用：应用数据目录确定后独立载入宏库，不替换当前临时录制或自动播放任何动作。
    /// 参数说明: 无。
    /// 返回：完整库取得查看资格；异常保留文件并关闭自动覆盖，正文仍可编辑。
    func configureMacroLibrary() {
        let runtime = macroLibrary
        guard runtime.store == nil, let support = applicationSupport else {
            return
        }
        let store = MacroLibraryStore(directory: support.appendingPathComponent("Macros", isDirectory: true))
        runtime.store = store
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshMacroLibraryPresentation()
            }
            do {
                let loaded = try await runtime.io.run {
                    try store.load()
                }
                guard let self, !self.closing else {
                    return
                }
                runtime.definitions = loaded.snapshot?.definitions ?? []
                runtime.baseline = loaded.baseline
                runtime.writable = loaded.writable
                runtime.failure = loaded.warning
                runtime.ready = true
                self.buildMenus()
            }
            catch {
                runtime.ready = true
                runtime.writable = false
                runtime.failure = error.localizedDescription
            }
        }
    }

    /// 业务作用：管理动作必须等待完整载入和实际文件任务结束，不能在未知基线上提交新定义。
    /// 参数说明: 无。
    /// 返回：当前可以明确改变宏库时为真，不授予正文播放权限。
    func canChangeMacroLibrary() -> Bool {
        !closing && macroLibrary.ready && macroLibrary.writable && macroLibrary.task == nil
            && !macroPlaying && macroPlayback.task == nil && !macroRecording
    }

    /// 业务作用：完整准备新列表后在独立串行通道保存，输入错误保留旧列表，磁盘失败保留待保存意图。
    /// 参数说明:
    /// - change: 只使用传入不可变定义生成完整候选，不捕获界面对象。
    /// 返回：成功发布新基线；文件冲突保留候选供明确处理，关闭自动覆盖而不修改正文。
    func changeMacroLibrary(_ change: @escaping @Sendable ([NamedMacro]) throws -> [NamedMacro]) {
        let runtime = macroLibrary
        guard canChangeMacroLibrary(), let store = runtime.store else {
            return
        }
        let original = runtime.definitions, baseline = runtime.baseline
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshMacroLibraryPresentation()
            }
            do {
                let result = try await runtime.io.run {
                    let snapshot = try MacroLibrarySnapshot(change(original))
                    // 最终归档容量先于磁盘动作判定，超量候选不能使仍有效的原库失去继续管理的资格。
                    _ = try MacroLibraryArchive.encode(snapshot)
                    do {
                        return MacroLibraryChange.saved(
                            snapshot,
                            try store.publish(snapshot, expected: baseline)
                        )
                    }
                    catch {
                        return MacroLibraryChange.pending(snapshot, error.localizedDescription)
                    }
                }
                switch result {
                case .saved(let snapshot, let baseline):
                    runtime.definitions = snapshot.definitions
                    runtime.baseline = baseline
                    runtime.writable = true
                    runtime.failure = nil
                case .pending(let snapshot, let message):
                    // 用户的完整新列表仍在内存，磁盘失败不能重新安装旧定义后声称保存成功。
                    runtime.definitions = snapshot.definitions
                    runtime.writable = false
                    runtime.failure = "当前列表尚未保存：" + message
                }
                self?.buildMenus()
            }
            catch {
                runtime.failure = "宏未保存：" + error.localizedDescription
            }
        }
        refreshMacroLibraryPresentation()
    }

    /// 业务作用：异常库只能在固定原基线和完整当前列表后明确重建，确认期间的外部改变仍拒绝覆盖。
    /// 参数说明: 无。
    /// 返回：用户确认后重新保存两份归档；拒绝、失权或发布失败均保留当前定义和原因。
    func resetMacroLibrary() {
        let runtime = macroLibrary
        guard !closing, runtime.task == nil, !macroPlaying, macroPlayback.task == nil,
            !macroRecording, let store = runtime.store
        else {
            return
        }
        let definitions = runtime.definitions
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshMacroLibraryPresentation()
            }
            do {
                let baseline = try await runtime.io.run {
                    try store.baseline()
                }
                guard let self, !self.closing else {
                    return
                }
                let question = NSAlert()
                question.messageText = "重新保存当前命名宏列表？"
                question.informativeText = "将用当前 \(definitions.count) 个宏重新建立两份宏库归档。原有无法读取的内容将被替换；此操作不修改正文。"
                question.addButton(withTitle: "重新保存")
                question.addButton(withTitle: "保留原文件")
                guard question.runModal() == .alertFirstButtonReturn, !self.closing else {
                    return
                }
                let saved = try await runtime.io.run {
                    try store.publish(MacroLibrarySnapshot(definitions), expected: baseline, rebuilding: true)
                }
                runtime.baseline = saved
                runtime.writable = true
                runtime.ready = true
                runtime.failure = nil
                self.buildMenus()
            }
            catch {
                runtime.failure = "当前列表尚未保存：" + error.localizedDescription
            }
        }
        refreshMacroLibraryPresentation()
    }
}
