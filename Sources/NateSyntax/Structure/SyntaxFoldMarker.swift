import Foundation

public enum SyntaxFoldAction: Int, Sendable {
    case open = 0
    case middle = 1
    case close = 2
    case continuation = 3
}

public struct SyntaxFoldMarker: Sendable, Equatable {
    public let action: SyntaxFoldAction
    public let insideComment: Bool

    /// 业务作用：折叠动作保留实际词法身份及注释上下文，范围转换不按同色文字重新猜测结构。
    /// 参数说明:
    /// - action: 当前标记的开端、分支中点、闭合或跨行延续职责。
    /// - insideComment: 识别该标记时是否实际位于注释上下文内。
    /// 返回：独立于颜色和字体属性的固定结构证据。
    public init(action: SyntaxFoldAction, insideComment: Bool) {
        self.action = action
        self.insideComment = insideComment
    }
}
