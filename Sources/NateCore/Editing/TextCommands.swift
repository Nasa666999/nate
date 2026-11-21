import Foundation

public enum TextCommand: String, Sendable, CaseIterable {
    case uppercase, lowercase, titlecase, sentencecase, invertCase, randomCase
    case trimLeading, trimTrailing, trimBoth, removeEmpty, removeBlank, joinLines
    case tabsToSpaces, spacesToTabs, leadingSpacesToTabs
    case sortAscending, sortDescending, sortIgnoringCase, sortNumeric, sortLength
    case reverseLines, shuffleLines, uniqueLines, uniqueAdjacent
    case duplicate, deleteLines, moveUp, moveDown, insertAbove, insertBelow, indent, outdent
    case eolLF, eolCRLF, eolCR, maskBlocks, maskDots
}

extension TextCommand {
    /// 业务作用：已有行命令使用与完整排序表单相同的数值、长度和锚点语义。
    /// 参数说明: 无。
    /// 返回：行重排命令对应的明确选项，其它文本命令为空。
    public var lineSortOptions: LineSortOptions? {
        switch self {
        case .sortAscending: return LineSortOptions()
        case .sortDescending: return LineSortOptions(descending: true)
        case .sortIgnoringCase: return LineSortOptions(kind: .ignoringCase)
        case .sortNumeric: return LineSortOptions(kind: .integer)
        case .sortLength: return LineSortOptions(kind: .length)
        case .reverseLines: return LineSortOptions(kind: .reverse)
        case .shuffleLines: return LineSortOptions(kind: .random)
        default: return nil
        }
    }
}

extension DocumentBuffer {
    /// 业务作用：以当前选区或明确的全文范围执行可撤销文本转换。
    /// 参数说明:
    /// - command: 用户选择的具体转换。
    /// - tabWidth: 当前语言的视觉 Tab 停靠间距。
    /// - indentWithTabs: 增加缩进是否使用真实 Tab，空格方式使用完整停靠间距。
    /// 返回：一次命令形成一个事务，保留混合换行直到显式转换。
    public func perform(_ command: TextCommand, tabWidth: Int = 4, indentWithTabs: Bool = false) throws {
        if let options = command.lineSortOptions {
            let plan = try PreparedLineSort(
                snapshot: snapshot,
                selections: selections,
                options: options,
                marks: markSnapshot,
                bookmarks: bookmarkSnapshot
            )
            try commit(plan.transaction)
            return
        }
        let selections = normalizedSelections()
        let width = max(1, tabWidth)
        let lineCommands: Set<TextCommand> = [
            .trimLeading, .trimTrailing, .trimBoth, .removeEmpty, .removeBlank,
            .joinLines, .sortAscending, .sortDescending, .sortIgnoringCase, .sortNumeric, .sortLength,
            .reverseLines, .shuffleLines, .uniqueLines, .uniqueAdjacent, .deleteLines, .indent, .outdent,
            .tabsToSpaces, .spacesToTabs, .leadingSpacesToTabs,
        ]
        var ranges = selections.map(\.range)
        if [.duplicate, .deleteLines, .indent, .outdent].contains(command) && ranges.allSatisfy(\.isEmpty) {
            ranges = ranges.map {
                text.lineRange(text.lineNumber(at: $0.lower))
            }
        }
        else if lineCommands.contains(command) {
            if ranges.allSatisfy(\.isEmpty) {
                ranges = [ByteRange(0, text.byteCount)]
            }
            else {
                ranges = ranges.map {
                    let first = text.lineNumber(at: $0.lower)
                    let last = text.lineNumber(at: max($0.lower, $0.upper - 1))
                    return ByteRange(text.lineStart(first), text.lineRange(last).upper)
                }
            }
        }
        else if [.eolLF, .eolCRLF, .eolCR].contains(command) {
            ranges = [ByteRange(0, text.byteCount)]
        }
        else if ranges.allSatisfy(\.isEmpty) {
            ranges = [ByteRange(0, text.byteCount)]
        }
        var merged: [ByteRange] = []
        for range in ranges.sorted(by: {
            $0.lower < $1.lower
        }) {
            if let last = merged.last, range.lower <= last.upper {
                merged[merged.count - 1] = ByteRange(last.lower, max(last.upper, range.upper))
            }
            else {
                merged.append(range)
            }
        }
        let edits = try merged.map {
            range in
            TextEdit(
                range,
                try TextTransforms.apply(
                    command,
                    to: text.text(in: range),
                    tabWidth: width,
                    indentWithTabs: indentWithTabs
                )
            )
        }
        var format = self.format
        if command == .eolLF {
            format.lineEnding = .lf
        }
        if command == .eolCRLF {
            format.lineEnding = .crlf
        }
        if command == .eolCR {
            format.lineEnding = .cr
        }
        try commit(edits, formatAfter: format, name: command.rawValue)
    }
}

