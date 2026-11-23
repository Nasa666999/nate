import AppKit
import NateCore

extension ThemePreferencesWindow {
    /// 业务作用：新主题以继承样式开始，命名和唯一身份只进入当前草稿。
    /// 参数说明:
    /// - sender: 当前明确的新建动作。
    /// 返回：容量允许且原草稿合法时建立新项，否则原库保持。
    @objc func newTheme(_ sender: Any?) {
        guard operation == nil else {
            return
        }
        do {
            try saveEditingStyle()
            let definition = try EditorThemeDefinition(name: uniqueName("新主题"))
            try append(try EditorThemeEntry(definition: definition))
        }
        catch {
            showFailure(error)
        }
    }

    /// 业务作用：复制主题保留完整配色并建立新身份，外部监视不因复制而隐式开启。
    /// 参数说明:
    /// - sender: 当前明确的复制动作。
    /// 返回：当前有效定义进入独立副本，原项与偏好保持不变。
    @objc func duplicateTheme(_ sender: Any?) {
        guard operation == nil else {
            return
        }
        do {
            try saveEditingStyle()
            guard
                let source = entries.first(where: {
                    $0.id == selectedID
                })
            else {
                throw NateError.message("请先选择要复制的主题。")
            }
            let definition = try EditorThemeDefinition(
                name: uniqueName("主题副本"),
                colors: source.definition.colors,
                kindStyles: source.definition.kindStyles,
                languageStyles: source.definition.languageStyles
            )
            try append(try EditorThemeEntry(definition: definition))
        }
        catch {
            showFailure(error)
        }
    }

    /// 业务作用：删除只移除当前草稿中的明确稳定项，不删除导入来源文件或已保存偏好。
    /// 参数说明:
    /// - sender: 当前明确的删除动作。
    /// 返回：当前草稿切回系统继承，应用前仍可通过取消保留原库。
    @objc func deleteTheme(_ sender: Any?) {
        guard operation == nil, let selectedID else {
            return
        }
        entries.removeAll {
            $0.id == selectedID
        }
        self.selectedID = nil
        editingID = nil
        reloadThemes()
    }

    /// 业务作用：主题应用必须先结束当前字段编辑并验证整库，非法草稿不能关闭窗口或覆盖原设置。
    /// 参数说明:
    /// - sender: 当前明确的应用动作。
    /// 返回：完整合法主题库作为唯一结果交给偏好来源复验，失败保留原草稿。
    @objc func applyDialog(_ sender: Any?) {
        guard operation == nil else {
            return
        }
        window?.makeFirstResponder(nil)
        do {
            try saveEditingStyle()
            let value = try EditorThemeLibrary(entries: entries, selectedID: selectedID)
            savedLibrary = value
            finishDialog(value)
        }
        catch {
            showFailure(error)
        }
    }

    /// 业务作用：取消丢弃所有主题草稿并撤销当前表单文件任务，原偏好不被触碰。
    /// 参数说明:
    /// - sender: 当前取消或窗口关闭动作。
    /// 返回：模态编辑结束且没有可应用结果。
    @objc func cancelDialog(_ sender: Any?) {
        finishDialog(nil)
    }

    /// 业务作用：新建和导入项先共同确认容量与名称，再一次性加入草稿。
    /// 参数说明:
    /// - entry: 已完成单项校验的独立主题。
    /// 返回：完整新库合法时加入并选中，失败不改变此前草稿。
    func append(_ entry: EditorThemeEntry) throws {
        let candidate = try EditorThemeLibrary(entries: entries + [entry], selectedID: entry.id)
        entries = candidate.entries
        selectedID = candidate.selectedID
        editingID = nil
        reloadThemes()
    }

    /// 业务作用：自动副本采用有限且不冲突的名称，原主题的名称与身份保持原状。
    /// 参数说明:
    /// - base: 当前明确新建或副本类型的短名称。
    /// 返回：当前有限草稿库中尚未使用的名称。
    func uniqueName(_ base: String) -> String {
        let existing = Set(
            entries.map {
                $0.definition.name
            }
        )
        if !existing.contains(base) {
            return base
        }
        var index = 2
        while existing.contains(base + " " + String(index)) {
            index += 1
        }
        return base + " " + String(index)
    }
}
