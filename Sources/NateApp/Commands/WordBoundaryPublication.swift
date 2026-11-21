import AppKit
import NateCore
import NateUI

extension ApplicationController {
    /// 业务作用：用户明确应用完整词规则后同步视图和搜索入口，旧计算先失去发布权限。
    /// 参数说明:
    /// - settings: 完整合法的默认及附加字符规则。
    /// 返回：归档编码与容量满足时保存并应用；关闭或编码失败保留原规则。
    func saveWordBoundaries(_ settings: WordBoundarySettings) throws {
        guard !closing else {
            throw NateError.message("工作区正在关闭，词边界设置未保存。")
        }
        let data = try JSONEncoder().encode(WordBoundaryPreferenceValue(format: 1, settings: settings))
        guard data.count <= 4096 else {
            throw NateError.message("完整词边界配置超过 4 KiB。")
        }
        let runtime = wordPreferences
        let domain = runtime.defaults ?? .standard
        // 旧任务的查询表达式或整词资格已经失效，先收回权限再发布新规则。
        cancelQuickFind()
        cancelMultipleSelection()
        cancelIncrementalSearch(resetOrigin: true)
        domain.set(data, forKey: "wordBoundarySettings")
        runtime.settings = settings
        runtime.loaded = true
        runtime.warning = nil
        runtime.sourceDomain = domain
        runtime.source = data as NSData
        runtime.generation = UUID()
        mainWindow?.setWordBoundaries(settings)
        findWindow?.setWordBoundaries(settings)
        refreshVisibleIncrementalHighlights()
    }

    /// 业务作用：词字符表单只持有打开时的偏好来源，候选、关闭或外部更改不能被旧草稿覆盖。
    /// 参数说明: 无。
    /// 返回：明确应用且原来源仍一致时保存完整规则，取消不写入。
    func showWordBoundaryPreferences() {
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let initial = currentWordBoundaries()
        let runtime = wordPreferences
        let domain = runtime.defaults ?? .standard
        let generation = runtime.generation
        let source = domain.object(forKey: "wordBoundarySettings") as? NSObject
        guard let selected = WordBoundaryDialog.choose(initial: initial, warning: runtime.warning), !closing
        else {
            return
        }
        let current = domain.object(forKey: "wordBoundarySettings") as? NSObject
        // 配置往返、偏好域切换及原字节变化均撤销本次表单的写入资格。
        guard runtime.generation == generation, (runtime.defaults ?? .standard) === domain,
            source.map({
                $0.isEqual(current)
            }) ?? (current == nil)
        else {
            runtime.loaded = false
            mainWindow?.status.stringValue = "词边界设置已改变，旧表单未保存，请重新打开。"
            return
        }
        do {
            try saveWordBoundaries(selected)
            mainWindow?.status.stringValue = "词字符规则已应用，已有正文和选区保持原状。"
        }
        catch {
            mainWindow?.status.stringValue = "词边界设置未保存：" + error.localizedDescription
        }
    }
}

struct WordBoundaryPreferenceValue: Codable {
    let format: Int
    let settings: WordBoundarySettings
}
