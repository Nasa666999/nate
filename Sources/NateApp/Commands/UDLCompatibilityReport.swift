import AppKit
import NatePlatform
import NateSyntax

extension ApplicationController {
    /// 业务作用：多语言资源的兼容说明保留所属语言，用户能对应每个尚未应用的字段。
    /// 参数说明:
    /// - definitions: 本次完整校验并发布的语言集合。
    /// 返回：每个有说明的语言只添加一个标题，不为每条字段重复展开语言名称。
    func udlCompatibilityMessages(_ definitions: [UDLDefinition]) -> [String] {
        definitions.flatMap {
            definition in
            definition.diagnostics.isEmpty ? [] : ["语言：" + definition.name] + definition.diagnostics
        }
    }

    /// 业务作用：导入完成后逐项展示未应用的规则，完整报告可以滚动和复制，原 XML 继续保留。
    /// 参数说明:
    /// - definitions: 实际持久化并发布的定义，不能使用另一轮解析代替其来源。
    /// 返回：仅展示导入结果；查看说明不执行正文编辑或再次发布配置。
    func showUDLImportReport(_ definitions: [UDLDefinition]) {
        let messages = udlCompatibilityMessages(definitions)
        guard !messages.isEmpty else {
            SystemIntegration.alert("UDL 已导入", "规则已加入语言菜单。原 XML 可完整导出。")
            return
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 360)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = messages.joined(separator: "\n\n")
        text.setAccessibilityLabel("UDL 完整兼容说明")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let alert = NSAlert()
        alert.messageText = "UDL 已导入 · 兼容说明"
        alert.informativeText = "以下逐项说明尚未应用的字段与实际呈现方式。规则已加入语言菜单，完整原 XML 可单独导出。"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }
}
