import AppKit

@MainActor
final class ResultTextView: NSTextView {
    var onActivate: ((Int) -> Void)?
    var navigationEnabled = false

    /// 业务作用：双击结果行直接定位完整命中，普通选择仍支持复制。
    /// 参数说明:
    /// - event: 用户鼠标事件。
    /// 返回：双击时发送结果行索引。
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            activateCurrentLine()
        }
    }

    /// 业务作用：Enter 与双击使用同一结果导航动作。
    /// 参数说明:
    /// - event: 键盘事件。
    /// 返回：Enter 定位，其他按键保留原生行为。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            activateCurrentLine()
        }
        else {
            super.keyDown(with: event)
        }
    }

    /// 业务作用：将结果文本的选择位置转换为条目序号。
    /// 参数说明: 无。
    /// 返回：发送当前行索引，不改源文件。
    func activateCurrentLine() {
        guard navigationEnabled else {
            return
        }
        let offset = min(selectedRange().location, string.utf16.count)
        let prefix = (string as NSString).substring(to: offset)
        onActivate?(
            prefix.reduce(0) {
                $0 + ($1 == "\n" ? 1 : 0)
            }
        )
    }
}
