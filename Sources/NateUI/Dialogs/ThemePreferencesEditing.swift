import AppKit
import NateCore
import NateSyntax

extension ThemePreferencesWindow {
    /// 业务作用：主题选择列表反映完整草稿库，系统继承始终是独立可选项。
    /// 参数说明: 无。
    /// 返回：当前稳定身份对应的主题与编辑字段同步安装，不改变偏好。
    func reloadThemes() {
        updating = true
        themes.removeAllItems()
        themes.addItem(withTitle: "系统与原资源样式")
        for entry in entries {
            themes.addItem(withTitle: entry.definition.name)
            themes.lastItem?.representedObject = entry.id.uuidString
        }
        let index = selectedID.flatMap {
            id in
            entries.firstIndex(where: {
                $0.id == id
            })
        }
        themes.selectItem(
            at: index.map {
                $0 + 1
            } ?? 0
        )
        editingID = selectedID
        let entry = entries.first(where: {
            $0.id == editingID
        })
        nameField.stringValue = entry?.definition.name ?? "系统与原资源样式"
        nameField.isEnabled = entry != nil && operation == nil && operationID == nil
        sourceLabel.stringValue =
            entry?.sourcePath.map {
                "本地来源：" + $0
            } ?? "此主题没有外部来源。导入文件后可明确启用热更新。"
        watch.state = entry?.watchesSource == true ? .on : .off
        watch.isEnabled = entry?.sourcePath != nil && operation == nil && operationID == nil
        editingKey = nil
        editingScope = scopes.selectedItem?.representedObject as? String ?? "surface"
        updating = false
        reloadStyles()
        updateManagementButtons()
    }

