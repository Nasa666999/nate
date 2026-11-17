import Foundation
import NateStorage
import NateUI

private struct WorkspaceDirectoryRecord {
    let url: URL
    var stamp: DirectoryStamp?
}

@MainActor
final class DirectoryWorkspaceController {
    weak var application: ApplicationController?
    weak var window: EditorWindow?
    private let io = IOExecutor(
        name: "nate.directory.workspace",
        concurrency: 1,
        maximumStalled: 0
    )
    private(set) var root: URL?
    private var generation = UUID()
    private var records: [Data: WorkspaceDirectoryRecord] = [:]
    private var requests: [Data: (UUID, Task<Void, Never>)] = [:]
    private var monitor: Task<Void, Never>?

    /// 业务作用：目录工作区单独持有读取任务和观察状态，不与会话、虚拟项目或结果面板共用列表。
    /// 参数说明:
    /// - application: 统一文件打开与退出权威。
    /// - window: 当前目录侧栏所属窗口。
    /// 返回：尚未取得任何目录读取权限的协调器。
    init(application: ApplicationController, window: EditorWindow) {
        self.application = application
        self.window = window
        window.directoryPanel.onLoad = {
            [weak self] path in self?.load(path)
        }
        window.directoryPanel.onOpen = {
            [weak self] path in
            // 关闭和退出已经撤销目录打开资格，失效行不能再引入新的文件读取。
            guard let self, self.root != nil, self.application?.closing == false else {
                return
            }
            let generation = self.generation
            Task {
                [weak self] in
                guard let self, let application = self.application, !application.closing,
                    self.generation == generation
                else {
                    return
                }
                // 文件打开也绑定原树，切根、关闭或移除条目后，迟到读取不能取得标签与焦点。
                await application.openFile(
                    URL(fileURLWithPath: path),
                    permit: {
                        [weak self] in
                        self?.generation == generation && self?.application?.closing == false
                            && self?.window === self?.application?.mainWindow
                            && self?.window?.directoryPanel.containsPath(path) == true
                    }
                )
            }
        }
        window.directoryPanel.onRefresh = {
            [weak self] in self?.refresh()
        }
        window.directoryPanel.onClose = {
            [weak self] in self?.stop()
        }
    }

    /// 业务作用：用户选择新根后先撤销原树发布权，再建立独立根节点并读取首层。
    /// 参数说明:
    /// - url: 用户明确选择的原始目录 URL。
    /// 返回：合法 URL 成为新根，实际读取失败单独显示；非法 URL 不改变原树。
    func start(_ url: URL) throws {
        try FileStorage.validateFileURL(url)
        guard application?.closing == false, let window else {
            return
        }
        // 原根的队列和观察先失权，随后才装配新根，迟到清单不能覆盖新目录。
        pause()
        records.removeAll()
        let root = url.standardizedFileURL
        self.root = root
        window.directoryPanel.setRoot(root.path)
        window.setDirectoryVisible(true)
        load(root.path)
        beginMonitoring()
    }

