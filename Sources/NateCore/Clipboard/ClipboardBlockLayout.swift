import Foundation

public struct ClipboardBlockTarget: Sendable {
    public let range: ByteRange
    public let leadingSpaces: Int
    public let trailingSpaces: Int
    public let virtualColumn: Int

    /// 业务作用：原生排版只提供一个真实目标行的替换边缘，不携带可重复或截断的剪贴板行。
    /// 参数说明:
    /// - range: 删除普通原选择之后的临时正文中的实际行内范围。
    /// - leadingSpaces: 插入前保留的 Tab 列或非空输入所需的虚拟定位。
    /// - trailingSpaces: 插入后保留的 Tab 列。
    /// - virtualColumn: 空操作仍保留的真实行尾外列数。
    /// 返回：尚未发布的单行边缘，完整行数与内容由后台按载荷验证。
    public init(range: ByteRange, leadingSpaces: Int = 0, trailingSpaces: Int = 0, virtualColumn: Int = 0) {
        self.range = range
        self.leadingSpaces = leadingSpaces
        self.trailingSpaces = trailingSpaces
        self.virtualColumn = virtualColumn
    }
}

public struct ClipboardBlockLayout: Sendable {
    public let baseRemoval: ByteRange?
    public let targets: [ClipboardBlockTarget]
    public let additionalRows: Int
    public let newRowPadding: Int
    public let originTabX: Double?

    /// 业务作用：绑定完整块的原生边缘和文档末尾扩展意图，正文构建始终留在后台事务内。
    /// 参数说明:
    /// - baseRemoval: 普通单选粘贴矩形前移除的原选区，矩形目标为空。
    /// - targets: 已存在真实行上的全部有序边缘，不包含新增行。
    /// - additionalRows: 超过临时文档末尾的真实载荷行数，包括空行。
    /// - newRowPadding: 新建非空行在插入内容前需要的空格列。
    /// - originTabX: 首行空操作仍停留在未展开 Tab 内时的明确视觉位置。
    /// 返回：不授予发布权限的完整布局意图。
    public init(
        baseRemoval: ByteRange? = nil,
        targets: [ClipboardBlockTarget],
        additionalRows: Int = 0,
        newRowPadding: Int = 0,
        originTabX: Double? = nil
    ) {
        self.baseRemoval = baseRemoval
        self.targets = targets
        self.additionalRows = additionalRows
        self.newRowPadding = newRowPadding
        self.originTabX = originTabX
    }
}
