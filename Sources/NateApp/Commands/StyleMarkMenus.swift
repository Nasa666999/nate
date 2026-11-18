import AppKit
import NateCore
import NateUI

@MainActor
final class StyleMarkRuntime {
    var generation = UUID()
    var pending: UUID?

    /// 业务作用：样式匹配偏好拥有独立运行期身份，往返切换不能恢复旧样式任务的权限。
    /// 参数说明: 无。
    /// 返回：尚无待执行样式任务的运行期状态，不包含正文或持久配置副本。
    init() {}
}

enum StyleMarkAction: String {
    case all
    case selection
    case next
    case previous
    case clear
    case copy
}

extension ApplicationController {
    /// 业务作用：样式选项从当前完整配置读取，查找窗口未建立时也使用已恢复的用户偏好。
    /// 参数说明: 无。
    /// 返回：独立于查找表达式的大小写与整词选项。
    var styleMarkPreferences: StyleMarkPreferences {
        findWindow?.stylePreferences ?? searchSettingsState.styling
    }

    /// 业务作用：菜单按颜色分组暴露完整样式动作，用户不需要用查找颜色替代持久样式。
    /// 参数说明:
    /// - parent: 当前搜索主菜单。
    /// 返回：查找颜色与五组样式各有导航、清除和复制入口，样式匹配选项独立可见。
    func addStyleMarkMenus(to parent: NSMenu) {
        let marks = NSMenu(title: "颜色标记")
        add(marks, "标记页…", "findMark")
        add(marks, "下一个查找标记", "nextSearchMark")
        add(marks, "上一个查找标记", "previousSearchMark")
        add(marks, "清除查找颜色", "clearSearchMarks")
        add(marks, "复制查找标记文本", "copySearchMarks")
        marks.addItem(.separator())
        for (index, color) in [(1, "黄色"), (2, "绿色"), (3, "蓝色"), (4, "紫色"), (5, "粉色")] {
            let group = NSMenu(title: "样式 \(index)（\(color)）")
            for (title, action) in [
                ("标记所有匹配文本", "all"), ("仅标记选区或当前词", "selection"),
                ("下一个标记", "next"), ("上一个标记", "previous"),
                ("清除此样式", "clear"), ("复制此样式文本", "copy"),
            ] {
                add(group, title, "markStyle:\(index):\(action)")
            }
            attach(group, to: marks)
        }
        marks.addItem(.separator())
        add(marks, "样式匹配区分大小写", "styleMatchCase")
        add(marks, "样式匹配仅全词", "styleWholeWord")
        marks.addItem(.separator())
        add(marks, "清除五组样式", "clearStyleMarks")
        add(marks, "清除全部颜色标记", "clearAllMarks")
        add(marks, "复制五组标记文本", "copyStyleMarks")
        add(marks, "复制全部标记文本", "copyAllMarks")
        attach(marks, to: parent)
    }

    /// 业务作用：样式命令只接受固定颜色与固定动作，外来的长标识不变成新的正文或路径入口。
    /// 参数说明:
    /// - id: 菜单或快捷命令中的稳定样式标识。
    /// 返回：五组样式内的合法动作，不识别的标识为空。
    func styleMarkAction(for id: String) -> (style: DocumentMarkStyle, action: StyleMarkAction)? {
        guard id.hasPrefix("markStyle:"), id.utf8.count < 64 else {
            return nil
        }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let index = Int(parts[1]), (1...5).contains(index),
            let style = DocumentMarkStyle(rawValue: index),
            let action = StyleMarkAction(rawValue: String(parts[2]))
        else {
            return nil
        }
        return (style, action)
    }