    /// 业务作用：同一目录只保留一个当前读取请求，后台完整清单在复验根、节点和请求后整体发布。
    /// 参数说明:
    /// - path: 当前树内用户展开或观察到变化的目录。
    /// 返回：合法当前节点进入有界队列，旧请求、被移除节点和退出状态不更新树。
    func load(_ path: String) {
        // 目录节点、原根和活动窗口必须仍然存在，移出的路径不能重新排队获取展示权。
        guard let root, let window, application?.closing == false,
            window.directoryPanel.containsDirectory(path)
        else {
            return
        }
        let key = Data(path.utf8)
        guard requests[key] == nil else {
            return
        }
        // 展开目录数同时限制观察与队列占用，不能让巨大目录树持续增加后台任务。
        guard records[key] != nil || records.count < 64 else {
            window.directoryPanel.fail(path, message: "最多同时读取并观察 64 个目录，请重新选择较小根目录。")
            return
        }
        let url = URL(
            fileURLWithPath: path,
            isDirectory: true
        )
        records[key] =
            records[key]
            ?? WorkspaceDirectoryRecord(
                url: url,
                stamp: nil
            )
        let generation = generation
        let request = UUID()
        let io = io
        let task = Task {
            [weak self, weak window] in
            guard let self, let window else {
                return
            }
            defer {
                if self.requests[key]?.0 == request {
                    self.requests.removeValue(forKey: key)
                }
            }
            do {
                let (stamp, entries) = try await io.readCancellable {
                    token in
                    let contents = try DirectoryContents.read(
                        root: root,
                        directory: url,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    return (
                        contents.stamp,
                        contents.entries.map {
                            DirectoryTreeEntry(
                                path: $0.url.path,
                                isDirectory: $0.isDirectory
                            )
                        }
                    )
                }
                // 相同路径也可能已属于另一根或另一轮读取；退出、关闭和节点移除都撤销原发布资格。
                guard !Task.isCancelled, self.generation == generation,
                    self.requests[key]?.0 == request, self.application?.closing == false,
                    self.window === window, window.directoryPanel.containsDirectory(path)
                else {
                    return
                }
                if window.directoryPanel.present(path, entries: entries) {
                    self.records[key]?.stamp = stamp
                    self.pruneRemovedDirectories()
                }
            }
            catch {
                // 失败反馈也属于原请求，迟到错误不能清空新根或新一轮的节点。
                guard !Task.isCancelled, self.generation == generation,
                    self.requests[key]?.0 == request, self.application?.closing == false
                else {
                    return
                }
                self.records[key]?.stamp = nil
                window.directoryPanel.fail(path, message: error.localizedDescription)
                self.pruneRemovedDirectories()
            }
        }
        requests[key] = (request, task)
    }

    /// 业务作用：父目录更新后释放已经移出树的后代观察和请求，旧路径不能继续后台访问。
    /// 参数说明: 无。
    /// 返回：记录和队列只保留当前目录树仍有的节点。
    private func pruneRemovedDirectories() {
        guard let window else {
            return
        }
        for (key, record) in records where !window.directoryPanel.containsDirectory(record.url.path) {
            requests.removeValue(forKey: key)?.1.cancel()
            records.removeValue(forKey: key)
        }
    }

    /// 业务作用：显式刷新当前已读取目录，不递归发现尚未展开的子目录。
    /// 参数说明: 无。
    /// 返回：现有节点分别排队复验，目录未选择时无副作用。
    func refresh() {
        for record in Array(records.values) {
            load(record.url.path)
        }
    }

    /// 业务作用：启动单个周期观察任务，目录变化只更新树，不抢正文焦点或覆盖搜索结果。
    /// 参数说明: 无。
    /// 返回：每两秒检查已读取目录，退出或失权后停止。
    private func beginMonitoring() {
        monitor?.cancel()
        let generation = generation
        monitor = Task {
            [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                }
                catch {
                    return
                }
                guard let self, self.generation == generation, self.application?.closing == false else {
                    return
                }
                await self.observe(generation: generation)
            }
        }
    }

    /// 业务作用：先比较轻量目录状态，只有变化或上次读取失败时才重新枚举首层。
    /// 参数说明:
    /// - generation: 观察启动时的根请求身份。
    /// 返回：仍有效的变化节点进入读取，迟到观察不重建已关闭目录。
    private func observe(generation: UUID) async {
        guard let root else {
            return
        }
        for (key, record) in Array(records) {
            // 观察跨越了等待边界，退出、换根或取消后不能继续为旧树发起读取。
            guard !Task.isCancelled, self.generation == generation, application?.closing == false else {
                return
            }
            if requests[key] != nil {
                continue
            }
            guard let previous = record.stamp else {
                load(record.url.path)
                continue
            }
            do {
                let stamp = try await io.readCancellable {
                    token in
                    try DirectoryContents.observe(
                        root: root,
                        directory: record.url,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                guard self.generation == generation, application?.closing == false else {
                    return
                }
                if stamp != previous {
                    load(record.url.path)
                }
            }
            catch {
                // 旧观察的失败不属于当前树，不能用它撤下已经重新读取的目录。
                guard self.generation == generation, application?.closing == false, !Task.isCancelled else {
                    return
                }
                records[key]?.stamp = nil
                window?.directoryPanel.fail(record.url.path, message: error.localizedDescription)
                pruneRemovedDirectories()
            }
        }
    }

    /// 业务作用：退出或更换根前先撤销目录发布资格，取消等待及观察，保留可恢复的已有展示。
    /// 参数说明: 无。
    /// 返回：旧请求即使已经返回也不能修改树，原根和清单仍可用于取消退出后的重读。
    func pause() {
        // 请求身份先失效，随后才取消线程等待，已返回但等待主执行域的清单同样不能发布。
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        for request in requests.values {
            request.1.cancel()
        }
        requests.removeAll()
        io.cancelReads()
    }

    /// 业务作用：取消退出后重新取得独立目录观察资格，不恢复旧任务的发布权。
    /// 参数说明: 无。
    /// 返回：已有目录重新读取并启动新观察，没有根时不启动任务。
    func resume() {
        // 只有仍存在且已解除退出状态的根能重新取得读取入口，空根不自动选择任何磁盘路径。
        guard root != nil, application?.closing == false else {
            return
        }
        refresh()
        beginMonitoring()
    }

    /// 业务作用：关闭目录工作区先停止读取和观察，再隐藏侧栏，文件和正文均保持原状。
    /// 参数说明: 无。
    /// 返回：根与观察记录释放，目录侧栏收起。
    func stop() {
        // 先撤销所有发布资格，再释放根与行对象，关闭后的异步返回不能重建不可见侧栏。
        pause()
        root = nil
        records.removeAll()
        window?.directoryPanel.clear()
        window?.setDirectoryVisible(false)
    }
}
