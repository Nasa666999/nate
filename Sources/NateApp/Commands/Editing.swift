import AppKit
import NateCore
import NatePlatform

extension ApplicationController {
    /// 业务作用：统一文本菜单的事务入口和修改通知。
    /// 参数说明:
    /// - command: 完整转换命令。
    /// 返回：一次动作对应一个撤销单元，失败显示原因。
    func edit(_ command: TextCommand) {
        if let options = command.lineSortOptions {
            performLineSort(options)
            return
        }
        mainWindow?.editor.finishComposition()
        guard let active else {
            return
        }
        do {
            try active.buffer.perform(command)
            if macroRecording && !macroPlaying {
                macroActions.append(.command(command.rawValue))
            }
            mainWindow?.editor.refresh(reveal: true)
            didEdit()
        }
        catch {
            SystemIntegration.alert("无法执行", error.localizedDescription)
        }
    }

    /// 业务作用：将工具生成或用户指定文字作为普通输入事务。
    /// 参数说明:
    /// - text: 完整插入文字。
    /// 返回：使用当前多选区，支持撤销。
    func insert(_ text: String) {
        mainWindow?.editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 业务作用：按语言规则切换行注释或添加块注释，不使用错误语言的通用符号。
    /// 参数说明:
    /// - block: 是否使用块注释。
    /// 返回：选区或涉及整行的一次事务；无规则时明确说明。
    func comment(block: Bool) {
        guard let active, let language = registry?.language(active.language),
            let selection = active.buffer.selections.first
        else {
            return
        }
        let tree = active.buffer.text
        do {
            if block {
                guard !language.blockStart.isEmpty, !language.blockEnd.isEmpty else {
                    throw NateError.message("当前语言没有块注释规则。")
                }
                try active.buffer.commit(
                    [
                        TextEdit(
                            selection.range,
                            language.blockStart + tree.text(in: selection.range) + language.blockEnd
                        )
                    ],
                    name: "块注释"
                )
            }
            else {
                guard !language.lineComment.isEmpty else {
                    throw NateError.message("当前语言没有行注释规则。")
                }
                let first = tree.lineNumber(at: selection.range.lower)
                let last = tree.lineNumber(at: max(selection.range.lower, selection.range.upper - 1))
                let ranges = (first...last).map {
                    tree.lineRange($0, includeEnding: false)
                }
                let remove = ranges.allSatisfy {
                    tree.text(in: $0).trimmingCharacters(in: .whitespaces).hasPrefix(language.lineComment)
                }
                let edits = ranges.map {
                    range -> TextEdit in
                    let text = tree.text(in: range)
                    let whitespace = String(
                        text.prefix {
                            $0 == " " || $0 == "\t"
                        }
                    )
                    let body = text.dropFirst(whitespace.count)
                    let value =
                        remove
                        ? whitespace + body.dropFirst(language.lineComment.count)
                        : whitespace + language.lineComment + body
                    return TextEdit(range, value)
                }
                try active.buffer.commit(edits, name: "切换行注释")
            }
            mainWindow?.editor.refresh()
            didEdit()
        }
        catch {
            SystemIntegration.alert("注释", error.localizedDescription)
        }
    }

    /// 业务作用：上移下移选区涉及的整行，行内容和换行位置分别保留。
    /// 参数说明:
    /// - command: 移动或插入空行动作。
    /// 返回：一次可撤销行事务，不作用于无关全文。
    func lineCommand(_ command: String) {
        guard let active, let selection = active.buffer.selections.first else {
            return
        }
        let tree = active.buffer.text
        let first = tree.lineNumber(at: selection.range.lower)
        let last = tree.lineNumber(at: max(selection.range.lower, selection.range.upper - 1))
        do {
            if command == "blankAbove" || command == "blankBelow" {
                let offset = command == "blankAbove" ? tree.lineStart(first) : tree.lineRange(last).upper
                let ending = mainWindow?.editor.newline ?? "\n"
                try active.buffer.commit([TextEdit(ByteRange(offset, offset), ending)], name: "插入空行")
            }
            else {
                let up = command == "moveLineUp"
                guard up ? first > 0 : last + 1 < tree.lineCount else {
                    return
                }
                let a = up ? first - 1 : first
                let b = up ? last : last + 1
                let range = ByteRange(tree.lineStart(a), tree.lineRange(b).upper)
                var rows = TextTransforms.lines(tree.text(in: range))
                let endings = rows.map(\.ending)
                if up {
                    rows.append(rows.removeFirst())
                }
                else {
                    rows.insert(rows.removeLast(), at: 0)
                }
                for i in rows.indices {
                    rows[i].ending = endings[i]
                }
                try active.buffer.commit(
                    [
                        TextEdit(
                            range,
                            rows.map {
                                $0.body + $0.ending
                            }.joined()
                        )
                    ],
                    name: "移动行"
                )
            }
            mainWindow?.editor.refresh(reveal: true)
            didEdit()
        }
        catch {
            SystemIntegration.alert("行操作", error.localizedDescription)
        }
    }

}
