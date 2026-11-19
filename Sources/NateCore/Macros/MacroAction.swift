import Foundation

public enum MacroAction: Codable, Sendable {
    case input(String)
    case command(String)
    case lineSort(LineSortOptions)
    case clipboard(ClipboardPayload, adaptLineEndings: Bool)
    case editor(EditorCommand)
    case search(MacroSearchAction)

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
            guard TextCommand(rawValue: name) != nil else {
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
        case .clipboard, .editor:
            break
        }
    }
}
