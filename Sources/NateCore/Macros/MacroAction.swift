import Foundation

public enum MacroAction: Codable, Sendable {
    case input(String)
    case command(String)
    case lineSort(LineSortOptions)
    case clipboard(ClipboardPayload, adaptLineEndings: Bool)
    case editor(EditorCommand)
    case search(MacroSearchAction)
    case clipboardCopy(cutting: Bool, copyLineWithoutSelection: Bool)
    case pairInput(PairInputCommand)

    /// 业务作用：临时录制和命名宏统一估计原文及片段索引占用，空片段也必须计入保留容量。
    /// 参数说明: 无。
    /// 返回：包含动作值、完整文字及载荷索引的字节估计，不包括另行持有的编码归档。
    public func retainedByteEstimate() -> Int {
        var bytes = MemoryLayout<MacroAction>.stride
        switch self {
        case .pairInput(let command):
            bytes +=
                command.pair.opening.utf8.count + command.pair.closing.utf8.count + command.input.utf8.count
        case .input(let text), .command(let text): bytes += text.utf8.count
        case .editor, .clipboardCopy: break
        case .search(let action):
            bytes += action.options.query.utf8.count + action.options.replacement.utf8.count
        case .lineSort(let options): bytes += options.localeIdentifier.utf8.count
        case .clipboard(let payload, _):
            bytes +=
                payload.fragments.count * (MemoryLayout<ClipboardFragment>.stride + MemoryLayout<Int>.stride)
            bytes += payload.fragments.reduce(0) {
                $0 + $1.text.utf8.count
            }
        }
        return bytes
    }

    /// 业务作用：导入和播放前确认每个动作具有当前支持的明确语义，不能跳过未知动作后继续修改。
    /// 参数说明: 无。
    /// 返回：动作名称、输入容量和区域参数合法时继续，未知命令或超量内容时拒绝整份动作列表。
    public func validateSupport() throws {
        switch self {
        case .search(let action):
            try action.validateSupport()
        case .input(let text):
            guard text.utf8.count <= 64 * 1024 * 1024 else {
                throw NateError.message("宏输入超过单次 64 MiB 预算。")
            }
        case .command(let name):
            guard
                TextCommand(rawValue: name) != nil || BookmarkAction(rawValue: name)?.macroTitle != nil
                    || BracketNavigation(rawValue: name) != nil || QuickFindAction(rawValue: name) != nil
            else {
                let label = name.unicodeScalars.prefix(128).map {
                    $0.value < 32 ? "�" : String($0)
                }.joined()
                throw NateError.message("无法识别的编辑动作“" + label + "”。")
            }
        case .lineSort(let options):
            guard options.localeIdentifier.utf8.count <= 256,
                !options.localeIdentifier.utf8.contains(0),
                options.kind != .locale || !options.localeIdentifier.isEmpty
            else {
                throw NateError.message("宏排序的语言地区标识为空、包含 NUL 或超过 256 字节。")
            }
        case .clipboard, .editor, .clipboardCopy, .pairInput:
            break
        }
    }
}