    /// 业务作用：颜色操作固定当前实际编辑视图，元数据修改受保护态约束，读取与导航仍可在保护态使用。
    /// 参数说明:
    /// - modifying: 是否准备修改颜色集合。
    /// 返回：正文、视图与输入上下文一致时提供当前目标，不满足门禁时不提交或丢弃候选。
    func currentMarkEditor(modifying: Bool) -> (
        document: WorkspaceDocument, window: EditorWindow, editor: EditorView
    )? {
        // 标记不能借菜单焦点提交候选，也不能从旧克隆视图给另一个文档套用范围。
        guard !closing, let document = active, let window = mainWindow,
            window.editor.document === document.buffer, !document.closing,
            !window.hasMarkedEditorInput, findWindow?.isEditingInput != true,
            !modifying || !document.buffer.isEditingSuspended
        else {
            return nil
        }
        return (document, window, window.editor)
    }

    /// 业务作用：样式菜单显式反映当前选择、颜色内容和只读操作能力，不在验证菜单时扫描正文或访问文件。
    /// 参数说明:
    /// - item: 当前需要验证的菜单项。
    /// - id: 该项的固定业务标识。
    /// 返回：属于颜色菜单时给出可用性，其他菜单返回空以继续原验证流程。
    func validateStyleMarkMenu(_ item: NSMenuItem, id: String) -> Bool? {
        if id == "styleMatchCase" || id == "styleWholeWord" {
            item.state =
                (id == "styleMatchCase" ? styleMarkPreferences.caseSensitive : styleMarkPreferences.wholeWord)
                ? .on : .off
            return !closing
        }
        if id.hasPrefix("markStyle:") {
            guard let command = styleMarkAction(for: id),
                let context = currentMarkEditor(
                    modifying: [.all, .selection, .clear].contains(command.action)
                )
            else {
                return false
            }
            switch command.action {
            case .all: return context.editor.viewSelections.count == 1
            case .selection:
                return !context.editor.viewSelections.isEmpty
                    && context.editor.viewSelections.count <= 100_000
            case .clear:
                return !context.document.buffer.marks.ranges(for: command.style).isEmpty
                    || markSearchGeneration == queryGeneration && searchTask != nil
            case .next, .previous, .copy:
                return !context.document.buffer.marks.ranges(for: command.style).isEmpty
            }
        }
        guard
            [
                "findMark", "nextSearchMark", "previousSearchMark", "clearSearchMarks", "copySearchMarks",
                "clearStyleMarks", "clearAllMarks", "copyStyleMarks", "copyAllMarks",
            ].contains(id)
        else {
            return nil
        }
        guard let context = currentMarkEditor(modifying: id.hasPrefix("clear")) else {
            return false
        }
        if id == "findMark" {
            return true
        }
        if id.hasPrefix("clear"), markSearchGeneration == queryGeneration, searchTask != nil {
            return true
        }
        let styles =
            id.contains("Style")
            ? DocumentMarkStyle.allCases.filter {
                $0 != .search
            }
            : id.contains("All") ? DocumentMarkStyle.allCases : [.search]
        return styles.contains {
            !context.document.buffer.marks.ranges(for: $0).isEmpty
        }
    }

    /// 业务作用：样式匹配偏好单独保存并撤销旧样式计划，不把改变样式设置等同于改变普通查找条件。
    /// 参数说明:
    /// - id: 大小写或整词选项的固定命令。
    /// 返回：对应偏好切换并进入受保护配置保存，旧样式任务的往返设置资格失效。
    func toggleStyleMarkPreference(_ id: String) {
        var preferences = styleMarkPreferences
        if id == "styleMatchCase" {
            preferences.caseSensitive.toggle()
        }
        else if id == "styleWholeWord" {
            preferences.wholeWord.toggle()
        }
        else {
            return
        }
        // 先撤销旧样式配置身份再取消对应计划，普通查找不依赖这份匹配偏好身份。
        styleMarks.generation = UUID()
        if styleMarks.pending == queryGeneration {
            cancelSearchMarking()
        }
        findWindow?.setStylePreferences(preferences)
        var state = findWindow?.state ?? searchSettingsState
        state.styling = preferences
        // 菜单配置仍通过已确认的归档基线顺序保存，不能授予覆盖未知设置的资格。
        scheduleSearchSettings(state)
    }
}
