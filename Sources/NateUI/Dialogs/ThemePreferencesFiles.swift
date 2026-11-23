import AppKit
import NateCore
import NateSyntax
import UniformTypeIdentifiers

extension ThemePreferencesWindow {
    /// 业务作用：主题导入只读取用户明确选择的独立文件，解析完成后加入可撤销的窗口草稿。
    /// 参数说明:
    /// - sender: 当前明确的导入动作。
    /// 返回：完整新主题进入草稿并提供兼容说明，取消或失败不改变偏好。
    @objc func importTheme(_ sender: Any?) {
        guard operation == nil else {
            return
        }
        do {
            try saveEditingStyle()
        }
        catch {
            showFailure(error)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入 Nate 或 Notepad++ 主题"
        panel.allowedContentTypes = [.json, .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let request = UUID()
        operationID = request
        setBusy(true)
        operation = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.operationID == request {
                    self.operationID = nil
                    self.operation = nil
                    self.setBusy(false)
                }
            }
            do {
                let imported = try await self.importer(url)
                guard !Task.isCancelled, self.operationID == request, self.isRunning else {
                    return
                }
                var definition = imported.definition
                if self.entries.contains(where: {
                    $0.definition.name == definition.name
                }) {
                    definition = try EditorThemeDefinition(
                        name: self.uniqueName("导入主题"),
                        colors: definition.colors,
                        kindStyles: definition.kindStyles,
                        languageStyles: definition.languageStyles
                    )
                }
                try self.append(try EditorThemeEntry(definition: definition, sourcePath: url.path))
                self.compatibilityReports = imported.reports
                if imported.omittedReportCount > 0 {
                    self.compatibilityReports.append("另有 \(imported.omittedReportCount) 项同类字段说明未展开。")
                }
                self.reportsButton.isEnabled = !self.compatibilityReports.isEmpty
                self.status.textColor =
                    self.compatibilityReports.isEmpty ? .secondaryLabelColor : .systemOrange
                self.status.stringValue =
                    "已读入主题草稿 · " + definition.name
                    + (self.compatibilityReports.isEmpty ? "" : "；请查看导入说明。")
            }
            catch is CancellationError {
                return
            }
            catch {
                guard self.operationID == request, self.isRunning else {
                    return
                }
                self.showFailure(error)
            }
        }
    }

    /// 业务作用：导出固定当前完整主题草稿，目标由系统保存面板明确确认，与原导入来源及正文分别持有。
    /// 参数说明:
    /// - sender: 当前明确的导出动作。
    /// 返回：完整独立 JSON 交给受保护写入；取消、目标占用或失败保持原偏好和主题。
    @objc func exportTheme(_ sender: Any?) {
        guard operation == nil else {
            return
        }
        let definition: EditorThemeDefinition
        do {
            try saveEditingStyle()
            guard
                let entry = entries.first(where: {
                    $0.id == selectedID
                })
            else {
                throw NateError.message("请先选择要导出的明确主题。")
            }
            definition = entry.definition
        }
        catch {
            showFailure(error)
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出独立 Nate 主题"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue =
            definition.name.replacingOccurrences(of: "/", with: "_") + ".nate-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let request = UUID()
        operationID = request
        setBusy(true)
        operation = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.operationID == request {
                    self.operationID = nil
                    self.operation = nil
                    self.setBusy(false)
                }
            }
            do {
                try await self.exporter(definition, url)
                guard !Task.isCancelled, self.operationID == request, self.isRunning else {
                    return
                }
                self.status.textColor = .secondaryLabelColor
                self.status.stringValue = "完整主题已导出 · " + url.lastPathComponent
            }
            catch is CancellationError {
                return
            }
            catch {
                guard self.operationID == request, self.isRunning else {
                    return
                }
                self.showFailure(error)
            }
        }
    }

    /// 业务作用：外部主题无法映射的字段逐项可查看，不用一个笼统成功提示掩盖兼容边界。
    /// 参数说明:
    /// - sender: 当前明确的兼容说明动作。
    /// 返回：只读有限说明窗口，不修改定义或当前偏好。
    @objc func showReports(_ sender: Any?) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.string = compatibilityReports.joined(separator: "\n")
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let alert = NSAlert()
        alert.messageText = "主题导入说明"
        alert.informativeText = "配色定义与语言关键字、独立标记设置及其它界面资源分别管理。导出采用 Nate 主题格式。"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "关闭")
        _ = alert.runModal()
    }

    /// 业务作用：主题文件任务期间冻结可变草稿，取消始终保留，迟到结果不能写入新的编辑目标。
    /// 参数说明:
    /// - busy: 是否有当前表单持有的文件任务。
    /// 返回：主题、范围和属性控件与当前任务资格一致。
    func setBusy(_ busy: Bool) {
        themes.isEnabled = !busy
        scopes.isEnabled = !busy
        nameField.isEnabled = !busy && editingID != nil
        watch.isEnabled =
            !busy
            && entries.contains(where: {
                $0.id == editingID && $0.sourcePath != nil
            })
        updateManagementButtons()
        if let editingKey,
            let index = choices.firstIndex(where: {
                $0.key == editingKey
            })
        {
            loadStyle(at: index)
        }
    }

    /// 业务作用：管理入口只在当前有明确目标和剩余容量时启用，系统继承不冒充可导出的命名主题。
    /// 参数说明: 无。
    /// 返回：管理按钮与当前完整草稿及文件任务一致。
    func updateManagementButtons() {
        let busy = operation != nil || operationID != nil
        for button in managedButtons {
            var enabled = !busy
            if button.action == #selector(newTheme(_:)) || button.action == #selector(importTheme(_:)) {
                enabled = enabled && entries.count < 32
            }
            else if button.action == #selector(duplicateTheme(_:)) {
                enabled = enabled && selectedID != nil && entries.count < 32
            }
            else if button.action == #selector(deleteTheme(_:)) || button.action == #selector(exportTheme(_:))
            {
                enabled = enabled && selectedID != nil
            }
            button.isEnabled = enabled
        }
    }
}