    /// 业务作用：作用范围固定完整样式目录，切换语言不会复用另一语言的颜色字段。
    /// 参数说明: 无。
    /// 返回：当前主题和作用范围的有限目录建立，首项完整载入。
    func reloadStyles() {
        let definition = entries.first(where: {
            $0.id == editingID
        })?.definition
        if editingScope == "surface" {
            let names: [EditorThemeColorRole: String] = [
                .background: "正文背景", .foreground: "默认正文", .caret: "光标",
                .selectionBackground: "选择背景", .selectionForeground: "选择文字",
                .currentLineBackground: "当前行背景", .lineNumber: "行号", .gutterBackground: "边栏背景",
                .whitespace: "空白与控制符", .indentGuide: "缩进参考线", .longLineGuide: "长行参考线",
                .bracketMatchBackground: "匹配括号背景", .bracketMismatchBackground: "未匹配括号背景",
                .foldMarker: "折叠标记", .bookmark: "书签", .modificationSaved: "已保存修改标记",
                .modificationUnsaved: "修改位置标记", .linkForeground: "链接",
            ]
            choices = EditorThemeColorRole.allCases.filter {
                ![.indentGuide, .longLineGuide, .modificationSaved, .linkForeground].contains($0)
            }.map {
                SyntaxThemeChoice(key: $0.rawValue, name: names[$0] ?? $0.rawValue)
            }
        }
        else if editingScope == "kinds" {
            choices = SyntaxThemeCatalog.choices(language: nil)
        }
        else {
            let id = String(editingScope.dropFirst("language:".count))
            choices = SyntaxThemeCatalog.choices(
                language: languages.first(where: {
                    $0.id == id
                }),
                userLanguage: userLanguages[id],
                additional: Set((definition?.languageStyles[id] ?? [:]).keys),
                names: styleNames[id] ?? [:]
            )
        }
        updating = true
        styleTable.reloadData()
        if !choices.isEmpty {
            styleTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updating = false
        loadStyle(at: choices.isEmpty ? -1 : 0)
    }

    /// 业务作用：单项编辑目标与完整稳定主题身份绑定，系统继承模式不能产生虚构覆盖。
    /// 参数说明:
    /// - index: 当前明确目录位置。
    /// 返回：合法项载入颜色和字体草稿；没有明确目标时停用属性输入。
    func loadStyle(at index: Int) {
        guard choices.indices.contains(index),
            let entry = entries.first(where: {
                $0.id == editingID
            })
        else {
            editingKey = nil
            fields.load(EditorThemeStyle(), colorOnly: editingScope == "surface", editable: false)
            return
        }
        let key = choices[index].key
        editingKey = key
        let style: EditorThemeStyle
        if editingScope == "surface" {
            style =
                entry.definition.colors[key].flatMap {
                    try? EditorThemeStyle(foreground: $0)
                } ?? EditorThemeStyle()
        }
        else if editingScope == "kinds" {
            style = entry.definition.kindStyles[key] ?? EditorThemeStyle()
        }
        else {
            let id = String(editingScope.dropFirst("language:".count))
            style = entry.definition.languageStyles[id]?[key] ?? EditorThemeStyle()
        }
        fields.load(
            style,
            colorOnly: editingScope == "surface",
            editable: operation == nil && operationID == nil
        )
    }

    /// 业务作用：名称、来源和当前样式先共同验证再替换内存草稿，任何非法字段保留此前完整定义。
    /// 参数说明: 无。
    /// 返回：完整合法草稿原子进入当前主题项；重名、超量或字段非法时抛错而不丢失输入。
    func saveEditingStyle() throws {
        guard let id = editingID,
            let index = entries.firstIndex(where: {
                $0.id == id
            }), let key = editingKey
        else {
            return
        }
        let old = entries[index]
        var colors = old.definition.colors
        var kinds = old.definition.kindStyles
        var languages = old.definition.languageStyles
        let value = try fields.value()
        if editingScope == "surface" {
            colors[key] = value.foreground
        }
        else if editingScope == "kinds" {
            kinds[key] = value == EditorThemeStyle() ? nil : value
        }
        else {
            let language = String(editingScope.dropFirst("language:".count))
            var group = languages[language] ?? [:]
            group[key] = value == EditorThemeStyle() ? nil : value
            languages[language] = group.isEmpty ? nil : group
        }
        let definition = try EditorThemeDefinition(
            name: nameField.stringValue,
            colors: colors,
            kindStyles: kinds,
            languageStyles: languages
        )
        let entry = try EditorThemeEntry(
            id: old.id,
            definition: definition,
            sourcePath: old.sourcePath,
            watchesSource: old.sourcePath != nil && watch.state == .on
        )
        var candidate = entries
        candidate[index] = entry
        _ = try EditorThemeLibrary(entries: candidate, selectedID: selectedID)
        entries = candidate
        themes.itemArray.first(where: {
            $0.representedObject as? String == id.uuidString
        })?.title = definition.name
    }

    /// 业务作用：主题切换先保存旧项合法草稿，非法输入不能被另一主题覆盖。
    /// 参数说明:
    /// - sender: 当前主题选择控件。
    /// 返回：合法旧草稿保存后切换稳定目标；失败保留原主题和输入。
    @objc func themeChanged(_ sender: NSPopUpButton) {
        guard !updating, operation == nil else {
            return
        }
        let next = (sender.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
        do {
            try saveEditingStyle()
            selectedID = next
            reloadThemes()
        }
        catch {
            showFailure(error)
            let old = entries.firstIndex(where: {
                $0.id == selectedID
            })
            sender.selectItem(
                at: old.map {
                    $0 + 1
                } ?? 0
            )
        }
    }

    /// 业务作用：作用范围改变前固定旧样式，主题颜色不会因语言目录切换而丢失。
    /// 参数说明:
    /// - sender: 当前整体、通用或语言范围控件。
    /// 返回：合法草稿保存后载入新目录，非法草稿原地保留。
    @objc func scopeChanged(_ sender: NSPopUpButton) {
        guard !updating, operation == nil else {
            return
        }
        let next = sender.selectedItem?.representedObject as? String ?? "surface"
        do {
            try saveEditingStyle()
            editingScope = next
            editingKey = nil
            reloadStyles()
        }
        catch {
            showFailure(error)
            sender.select(
                sender.itemArray.first(where: {
                    $0.representedObject as? String == editingScope
                })
            )
        }
    }
}
