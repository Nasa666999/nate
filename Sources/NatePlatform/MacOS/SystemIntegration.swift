import AppKit
import Darwin

@MainActor
public enum SystemIntegration {
    /// 业务作用：取得单项用户输入，取消时不产生业务副作用。
    /// 参数说明:
    /// - title: 当前动作。
    /// - message: 输入意义与范围。
    /// - initial: 初始建议值。
    /// 返回：确认的完整文字或取消。
    public static func prompt(_ title: String, _ message: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let input = NSTextField(string: initial)
        input.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }
    /// 业务作用：统一定位应用资源，安装后不回退到源码或构建缓存。
    /// 参数说明: 无。
    /// 返回：已安装应用资源根目录。
    public static func resourceDirectory() -> URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    /// 业务作用：选择任意扩展名的本地文本文件。
    /// 参数说明: 无。
    /// 返回：用户确认的路径，取消为空。
    public static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// 业务作用：取得用户明确确认的保存位置，不自动重写扩展名。
    /// 参数说明:
    /// - name: 建议文件名。
    /// 返回：确认目标；取消为空。
    public static func chooseSave(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 业务作用：展示操作失败或需要处理的事实，避免伪报成功。
    /// 参数说明:
    /// - title: 动作名称。
    /// - message: 具体状态或原因。
    /// 返回：用户关闭说明框。
    public static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// 业务作用：只在应用主动复制时收集剪贴板内容。
    /// 参数说明:
    /// - text: 当前复制文本，保留 NUL。
    /// 返回：系统剪贴板更新，其他应用不会被持续采集。
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 写入权锁随文件描述符关闭而释放，崩溃不留下永久占用。
@MainActor
public final class InstanceLease {
    private var descriptor: Int32 = -1

    /// 业务作用：为共享恢复目录取得跨进程单写入权。
    /// 参数说明:
    /// - path: 用户应用支持目录内的锁文件。
    /// 返回：无法取得锁时为空，调用方转发系统打开请求。
    public init?(path: String) {
        descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            return nil
        }
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}
