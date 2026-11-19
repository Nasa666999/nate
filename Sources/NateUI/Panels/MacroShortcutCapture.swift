import AppKit
import NateCore

@MainActor
public final class MacroShortcutCapture: NSView {
    public var shortcut: MacroShortcut? {
        didSet {
            needsDisplay = true
        }
    }
    public var isEnabled = true {
        didSet {
            if !isEnabled {
                stopCapture()
            }
            needsDisplay = true
        }
    }
    public var onError: ((String) -> Void)?
    private var recording = false
    private var monitor: Any?
    public override var acceptsFirstResponder: Bool {
        isEnabled
    }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 28)
    }

    /// 业务作用：快捷键只在用户明确点击录制时捕获，普通名称输入和其它窗口不被拦截。
    /// 参数说明: 无。
    /// 返回：尚未绑定快捷键的独立录制控件。
    public init() {
        super.init(frame: .zero)
        toolTip = "点击后按组合键；Esc 取消。Command、Option 或 Control 组合及功能键可用。"
    }

    /// 业务作用：快捷键控件只由当前应用建立，不从外部归档恢复事件拦截器。
    /// 参数说明:
    /// - coder: 系统界面归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 业务作用：点击明确授予本控件一次按键捕获权，菜单快捷键在捕获期间也只记录而不执行。
    /// 参数说明:
    /// - event: 录制区域内的鼠标动作。
    /// 返回：仅本窗口、本控件保持焦点期间捕获下一项实际组合。
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled, window?.makeFirstResponder(self) == true else {
            return
        }
        stopCapture()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.recording, self.window?.isKeyWindow == true,
                self.window?.firstResponder === self
            else {
                return event
            }
            self.capture(event)
            return nil
        }
        needsDisplay = true
    }

    /// 业务作用：离开录制控件立即解除局部拦截，后续窗口不能沿旧录制状态丢失按键。
    /// 参数说明: 无。
    /// 返回：解除捕获并允许正常焦点切换。
    public override func resignFirstResponder() -> Bool {
        stopCapture()
        return super.resignFirstResponder()
    }

    /// 业务作用：关闭面板或取消录制时释放实际事件监听，不改变已有绑定。
    /// 参数说明: 无。
    /// 返回：恢复正常菜单与文字输入分发。
    public func stopCapture() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        needsDisplay = true
    }

    /// 业务作用：录制值只使用明确修饰键和未应用修饰的原键，不把输入文字或候选内容当成宏。
    /// 参数说明:
    /// - event: 当前控件拥有捕获权的真实键盘事件。
    /// 返回：合法组合成为待应用绑定；Esc 取消，非法组合保留录制状态供重试。
    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopCapture()
            return
        }
        guard let key = event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else {
            return
        }
        let flags = event.modifierFlags
        let modifiers: UInt8 =
            (flags.contains(.command) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.control) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
        do {
            shortcut = try MacroShortcut(key: key, modifiers: modifiers)
            stopCapture()
        }
        catch {
            onError?(error.localizedDescription)
        }
    }

    /// 业务作用：用原生菜单符号显示待应用的组合，录制状态与已保存绑定清楚区分。
    /// 参数说明:
    /// - value: 可选的完整绑定。
    /// 返回：可读的修饰键与实际键名称；无绑定时显示明确提示。
    public static func label(_ value: MacroShortcut?) -> String {
        guard let value else {
            return "点击录制快捷键"
        }
        var result = ""
        for (bit, symbol) in [(UInt8(4), "⌃"), (UInt8(2), "⌥"), (UInt8(8), "⇧"), (UInt8(1), "⌘")] {
            if value.modifiers & bit != 0 {
                result += symbol
            }
        }
        if let scalar = value.key.unicodeScalars.first, (0xF704...0xF726).contains(scalar.value) {
            return result + "F\(scalar.value - 0xF704 + 1)"
        }
        return result + (value.key == " " ? "Space" : value.key.uppercased())
    }

    /// 业务作用：录制区域使用实际外观与焦点状态绘制，不把键盘事件权限藏在普通输入框中。
    /// 参数说明:
    /// - dirtyRect: 系统请求重绘的范围。
    /// 返回：显示等待录制或待应用组合，不读写正文。
    public override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.stroke()
        let value = recording ? "请按组合键 · Esc 取消" : Self.label(shortcut)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
        ]
        value.draw(in: bounds.insetBy(dx: 9, dy: 6), withAttributes: attributes)
    }
}
