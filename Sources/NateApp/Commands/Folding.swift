import NateUI

extension ApplicationController {
    /// 业务作用：菜单、快捷键和命令路由使用同一折叠动作映射，不各自猜测当前作用范围。
    /// 参数说明:
    /// - command: 稳定界面命令标识符。
    /// 返回：已定义的折叠动作；其它业务命令为空。
    func foldAction(for command: String) -> FoldAction? {
        switch command {
        case "foldToggle": return .toggle
        case "foldCurrent": return .collapse
        case "unfoldCurrent": return .expand
        case "foldAll": return .collapseAll
        case "unfoldAll": return .expandAll
        default:
            guard command.hasPrefix("foldLevel:"), let level = Int(command.dropFirst(10)),
                (1...8).contains(level)
            else {
                return nil
            }
            return .level(level)
        }
    }
}
