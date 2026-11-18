import AppKit
import NateCore
import NatePlatform
import NateSearch
import NateStorage

extension ApplicationController {
    /// 业务作用：统一文本菜单的事务入口和修改通知。
    /// 参数说明:
    /// - command: 完整转换命令。
    /// 返回：一次动作对应一个撤销单元，失败显示原因。
    func edit(_ command: TextCommand) {
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

    /// 业务作用：在全部目标上插入固定列文本或按文档顺序生成进制数字。
    /// 参数说明: 无。
    /// 返回：虚拟列只在插入时补空白，全部目标共用一个撤销单元。
    func columnEditor() {
        guard let active, let selection = active.buffer.selections.first else {
            return
        }
        guard
            let format = SystemIntegration.prompt(
                "列编辑器",
                "固定文字输入 text:内容；数字输入 开始值,步长,进制(2/8/10/16),零填充宽度,重复次数。单光标从当前列应用到文档末尾。",
                initial: "1,1,10,0,1"
            )
        else {
            return
        }
        var targets = active.buffer.normalizedSelections()
        if targets.count == 1 && selection.range.isEmpty {
            let first = active.buffer.text.lineNumber(at: selection.head)
            let prefix = active.buffer.text.text(
                in: ByteRange(active.buffer.text.lineStart(first), selection.head)
            )
            let column = prefix.count
            guard active.buffer.text.lineCount - first <= 100_000 else {
                SystemIntegration.alert("范围过大", "请明确选择不超过 100000 行的目标。 ")
                return
            }
            targets = (first..<active.buffer.text.lineCount).map {
                line in
                let row = active.buffer.text.lineRange(line, includeEnding: false)
                let body = active.buffer.text.text(in: row)
                let prefix = body.prefix(column)
                let offset = row.lower + prefix.utf8.count
                return TextSelection(anchor: offset, head: offset, virtualColumn: max(0, column - body.count))
            }
        }
        do {
            let pieces: [String]
            if format.hasPrefix("text:") {
                pieces = targets.map {
                    _ in String(format.dropFirst(5))
                }
            }
            else {
                let values = format.split(separator: ",").compactMap {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
                guard values.count == 5, [2, 8, 10, 16].contains(values[2]), (0...1000).contains(values[3]),
                    values[4] > 0
                else {
                    throw NateError.message("列数字参数无效。")
                }
                pieces = try targets.indices.map {
                    index in
                    let (delta, overflow) = (index / values[4]).multipliedReportingOverflow(by: values[1])
                    let (number, sumOverflow) = values[0].addingReportingOverflow(delta)
                    guard !overflow, !sumOverflow else {
                        throw NateError.message("列数字超出整数范围。")
                    }
                    let value = String(number, radix: values[2], uppercase: true)
                    return String(repeating: "0", count: max(0, values[3] - value.count)) + value
                }
            }
            try active.buffer.commit(
                zip(targets, pieces).map {
                    TextEdit($0.0.range, String(repeating: " ", count: $0.0.virtualColumn) + $0.1)
                },
                name: "列编辑"
            )
            mainWindow?.editor.refresh()
            didEdit()
        }
        catch {
            SystemIntegration.alert("列编辑器", error.localizedDescription)
        }
    }
}