public enum TextTransforms {
    /// 业务作用：将文本按真实换行分割，行内容和行终止符分别保留。
    /// 参数说明:
    /// - text: 原始文本。
    /// 返回：不丢末尾换行、空行或 CRLF 的行列表。
    public static func lines(_ text: String) -> [(body: String, ending: String)] {
        var result: [(String, String)] = []
        var body = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                result.append((body, String(ch)))
                body = ""
            }
            else {
                body.append(ch)
            }
        }
        if !body.isEmpty || result.isEmpty {
            result.append((body, ""))
        }
        return result
    }

    /// 业务作用：实现独立于界面的文本变换，副作用由事务入口统一发布。
    /// 参数说明:
    /// - command: 变换类型。
    /// - text: 固定输入片段。
    /// - tabWidth: Tab 视觉停靠间距。
    /// - indentWithTabs: 增加缩进使用真实 Tab，其它转换仍按实际停靠间距处理。
    /// 返回：完整转换文本，不触碰磁盘或文档历史；行排序超量或换行边界无法完整保持时失败。
    public static func apply(
        _ command: TextCommand,
        to text: String,
        tabWidth: Int,
        indentWithTabs: Bool = false
    ) throws -> String {
        if let options = command.lineSortOptions {
            let snapshot = DocumentSnapshot(id: UUID(), revision: 0, text: PieceTree(text))
            return try PreparedLineSort(
                snapshot: snapshot,
                selections: [TextSelection(anchor: 0, head: 0)],
                options: options
            ).transaction.resultingText.text()
        }
        switch command {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titlecase: return text.capitalized
        case .sentencecase:
            var capital = true
            return text.lowercased().map {
                ch in
                defer {
                    if ch.isLetter {
                        capital = false
                    }
                    if ".!?。！？".contains(ch) {
                        capital = true
                    }
                }
                return capital ? String(ch).uppercased() : String(ch)
            }.joined()
        case .invertCase:
            return text.map {
                String($0) == String($0).uppercased() ? String($0).lowercased() : String($0).uppercased()
            }.joined()
        case .randomCase:
            return text.map {
                Bool.random() ? String($0).uppercased() : String($0).lowercased()
            }.joined()
        case .maskBlocks, .maskDots:
            return text.map {
                $0.isNewline ? String($0) : (command == .maskBlocks ? "█" : "●")
            }.joined()
        case .eolLF, .eolCRLF, .eolCR:
            let ending = command == .eolLF ? "\n" : command == .eolCR ? "\r" : "\r\n"
            return lines(text).map {
                $0.body + ($0.ending.isEmpty ? "" : ending)
            }.joined()
        default: break
        }
        var rows = lines(text)
        let defaultEnding =
            rows.first(where: {
                !$0.ending.isEmpty
            })?.ending ?? "\n"
        switch command {
        case .uniqueLines, .uniqueAdjacent:
            var seen = Set<[UInt8]>()
            var previous: [UInt8]?
            rows = rows.filter {
                let bytes = Array($0.body.utf8)
                defer {
                    previous = bytes
                }
                return command == .uniqueLines ? seen.insert(bytes).inserted : previous != bytes
            }
        case .removeEmpty:
            rows.removeAll {
                $0.body.isEmpty
            }
        case .removeBlank:
            rows.removeAll {
                $0.body.allSatisfy {
                    $0 == " " || $0 == "\t"
                }
            }
        case .joinLines: return rows.map(\.body).joined(separator: " ")
        case .duplicate:
            return text + (text.hasSuffix("\n") || text.hasSuffix("\r") ? "" : defaultEnding) + text
        case .deleteLines: return ""
        default:
            rows = rows.map {
                row in
                var body = row.body
                switch command {
                case .trimLeading, .trimBoth:
                    body = String(
                        body.drop(while: {
                            $0 == " " || $0 == "\t"
                        })
                    )
                    if command == .trimBoth {
                        body = String(
                            body.reversed().drop(while: {
                                $0 == " " || $0 == "\t"
                            }).reversed()
                        )
                    }
                case .trimTrailing:
                    body = String(
                        body.reversed().drop(while: {
                            $0 == " " || $0 == "\t"
                        }).reversed()
                    )
                case .indent: body = (indentWithTabs ? "\t" : String(repeating: " ", count: tabWidth)) + body
                case .outdent:
                    if body.first == "\t" {
                        body.removeFirst()
                    }
                    else {
                        body = String(
                            body.dropFirst(
                                min(
                                    tabWidth,
                                    body.prefix(while: {
                                        $0 == " "
                                    }).count
                                )
                            )
                        )
                    }
                case .tabsToSpaces:
                    var column = 0
                    body = body.map {
                        ch in
                        let amount = ch == "\t" ? tabWidth - column % tabWidth : 1
                        column += amount
                        return ch == "\t" ? String(repeating: " ", count: amount) : String(ch)
                    }.joined()
                case .spacesToTabs, .leadingSpacesToTabs:
                    let leading = String(
                        body.prefix(while: {
                            $0 == " "
                        })
                    )
                    body =
                        String(repeating: "\t", count: leading.count / tabWidth)
                        + String(repeating: " ", count: leading.count % tabWidth)
                        + body.dropFirst(leading.count)
                default: break
                }
                return (body, row.ending)
            }
        }
        return rows.map {
            $0.body + $0.ending
        }.joined()
    }
}
