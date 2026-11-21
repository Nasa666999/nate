import AppKit
import NateCore

@MainActor
public enum FileOpeningDialog {
    /// 业务作用：以独立草稿配置新建文档和文件对话框入口，取消不改变偏好或历史。
    /// 参数说明:
    /// - initial: 已验证的完整文件偏好。
    /// - languages: 当前已载入的稳定语言身份及显示名称。
    /// - warning: 原归档不能读取时持续展示的原因。
    /// 返回：明确应用且全部字段合法时交付完整偏好，取消返回空。
    public static func choose(
        initial: FileOpeningSettings,
        languages: [(id: String, name: String)],
        warning: String?
    ) -> FileOpeningSettings? {
        let form = FileOpeningForm(initial: initial, languages: languages, warning: warning)
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form.stack)
        let alert = NSAlert()
        alert.messageText = "文件与新建默认设置"
        alert.informativeText = "新建文档使用 UTF-8（无 BOM）。默认语言和换行只影响以后新建的文档；已有正文与保存编码保持原状。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.stack.frame = NSRect(x: 8, y: 8, width: 480, height: max(340, form.stack.fittingSize.height))
            background.setFrameSize(NSSize(width: 496, height: form.stack.frame.height + 16))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            alert.window.makeFirstResponder(nil)
            do {
                return try form.settings()
            }
            catch {
                form.status.stringValue = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class FileOpeningForm: NSObject {
    let stack = NSStackView()
    let language = NSPopUpButton()
    let ending = NSPopUpButton()
    let directory = NSPopUpButton()
    let custom: NSTextField
    let recent: NSTextField
    let folder = NSButton(title: "选择目录…", target: nil, action: nil)
    let status: NSTextField
    private var languageIDs: [String]
    private let directoryModes: [FileDirectoryMode] = [.lastUsed, .currentDocument, .custom]

    /// 业务作用：固定菜单身份并保留未载入语言与停用目录草稿，资源暂时缺席不丢失用户选择。
    /// 参数说明:
    /// - initial: 完整文件偏好初值。
    /// - languages: 当前可选择的语言身份和名称。
    /// - warning: 需要保留在表单中的读取原因。
    /// 返回：只建立内存草稿，不访问目录或保存设置。
    init(initial: FileOpeningSettings, languages: [(id: String, name: String)], warning: String?) {
        languageIDs = languages.map(\.id)
        custom = NSTextField(string: initial.customDirectory)
        recent = NSTextField(string: String(initial.recentFileLimit))
        status = NSTextField(wrappingLabelWithString: warning ?? "")
        super.init()
        language.addItems(withTitles: languages.map(\.name))
        if let index = languageIDs.firstIndex(where: {
            $0.utf8.elementsEqual(initial.defaultLanguage.utf8)
        }) {
            language.selectItem(at: index)
        }
        else {
            language.addItem(withTitle: "未载入：" + initial.defaultLanguage)
            languageIDs.append(initial.defaultLanguage)
            language.selectItem(at: languageIDs.count - 1)
        }
        ending.addItems(withTitles: LineEnding.allCases.map(\.rawValue))
        ending.selectItem(at: LineEnding.allCases.firstIndex(of: initial.lineEnding) ?? 0)
        directory.addItems(withTitles: ["上次选择的目录", "当前文档所在目录", "自定义目录"])
        directory.selectItem(at: directoryModes.firstIndex(of: initial.directoryMode) ?? 0)
        directory.target = self
        directory.action = #selector(updateDirectory)
        folder.target = self
        folder.action = #selector(chooseDirectory)
        language.setAccessibilityLabel("新建默认语言")
        ending.setAccessibilityLabel("新建默认换行")
        directory.setAccessibilityLabel("文件对话框默认目录")
        custom.setAccessibilityLabel("自定义默认目录路径")
        recent.setAccessibilityLabel("最近文件数量上限")
        status.textColor = .systemOrange
        status.preferredMaxLayoutWidth = 480
        let pathRow = NSStackView(views: [custom, folder])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        let note = NSTextField(
            wrappingLabelWithString:
                "最近文件为 0–200 条，0 表示停用记录和显示。默认目录只在打开或另存为对话框中使用，不在载入偏好时访问磁盘。未载入的默认语言暂用纯文本，原选择仍保留。"
        )
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 480
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [
            NSTextField(labelWithString: "新建文档语言"), language,
            NSTextField(labelWithString: "新建文档换行"), ending,
            NSTextField(labelWithString: "打开与另存为的起始目录"), directory,
            pathRow, NSTextField(labelWithString: "最近文件数量"), recent, note, status,
        ] {
            stack.addArrangedSubview(view)
        }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        custom.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateDirectory()
    }

    /// 业务作用：只有自定义模式才允许编辑目录，切换来源不删除尚未应用的路径草稿。
    /// 参数说明: 无。
    /// 返回：更新表单可编辑状态，不访问或更改目录。
    @objc private func updateDirectory() {
        let enabled = directory.indexOfSelectedItem == 2
        custom.isEnabled = enabled
        folder.isEnabled = enabled
    }

    /// 业务作用：用户明确选择后只更新独立目录草稿，取消选择不改变原路径。
    /// 参数说明: 无。
    /// 返回：确认的本地文件目录进入草稿，尚不取得偏好保存权限。
    @objc private func chooseDirectory() {
        let chooser = NSOpenPanel()
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = false
        guard chooser.runModal() == .OK, let url = chooser.url, url.isFileURL else {
            return
        }
        custom.stringValue = url.path
    }

    /// 业务作用：按固定菜单身份和完整数量建立偏好，不能把无效选择或部分数字当作合法配置。
    /// 参数说明: 无。
    /// 返回：全部字段有效时交付完整设置，否则保留草稿并说明原因。
    func settings() throws -> FileOpeningSettings {
        let count = recent.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !count.isEmpty, count.utf8.count <= 3,
            count.utf8.allSatisfy({
                $0 >= 48 && $0 <= 57
            }), let limit = Int(count), languageIDs.indices.contains(language.indexOfSelectedItem),
            directoryModes.indices.contains(directory.indexOfSelectedItem),
            LineEnding.allCases.indices.contains(ending.indexOfSelectedItem)
        else {
            throw NateError.message("请选择完整语言、换行与目录来源，并输入 0–200 的整数。")
        }
        return try FileOpeningSettings(
            defaultLanguage: languageIDs[language.indexOfSelectedItem],
            lineEnding: LineEnding.allCases[ending.indexOfSelectedItem],
            recentFileLimit: limit,
            directoryMode: directoryModes[directory.indexOfSelectedItem],
            customDirectory: custom.stringValue
        )
    }
}
