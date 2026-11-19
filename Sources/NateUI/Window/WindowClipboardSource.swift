import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：同一工作区的全部克隆使用明确的源码解码来源，资源改变时旧后台粘贴同时失权。
    /// 参数说明:
    /// - decoder: 只捕获固定代码页资源的完整有界源码解码器。
    /// 返回：当前全部视图采用同一传输编码规则，新克隆继承当前来源。
    public func setClipboardMarkupDecoder(
        _ decoder: @escaping @Sendable (Data, ClipboardMarkupFormat, ContinuousClock.Instant) throws -> String
    ) {
        for view in editorSplit.arrangedSubviews {
            if let editor = (view as? NSScrollView)?.documentView as? EditorView {
                editor.clipboardMarkupDecoder = decoder
            }
        }
    }
}
