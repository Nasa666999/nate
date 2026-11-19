import AppKit
import NateCore
import NateStorage
import NateUI

@MainActor
final class KeyboardMapRuntime {
    let io = IOExecutor(name: "nate.keyboard.map", concurrency: 1, maximumStalled: 0)
    var store: KeyboardMapStore?
    var configuration = KeyboardMap()
    var baseline: DiskBaseline?
    var ready = false
    var writable = false
    var failure: String?
    var task: Task<Void, Never>?
    var panel: KeyboardMapPanel?
    var catalog: [KeyboardCommandEntry] = []
    var resolution: KeyboardMapResolution?
    var generation = UUID()
    var preview: KeyboardMap?
    var previewName: String?
    var importTask: Task<Void, Never>?
    var importID: UUID?
    var importGeneration = UUID()
    var monitor: Any?

    /// 业务作用：用户覆盖拥有独立串行存储与预览，设置读取不占用正文保存通道。
    /// 参数说明: 无。
    /// 返回：沿默认绑定、尚未读取磁盘的初始状态。
    init() {}
}

private enum KeyboardMapPublication: Sendable {
    case saved(DiskBaseline)
    case pending(String)
}

extension ApplicationController {
    /// 业务作用：固定应用支持目录后完整读取设置，损坏或未知归档保留原字节并使用默认命令。
    /// 参数说明: 无。
    /// 返回：读取完成后更新实际菜单，不执行配置中的命令或改变正文。
    func configureKeyboardMap() {
        let runtime = keyboardMap
        guard runtime.store == nil, let support = applicationSupport else {
            return
        }
        let store = KeyboardMapStore(directory: support.appendingPathComponent("Keyboard", isDirectory: true))
        runtime.store = store
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshKeyboardMapPresentation()
            }
            do {
                let loaded = try await runtime.io.run {
                    try store.load()
                }
                guard let self, !self.closing else {
                    return
                }
                runtime.configuration = loaded.configuration ?? KeyboardMap()
                runtime.baseline = loaded.baseline
                runtime.writable = true
                runtime.ready = true
                self.buildMenus()
            }
            catch {
                runtime.ready = true
                runtime.writable = false
                runtime.failure = "原快捷键文件已保留，当前使用默认绑定：" + error.localizedDescription
                self?.buildMenus()
            }
        }
    }

    /// 业务作用：只有载入完成且无实际发布任务时才能修改整份覆盖，避免沿未知基线产生部分配置。
    /// 参数说明: 无。
    /// 返回：当前配置可明确保存时为真。
    func canChangeKeyboardMap() -> Bool {
        !closing && keyboardMap.ready && keyboardMap.writable && keyboardMap.task == nil
            && keyboardMap.importTask == nil
    }

    /// 业务作用：完整候选先编码，磁盘异常保留用户新意图并停止后续自动覆盖。
    /// 参数说明:
    /// - candidate: 用户明确应用的完整覆盖。
    /// 返回：成功后发布新基线；失败保留内存候选与未保存提示，不误报已保存。
    func saveKeyboardMap(_ candidate: KeyboardMap) {
        let runtime = keyboardMap
        guard canChangeKeyboardMap(), let store = runtime.store else {
            return
        }
        let baseline = runtime.baseline
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshKeyboardMapPresentation()
            }
            do {
                let result = try await runtime.io.run {
                    _ = try KeyboardMapArchive.encode(candidate)
                    do {
                        return KeyboardMapPublication.saved(try store.publish(candidate, expected: baseline))
                    }
                    catch {
                        return KeyboardMapPublication.pending(error.localizedDescription)
                    }
                }
                // 完整候选已通过容量门禁，文件失败仍保留本次意图，不能恢复旧绑定后声称保存完成。
                runtime.configuration = candidate
                runtime.generation = UUID()
                runtime.preview = nil
                runtime.previewName = nil
                switch result {
                case .saved(let saved):
                    runtime.baseline = saved
                    runtime.failure = nil
                    runtime.writable = true
                case .pending(let message):
                    runtime.failure = "当前映射尚未保存：" + message
                    runtime.writable = false
                }
                self?.buildMenus()
            }
            catch {
                runtime.failure = "映射未改变：" + error.localizedDescription
            }
        }
        refreshKeyboardMapPresentation()
    }

    /// 业务作用：异常文件只能在重新读取原基线并明确确认后重建，确认期间的外部改变仍拒绝覆盖。
    /// 参数说明: 无。
    /// 返回：完整当前映射成功保存后恢复写入；拒绝或失败保留文件与当前配置。
    func rebuildKeyboardMap() {
        let runtime = keyboardMap
        guard !closing, runtime.ready, runtime.task == nil, runtime.importTask == nil,
            let store = runtime.store
        else {
            return
        }
        let candidate = runtime.configuration
        runtime.task = Task {
            [weak self] in
            defer {
                runtime.task = nil
                self?.refreshKeyboardMapPresentation()
            }
            do {
                let baseline = try await runtime.io.run {
                    try store.baseline()
                }
                guard let self, !self.closing else {
                    return
                }
                let question = NSAlert()
                question.messageText = "重新保存当前快捷键映射？"
                question.informativeText = "将使用当前完整映射替换原设置文件。原有无法读取的内容将被替换；此操作不执行命令。"
                question.addButton(withTitle: "重新保存")
                question.addButton(withTitle: "保留原文件")
                guard question.runModal() == .alertFirstButtonReturn, !self.closing else {
                    return
                }
                let saved = try await runtime.io.run {
                    try store.publish(candidate, expected: baseline, rebuilding: true)
                }
                runtime.baseline = saved
                runtime.writable = true
                runtime.failure = nil
                self.buildMenus()
            }
            catch {
                runtime.failure = "当前映射尚未保存：" + error.localizedDescription
            }
        }
        refreshKeyboardMapPresentation()
    }
}
