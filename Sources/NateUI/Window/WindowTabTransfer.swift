import AppKit

public struct WindowTabTransfer {
    public let documentID: UUID
    public let sourceGeneration: UUID
    public let destinationGeneration: UUID
    public let before: UUID?

    /// 业务作用：鼠标拖放或菜单选择携带原窗口和目标窗口的顺序证据。
    /// 参数说明:
    /// - documentID: 原标签的实际文档身份。
    /// - sourceGeneration: 拖动或选择时的源标签栏代次。
    /// - destinationGeneration: 确认插入位置时的目标标签栏代次。
    /// - before: 目标栏的插入参考，为空时插入末尾。
    /// 返回：待统一工作区复验的移动意图。
    public init(documentID: UUID, sourceGeneration: UUID, destinationGeneration: UUID, before: UUID?) {
        self.documentID = documentID
        self.sourceGeneration = sourceGeneration
        self.destinationGeneration = destinationGeneration
        self.before = before
    }
}

extension EditorWindow {
    /// 业务作用：用目标窗口实际标签视口复验跨窗鼠标落点。
    /// 参数说明:
    /// - point: 当前原生屏幕坐标。
    /// 返回：落点在可见、允许移动的实际标签栏内时为真。
    public func acceptsTabDrop(at point: NSPoint) -> Bool {
        guard let window, window.isVisible, !tabs.isHidden, tabs.canTransferTabs else {
            return false
        }
        let windowPoint = window.convertPoint(fromScreen: point)
        return tabs.bounds.contains(tabs.convert(windowPoint, from: nil))
    }
}
