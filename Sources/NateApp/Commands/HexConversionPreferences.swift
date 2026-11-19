import AppKit
import NateCore
import NateStorage

private struct HexPreferencesArchive: Codable {
    let format: Int
    let options: HexEncodingOptions
}

extension ApplicationController {
    /// 业务作用：HEX 格式按需读取，损坏或未知偏好保留原值并明确采用默认显示规则。
    /// 参数说明: 无。
    /// 返回：当前完整合法选项；不自动写回未能解释的归档。
    func currentHexOptions() -> HexEncodingOptions {
        let runtime = textTools, domain = textTools.hexDefaults ?? .standard
        runtime.hexOptions = HexEncodingOptions()
        runtime.hexWarning = nil
        guard let object = domain.object(forKey: "hexConversionOptions") else {
            return runtime.hexOptions
        }
        do {
            guard let data = object as? Data, data.count <= 4096 else {
                throw NateError.message("HEX 设置不是受限完整归档。")
            }
            let archive = try JSONDecoder().decode(HexPreferencesArchive.self, from: data)
            guard archive.format == 1, (0...4096).contains(archive.options.bytesPerLine) else {
                throw NateError.message("HEX 设置格式或行宽不受支持。")
            }
            runtime.hexOptions = archive.options
        }
        catch {
            runtime.hexWarning = "HEX 设置未被读取，原归档保留；本次采用默认格式。" + error.localizedDescription
        }
        return runtime.hexOptions
    }

    /// 业务作用：明确应用时先完整验证与编码，再发布全部 HEX 格式偏好。
    /// 参数说明:
    /// - options: 用户明确确认的大小写、间隔及行宽。
    /// 返回：合法配置完整保存；非法行宽或编码失败保留原偏好。
    func saveHexOptions(_ options: HexEncodingOptions) throws {
        guard (0...4096).contains(options.bytesPerLine) else {
            throw NateError.message("每行原字节数必须为 0 至 4096，零表示不自动分行。")
        }
        let data = try JSONEncoder().encode(
            HexPreferencesArchive(
                format: 1,
                options: options
            )
        )
        guard data.count <= 4096 else {
            throw NateError.message("HEX 完整设置超过 4 KiB。")
        }
        (textTools.hexDefaults ?? .standard).set(data, forKey: "hexConversionOptions")
        textTools.hexOptions = options
        textTools.hexWarning = nil
    }

    /// 业务作用：格式表单只在明确应用时保存，等待期间外部偏好改变不能被旧草稿覆盖。
    /// 参数说明: 无。
    /// 返回：取消不写入；合法完整草稿且原偏好来源未变时保存。
    func showHexConversionSettings() {
        // 候选不属于格式窗口，不能因打开配置先确认正文输入。
        guard !closing, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        let options = currentHexOptions(), domain = textTools.hexDefaults ?? .standard
        let original = domain.object(forKey: "hexConversionOptions") as? NSObject
        let uppercase = NSButton(
            checkboxWithTitle: "使用大写 A–F",
            target: nil,
            action: nil
        )
        uppercase.state = options.uppercase ? .on : .off
        let spaces = NSButton(
            checkboxWithTitle: "字节之间插入空格（最后未分行字节后也保留空格）",
            target: nil,
            action: nil
        )
        spaces.state = options.separateBytes ? .on : .off
        let width = NSTextField(string: String(options.bytesPerLine))
        width.setAccessibilityLabel("每行原字节数，零表示不分行")
        let widthRow = NSStackView(views: [NSTextField(labelWithString: "每行原字节数"), width])
        widthRow.spacing = 10
        let note = NSTextField(
            wrappingLabelWithString:
                "范围 0–4096，0 表示不自动换行。分行使用当前文档换行格式；完整行的最后一个字节后使用换行，不再增加空格。输入按 UTF-8 原字节解释，HEX 解码的其它字节在独立结果窗口保留。"
        )
        note.textColor = .secondaryLabelColor
        let warning = NSTextField(wrappingLabelWithString: textTools.hexWarning ?? "")
        warning.textColor = .systemOrange
        let form = NSStackView(views: [uppercase, spaces, widthRow, note, warning])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.widthAnchor.constraint(equalToConstant: 500).isActive = true
        note.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        warning.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        width.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        note.preferredMaxLayoutWidth = 500
        warning.preferredMaxLayoutWidth = 500
        let background = NSBox()
        background.boxType = .custom
        background.title = ""
        background.borderWidth = 0
        background.contentViewMargins = .zero
        background.fillColor = .windowBackgroundColor
        background.addSubview(form)
        let alert = NSAlert()
        alert.messageText = "HEX 转换格式"
        alert.informativeText = "只配置明确执行的 HEX 编码，不改变正文、编码菜单或保存格式。"
        alert.accessoryView = background
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        while true {
            form.frame = NSRect(
                x: 8,
                y: 8,
                width: 500,
                height: max(200, form.fittingSize.height)
            )
            background.frame = NSRect(
                x: 0,
                y: 0,
                width: form.frame.width + 16,
                height: form.frame.height + 16
            )
            guard alert.runModal() == .alertFirstButtonReturn, !closing else {
                return
            }
            // 应用读取实际字段编辑器已经确认的文本，重开同一表单保留非法草稿而不换成旧数值。
            alert.window.makeFirstResponder(nil)
            let currentDomain = textTools.hexDefaults ?? .standard
            let current = currentDomain.object(forKey: "hexConversionOptions") as? NSObject
            // 原偏好是整份草稿的来源证据，外部重配或偏好域改变必须重新打开读取。
            guard currentDomain === domain,
                original.map({
                    $0.isEqual(current)
                }) ?? (current == nil)
            else {
                mainWindow?.status.stringValue = "HEX 配置已改变，旧表单未保存，请重新打开。"
                return
            }
            let raw = width.stringValue
            guard !raw.isEmpty, raw.utf8.count <= 4,
                raw.utf8.allSatisfy({
                    (48...57).contains($0)
                }),
                let count = Int(raw), (0...4096).contains(count)
            else {
                warning.stringValue = "每行原字节数必须是 0 至 4096 的十进制整数。"
                continue
            }
            do {
                try saveHexOptions(
                    HexEncodingOptions(
                        uppercase: uppercase.state == .on,
                        separateBytes: spaces.state == .on,
                        bytesPerLine: count
                    )
                )
                mainWindow?.status.stringValue = "HEX 转换格式已保存。"
            }
            catch {
                mainWindow?.status.stringValue = "HEX 格式未保存：" + error.localizedDescription
            }
            return
        }
    }
}
