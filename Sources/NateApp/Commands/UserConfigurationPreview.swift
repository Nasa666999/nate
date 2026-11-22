import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：在实际偏好保持不变时展示逐字段差异，明确应用才进入来源复验和整份发布。
    /// 参数说明: 无。
    /// 返回：明确应用后完整采用候选，取消只清除预览；失效来源或界面失败由调用方反馈。
    func showUserConfigurationPreview() throws {
        let runtime = userConfiguration
        guard let candidate = runtime.preview, let source = runtime.source else {
            throw NateError.message("没有可审阅的完整用户配置。")
        }
        let existing = Dictionary(
            uniqueKeysWithValues: source.entries.map {
                ($0.key, $0.value)
            }
        )
        var sections: [String] = []
        for entry in candidate.entries where existing[entry.key] != entry.value {
            sections.append(
                "【" + UserConfigurationLabels.title(entry.key) + " · " + entry.key + "】\n当前：\n"
                    + UserConfigurationLabels.detail(existing[entry.key] ?? .unset)
                    + "\n导入：\n" + UserConfigurationLabels.detail(entry.value)
            )
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 660, height: 390))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 390)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        text.string = sections.isEmpty ? "当前字段与导入配置一致。" : sections.joined(separator: "\n\n")
        text.setAccessibilityLabel("用户配置完整差异预览")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 660, height: 390))
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let alert = NSAlert()
        alert.messageText = "导入用户配置"
        alert.informativeText =
            "来源：" + (runtime.previewName ?? "已读取配置") + "\n"
            + "以下显示差异；确认后完整应用 \(candidate.entries.count) 项偏好。正文、最近文件、查询与历史、剪贴板内容、主题资源、UDL、快捷键、宏和运行命令不在此配置包内。"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "应用完整配置")
        alert.addButton(withTitle: "取消")
        runtime.previewWindow = alert.window
        defer {
            runtime.previewWindow = nil
            clearUserConfigurationPreview()
        }
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        try applyUserConfigurationPreview()
    }
}

private enum UserConfigurationLabels {
    static let names: [String: String] = [
        "adaptClipboardLineEndings": "粘贴换行适配",
        "autosaveEnabled": "每秒自动保存",
        "completion.enabled": "自动补全",
        "completion.words": "正文词补全",
        "completion.language": "语言资源补全",
        "completion.tab": "Tab 确认补全",
        "completion.enter": "回车确认补全",
        "completion.threshold": "补全起始长度",
        "copyLineWithoutSelection": "无选区复制与剪切整行",
        "dateTimeSettings": "日期时间格式",
        "delimiterSelectionSettings": "分隔符选择",
        "documentTabLayout": "标签栏布局",
        "editorDisplaySettings": "字体、外观与显示",
        "fileOpeningSettings": "文件与新建默认设置",
        "fontSize": "既有字号偏好",
        "hexConversionOptions": "HEX 转换格式",
        "incrementalSearch.caseSensitive": "增量搜索大小写",
        "incrementalSearch.wholeWord": "增量搜索整词",
        "incrementalSearch.highlightAll": "增量搜索全部高亮",
        "incrementalSearch.wrap": "增量搜索循环",
        "indentationSettings": "自动缩进与退格",
        "languageTabSettings": "全局和语言 Tab 规则",
        "multipleSelectionOptions": "匹配多选",
        "pairInsertionSettings": "括号与引号配对",
        "printSettings": "打印设置",
        "saveBackupPolicy": "保存前备份",
        "searchUserPreferences": "搜索行为、输入字体与结果呈现",
        "selectedTextHighlightOptions": "选中文字智能高亮",
        "showSymbols": "既有符号显示偏好",
        "structure.sortByName": "函数列表排序",
        "webSearchSettings": "搜索引擎与固定网址模板",
        "wordBoundarySettings": "词字符与边界",
        "wrapLines": "既有自动换行偏好",
    ]

    /// 业务作用：配置差异使用可识别的设置名称，同时保留真实配置键供精确核对。
    /// 参数说明:
    /// - key: 已通过白名单的稳定键。
    /// 返回：对应业务设置名称，未命名键保留原名。
    static func title(_ key: String) -> String {
        names[key] ?? key
    }

    /// 业务作用：配置预览只解释字段数据，网址、路径和命令外观均不取得执行或访问权限。
    /// 参数说明:
    /// - value: 完整字段值，原域损坏内容仍保持独立来源。
    /// 返回：可选择的完整数值或 JSON 文本；无法解释的原归档只说明实际类型与字节数。
    static func detail(_ value: UserPreferenceValue) -> String {
        switch value {
        case .unset: return "未设置（使用默认规则或既有兼容字段）"
        case .boolean(let flag): return flag ? "开启" : "关闭"
        case .integer(let number): return String(number)
        case .decimal(let number): return String(number)
        case .text(let text): return String(reflecting: text)
        case .bytes(let data):
            guard (try? UserConfigurationJSON.validate(data)) != nil,
                let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                let formatted = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
                )
            else {
                return "原归档无法解释（\(data.count) 字节）"
            }
            return String(decoding: formatted, as: UTF8.self)
        }
    }
}
