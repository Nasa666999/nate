import AppKit
import NateCore
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：取得搜索配置的完整字节和保存基线，未知或损坏归档不自动覆盖。
    /// 参数说明: 无。
    /// 返回：合法配置供窗口恢复；缺失时使用默认值，失败时保留归档并等待用户显式重新保存。
    func loadSearchSettings() async {
        searchSettingsState = mergingSearchUserPreferences(searchSettingsState)
        // 未取得应用数据目录时不推断其它位置，也不把临时窗口变成持久化入口。
        guard let applicationSupport else {
            return
        }
        let url = applicationSupport.appendingPathComponent("Search.plist")
        searchSettingsURL = url
        do {
            let (state, baseline) = try await searchSettingsIO.readCancellable {
                token -> (SearchWindowState, DiskBaseline?) in
                try token.check()
                try FileStorage.validateFileURL(url)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return (SearchWindowState(), nil)
                }
                let bytes = try self.fileAccess.readData(
                    url,
                    maximumBytes: 64 * 1024 * 1024,
                    permit: {
                        !token.isCancelled
                    }
                )
                let state = try PropertyListDecoder().decode(SearchWindowState.self, from: bytes.data)
                try state.validate()
                try token.check()
                return (state, bytes.baseline)
            }
            searchSettingsState = mergingSearchUserPreferences(state)
            mainWindow?.searchResults.setPreferences(searchSettingsState.results)
            searchSettingsBaseline = baseline
            searchSettingsReady = true
            searchSettingsError = nil
        }
        catch {
            // 无完整配置证据时保留磁盘内容，后续普通控件变化不能默默重建归档。
            searchSettingsReady = false
            searchSettingsError = "搜索设置未读取，原归档保留；可使用“重新保存设置”：" + error.localizedDescription
        }
    }

    /// 业务作用：合并未开始的配置保存，单一实际写入顺序保证旧历史不能越过新的删除或清空。
    /// 参数说明:
    /// - state: 当前窗口完整配置。
    /// 返回：记录最新配置并启动至多一个排空任务；未初始化或需显式重新保存时保留待写状态。
    func scheduleSearchSettings(_ state: SearchWindowState) {
        persistSearchUserPreferences(state)
        searchSettingsState = state
        pendingSearchSettings = state
        // 读取失败不授予覆盖资格；已有排空任务保持唯一写入顺序，新状态只替换尚未开始的候选。
        guard searchSettingsReady, searchSettingsURL != nil, searchSettingsTask == nil else {
            return
        }
        searchSettingsTask = Task {
            await drainSearchSettings()
        }
    }

    /// 业务作用：按已确认的磁盘基线顺序保存完整配置，实际失败停止后续覆盖并保留当前窗口原文。
    /// 参数说明: 无。
    /// 返回：所有已排队状态持久化后收回任务；失败在搜索反馈中保留原因并要求重新确认基线。
    func drainSearchSettings() async {
        defer {
            searchSettingsTask = nil
        }
        while let state = pendingSearchSettings, let url = searchSettingsURL {
            pendingSearchSettings = nil
            let expected = searchSettingsBaseline
            do {
                let baseline = try await searchSettingsIO.runCancellable {
                    token in
                    try state.validate()
                    try token.check()
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    let data = try encoder.encode(state)
                    // 原文预算之外再限制归档字节，编码放大不能把配置写入变成无界文件发布。
                    guard data.count <= 64 * 1024 * 1024 else {
                        throw NateError.message("搜索设置归档超过 64 MiB，未开始写入。")
                    }
                    // 配置也先按原基线发布完整文件；一次确认返回后，下一状态才取得新的基线。
                    return try self.fileAccess.save(
                        data,
                        to: url,
                        expected: expected,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                searchSettingsBaseline = baseline
                searchSettingsError = nil
            }
            catch {
                // 发布或同步失败时真实磁盘状态可能已改变，不能用旧基线盲目重试覆盖。
                searchSettingsReady = false
                searchSettingsError = "搜索设置未确认保存；可使用“重新保存设置”：" + error.localizedDescription
                findWindow?.feedback.stringValue += " · " + (searchSettingsError ?? "")
                return
            }
        }
    }

    /// 业务作用：用户明确确认重建配置后重新取得当前磁盘基线，仍不越过其它正在进行的设置写入。
    /// 参数说明:
    /// - state: 用户确认重新保存的当前完整设置。
    /// 返回：读取新基线后顺序保存；读取、容量或发布失败保留当前输入和磁盘归档。
    func resetSearchSettings(_ state: SearchWindowState) {
        // 基线重建不能与旧文件发布并行，否则确认的目标证据可能立刻被另一个设置动作替换。
        guard let url = searchSettingsURL, searchSettingsTask == nil else {
            findWindow?.feedback.stringValue = "搜索设置仍在保存，请等待后重试。"
            return
        }
        do {
            try state.validate()
        }
        catch {
            findWindow?.feedback.stringValue = error.localizedDescription
            return
        }
        searchSettingsReady = false
        persistSearchUserPreferences(state, replacingUnknown: true)
        searchSettingsState = state
        pendingSearchSettings = state
        searchSettingsTask = Task {
            do {
                let baseline = try await searchSettingsIO.readCancellable {
                    token -> DiskBaseline? in
                    try token.check()
                    try FileStorage.validateFileURL(url)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return nil
                    }
                    return try self.fileAccess.baseline(
                        url,
                        permit: {
                            !token.isCancelled
                        }
                    )
                }
                // 只有显式重新保存动作可以更换配置基线，普通历史删除不能授予覆盖未知归档的权限。
                searchSettingsBaseline = baseline
                searchSettingsReady = true
                await drainSearchSettings()
            }
            catch {
                searchSettingsTask = nil
                searchSettingsError = "搜索设置未重新保存：" + error.localizedDescription
                findWindow?.feedback.stringValue = searchSettingsError ?? ""
            }
        }
    }
}
