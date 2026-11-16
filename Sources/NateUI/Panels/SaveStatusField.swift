import AppKit

@MainActor
public final class SaveStatusField: NSTextField {
    public var onActivate: (() -> Void)?

    /// 业务作用：保存失败和外部冲突可从状态栏直接进入处理流程。
    /// 参数说明:
    /// - event: 用户点击事件。
    /// 返回：发送当前文档的状态处理意图，不自行访问文件。
    public override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    /// 业务作用：辅助功能与鼠标使用同一保存状态入口。
    /// 参数说明: 无。
    /// 返回：执行可访问性按下动作。
    public override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }
}
