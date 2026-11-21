import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：固定真实正文中的单一连续选区或完整词，构造一次明确网络搜索的完整目标。
    /// 参数说明: 无。
    /// 返回：原文和目标均完整有效的网页 URL；焦点、形态、候选、容量或来源不足时拒绝整个动作。
    func preparedWebSearchURL() throws -> URL {
        guard let (document, _, editor) = quickFindContext(), editor.viewSelections.count == 1,
            let selection = editor.viewSelections.first, selection.virtualColumn == 0,
            editor.viewSelectionState?.shape == .stream
        else {
            throw NateError.message("网络搜索需要当前正文中的单一连续选区或光标，不能使用多选区、矩形或未确认的输入。")
        }
        let snapshot = document.buffer.snapshot
        let range: ByteRange
        if selection.range.isEmpty {
            switch snapshot.text.wordSelection(
                at: selection.head,
                maximumScalars: 16_384,
                wordBoundaries: editor.wordBoundaries
            ) {
            case .word(let word): range = word
            case .noWord: throw NateError.message("光标位置没有可搜索的完整词，请明确选择查询文字。")
            case .exceedsLimit: throw NateError.message("当前词超过网络搜索容量，未使用截断查询。")
            }
        }
        else {
            range = selection.range
        }
        // 原范围先整体确认再复制，不能把半个标量、超长选区或不存在的正文当成网络查询。
        guard range.lower >= 0, range.upper <= snapshot.text.byteCount, range.count <= 16_384,
            snapshot.text.isBoundary(range.lower), snapshot.text.isBoundary(range.upper)
        else {
            throw NateError.message("网络查询须为最多 16 KiB 的完整原文，未打开截断内容。")
        }
        let settings = currentWebSearchSettings()
        // 原引擎归档失去完整证据时不能把查询改投默认服务，用户须先明确保存有效目标。
        guard webSearch.warning == nil else {
            throw NateError.message("搜索引擎设置无法完整读取，请在“搜索引擎”中确认并应用后再执行。")
        }
        return try settings.url(for: snapshot.text.text(in: range))
    }

    /// 业务作用：只有明确菜单动作通过全部正文与目标门禁后，才把固定网址交给系统浏览器。
    /// 参数说明: 无。
    /// 返回：成功交付时反馈目标主机，失败保留正文、历史、选区与偏好且不记录查询原文。
    func searchOnInternet() {
        do {
            let url = try preparedWebSearchURL()
            // 构造和交付间不等待或重入，来源检查与实际打开属于同一明确用户动作。
            guard webSearch.openURL(url) else {
                throw NateError.message("系统未能打开默认浏览器。")
            }
            mainWindow?.status.stringValue = "网络搜索已交给默认浏览器 · " + (url.host ?? "")
        }
        catch {
            mainWindow?.status.stringValue = "网络搜索未执行：" + error.localizedDescription
        }
    }

    /// 业务作用：菜单显示只核对正文控制来源与选择形态，不提前提取或发送查询。
    /// 参数说明: 无。
    /// 返回：允许明确发起网络搜索时为真，实际动作仍完整复验范围和目标。
    func webSearchAvailable() -> Bool {
        guard let (_, _, editor) = quickFindContext() else {
            return false
        }
        return editor.viewSelections.count == 1 && editor.viewSelections.first?.virtualColumn == 0
            && editor.viewSelectionState?.shape == .stream
    }
}
