import Foundation

extension PieceTree {
    /// 业务作用：固定正文前瞻以不可变根身份确认来源，修订相同的另一棵正文不能复用旧匹配证据。
    /// 参数说明: 无。
    /// 返回：当前不可变正文根的唯一身份；结构共享的同一根保持一致，新正文根取得独立身份。
    public var sourceIdentity: UUID {
        root.identity
    }
}
