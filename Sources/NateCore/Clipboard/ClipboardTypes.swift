import Foundation

public struct ClipboardFragment: Sendable, Equatable {
    public let text: String
    public let documentOrder: Int
    public let reversed: Bool
    public let virtualStart: Int
    public let virtualTail: Int

    /// 业务作用：复制片段保留原文字节、选择方向与虚拟边缘，定位空白不混入被复制正文。
    /// 参数说明:
    /// - text: 实际选择的原文或选中 Tab 列对应的空格。
    /// - documentOrder: 在源文档顺序中的零起始位置，独立于片段建立顺序。
    /// - reversed: 源选择的活动端是否在固定端之前。
    /// - virtualStart: 短行行尾之后的定位列，不作为复制内容。
    /// - virtualTail: 实际选中的行尾虚拟空格列，属于复制内容。
    /// 返回：尚未绑定整份载荷的独立片段；非法顺序、超过一百万列或单片段超过 64 MiB 时失败。
    public init(
        text: String,
        documentOrder: Int,
        reversed: Bool = false,
        virtualStart: Int = 0,
        virtualTail: Int = 0
    ) throws {
        guard (0..<100_000).contains(documentOrder), text.utf8.count <= ClipboardLimits.contentBytes,
            (0...1_000_000).contains(virtualStart), (0...1_000_000).contains(virtualTail),
            virtualStart == 0 || text.isEmpty
        else {
            throw NateError.message("剪贴板片段的顺序、文字或虚拟边缘超出有效范围。")
        }
        self.text = text
        self.documentOrder = documentOrder
        self.reversed = reversed
        self.virtualStart = virtualStart
        self.virtualTail = virtualTail
    }

    /// 业务作用：历史去重保留原始 Unicode 字节区别，不能把等价组合原文当成同一次复制。
    /// 参数说明:
    /// - lhs: 第一份实际片段。
    /// - rhs: 第二份实际片段。
    /// 返回：原始 UTF-8 与全部形态字段逐项一致时为真。
    public static func == (lhs: ClipboardFragment, rhs: ClipboardFragment) -> Bool {
        lhs.documentOrder == rhs.documentOrder && lhs.reversed == rhs.reversed
            && lhs.virtualStart == rhs.virtualStart && lhs.virtualTail == rhs.virtualTail
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

public struct ClipboardRectangle: Sendable, Equatable {
    public let width: Double
    public let reversed: Bool
    public let zeroWidth: Bool
    public let anchorRow: Int
    public let headRow: Int

    /// 业务作用：矩形剪贴板保留源视觉宽度、横向方向和纵向端点，不泄露源文档路径或字节位置。
    /// 参数说明:
    /// - width: 源视图中的非负像素宽度。
    /// - reversed: 活动视觉边缘是否在固定边缘左侧。
    /// - zeroWidth: 源交互明确的零宽模式，独立于实际文字范围。
    /// - anchorRow: 固定行在真实源行顺序中的位置。
    /// - headRow: 活动行在真实源行顺序中的位置。
    /// 返回：尚未绑定载荷行数的完整形态；非法坐标、端点或超量时失败。
    public init(width: Double, reversed: Bool, zeroWidth: Bool, anchorRow: Int, headRow: Int) throws {
        guard width.isFinite, (0...1_000_000_000).contains(width),
            (0..<100_000).contains(anchorRow), (0..<100_000).contains(headRow)
        else {
            throw NateError.message("剪贴板矩形的宽度或纵向端点无效。")
        }
        self.width = width
        self.reversed = reversed
        self.zeroWidth = zeroWidth
        self.anchorRow = anchorRow
        self.headRow = headRow
    }
}

public enum ClipboardShape: Sendable, Equatable {
    case stream
    case lines
    case rectangle(ClipboardRectangle)
}

public enum ClipboardLimits {
    public static let contentBytes = 64 * 1024 * 1024
    public static let encodedBytes = 96 * 1024 * 1024
    public static let fragments = 100_000
}

struct ClipboardBudget {
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool

    /// 业务作用：剪贴板读取、构建与编解码共用当前动作的取消和截止，不向后续阶段重新授予完整预算。
    /// 参数说明:
    /// - deadline: 外层动作固定截止；省略时使用最多五秒。
    /// - permit: 本轮仍拥有来源和发布资格。
    /// 返回：不可扩大的处理预算。
    init(deadline: ContinuousClock.Instant? = nil, permit: @escaping @Sendable () -> Bool) {
        let own = ContinuousClock.now.advanced(by: .seconds(5))
        self.deadline = min(deadline ?? own, own)
        self.permit = permit
    }

    /// 业务作用：容量内的数据处理仍能及时退出，取消和超时不能发布部分剪贴板内容。
    /// 参数说明: 无。
    /// 返回：当前仍有效时继续，否则完整失败。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("剪贴板处理超过时间预算，未发布部分内容。")
        }
    }
}
