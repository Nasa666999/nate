import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class RunCommandRuntime {
    let io = IOExecutor(name: "nate.run.commands", concurrency: 1, maximumStalled: 0)
    var store: RunCommandStore?
    var library = RunCommandLibrary()
    var baseline: DiskBaseline?
    var ready = false
    var writable = false
    var failure: String?
    var task: Task<Void, Never>?
    var generation = UUID()
    var panel: RunCommandPanel?
    var importCandidate: RunCommandLibrary?
    var importName: String?
    var importTask: Task<Void, Never>?
    var importID: UUID?
    var importGeneration = UUID()
    var prepareTask: Task<Void, Never>?
    var prepareID: UUID?
    var prepareGeneration = UUID()
    var prepared: PreparedRunCommand?
    var confirmation: RunCommandPreview?
    var preparationFailure: String?
    var newDraftRequested = false

    /// 业务作用：命名运行配置、导入与执行准备拥有独立身份，文件读取不取得外部进程启动权。
    /// 参数说明: 无。
    /// 返回：没有已保存命令或可执行预览的初始状态。
    init() {}
}

private enum RunCommandPublication: Sendable {
    case saved(RunCommandLibrary, DiskBaseline)
    case pending(RunCommandLibrary, String)
}

extension ApplicationController {
    /// 业务作用：支持目录确定后完整载入独立运行配置，未知或损坏归档保留原字节并关闭自动覆盖。
    /// 参数说明: 无。
    /// 返回：安装完整可查看定义；载入不执行命令，也不阻止编辑器正常打开。
    func configureRunCommands() {
        let runtime = runCommands
        guard runtime.store == nil, let support = applicationSupport else {
            return
        }
        let store = RunCommandStore(
            directory: support.appendingPathComponent("RunCommands", isDirectory: true)
        )
        runtime.store = store
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshRunCommandPresentation()
            }
            do {
                let loaded = try await runtime.io.run {
                    try store.load()
                }
                guard let self, !self.closing else {
                    return
                }
                runtime.library = loaded.library ?? RunCommandLibrary()
                runtime.baseline = loaded.baseline
                runtime.generation = UUID()
                runtime.ready = true
                runtime.writable = true
                self.buildMenus()
            }
            catch {
                runtime.ready = true
                runtime.writable = false
                runtime.failure = "原运行配置已保留，当前列表只读：" + error.localizedDescription
            }
        }
    }

    /// 业务作用：完整读取和实际发布收束后才能保存新列表，未知基线不能被后台草稿覆盖。
    /// 参数说明: 无。
    /// 返回：当前可以明确改变完整库时为真，不授予进程启动资格。
    func canChangeRunCommands() -> Bool {
        !closing && runCommands.ready && runCommands.writable && runCommands.task == nil
            && runCommands.importTask == nil && runCommands.prepareTask == nil
    }

    /// 业务作用：完整候选先通过最终归档容量门禁，文件失败保留用户新意图并停止后续自动覆盖。
    /// 参数说明:
    /// - candidate: 用户明确保留的完整配置列表。
    /// - selecting: 保存完成后明确定位的配置身份。
    /// 返回：成功发布新基线；冲突保留候选和未保存说明，不启动配置中的程序。
    func saveRunCommands(_ candidate: RunCommandLibrary, selecting: UUID? = nil) {
        changeRunCommandLibrary(
            {
                _ in candidate
            },
            selecting: selecting
        )
    }

    /// 业务作用：草稿解析和完整列表变更先在后台全部通过，再进入唯一串行发布步骤。
    /// 参数说明:
    /// - change: 只捕获固定输入并生成完整库的准备方法。
    /// - selecting: 发布后明确定位的配置身份。
    /// 返回：输入失败保留原列表，磁盘失败保留完整新意图和原文件。
    func changeRunCommandLibrary(
        _ change: @escaping @Sendable (RunCommandLibrary) throws -> RunCommandLibrary,
        selecting: UUID? = nil
    ) {
        let runtime = runCommands
        guard canChangeRunCommands(), let store = runtime.store else {
            return
        }
        cancelRunCommandPreparation()
        let baseline = runtime.baseline
        let original = runtime.library
        let panelIntent = runtime.panel?.intentGeneration
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshRunCommandPresentation()
                if let selecting, runtime.panel?.intentGeneration == panelIntent {
                    runtime.panel?.selectCommand(selecting)
                }
            }
            do {
                let result = try await runtime.io.run {
                    let candidate = try change(original)
                    _ = try RunCommandArchive.encode(candidate)
                    do {
                        return RunCommandPublication.saved(
                            candidate,
                            try store.publish(candidate, expected: baseline)
                        )
                    }
                    catch {
                        return RunCommandPublication.pending(candidate, error.localizedDescription)
                    }
                }
                // 完整意图已通过容量门禁，磁盘失败不能换回旧列表后误报保存成功。
                runtime.generation = UUID()
                runtime.importCandidate = nil
                runtime.importName = nil
                switch result {
                case .saved(let candidate, let saved):
                    runtime.library = candidate
                    runtime.baseline = saved
                    runtime.writable = true
                    runtime.failure = nil
                case .pending(let candidate, let message):
                    runtime.library = candidate
                    runtime.writable = false
                    runtime.failure = "当前运行配置尚未保存：" + message
                }
                self?.buildMenus()
            }
            catch {
                runtime.failure = "运行配置未改变：" + error.localizedDescription
            }
        }
        refreshRunCommandPresentation()
    }

    /// 业务作用：损坏配置只能读取新原字节基线并明确确认后重建，确认不能覆盖之后的外部改变。
    /// 参数说明: 无。
    /// 返回：完整当前库实际保存后恢复写入；拒绝或失败保留原内容与原因。
    func rebuildRunCommands() {
        let runtime = runCommands
        guard !closing, runtime.ready, runtime.task == nil, runtime.importTask == nil,
            runtime.prepareTask == nil, let store = runtime.store
        else {
            return
        }
        cancelRunCommandPreparation()
        let library = runtime.library
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshRunCommandPresentation()
            }
            do {
                let baseline = try await runtime.io.run {
                    try store.baseline()
                }
                guard let self, !self.closing else {
                    return
                }
                let question = NSAlert()
                question.messageText = "重新保存当前运行配置？"
                question.informativeText = "将使用当前完整列表替换原配置文件。原有无法读取的内容将被替换；此操作不执行程序。"
                question.addButton(withTitle: "重新保存")
                question.addButton(withTitle: "保留原文件")
                guard question.runModal() == .alertFirstButtonReturn, !self.closing else {
                    return
                }
                let saved = try await runtime.io.run {
                    try store.publish(library, expected: baseline, rebuilding: true)
                }
                runtime.baseline = saved
                runtime.writable = true
                runtime.failure = nil
                self.buildMenus()
            }
            catch {
                runtime.failure = "当前运行配置尚未保存：" + error.localizedDescription
            }
        }
        refreshRunCommandPresentation()
    }
}
