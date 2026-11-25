import Foundation

public struct MixedHanWrapMetrics: Sendable, Equatable {
    public let width: Double
    public let asciiAdvance: Double
    public let hanAdvance: Double
    public let asciiHeight: Double
    public let hanHeight: Double

    /// 业务作用：固定同一容器中实际取得的两种字形步距及原生行高，后台只能按这些度量安排断行。
    /// 参数说明:
    /// - width: 当前容器允许使用的实际宽度。
    /// - asciiAdvance: 已由原生字体确认的单个 ASCII 字形宽度。
    /// - hanAdvance: 已由级联字体确认的单个全角字形宽度。
    /// - asciiHeight: 只含 ASCII 的原生视觉行高度。
    /// - hanHeight: 含有全角字形的原生视觉行高度。
    /// 返回：有限而可换算的完整度量，否则为空。
    public init?(
        width: Double,
        asciiAdvance: Double,
        hanAdvance: Double,
        asciiHeight: Double,
        hanHeight: Double
    ) {
        guard width.isFinite, width > 0, width / asciiAdvance <= 8192,
            [asciiAdvance, hanAdvance, asciiHeight, hanHeight].allSatisfy({ (0.015625...4096).contains($0) }),
            asciiAdvance <= hanAdvance, asciiHeight <= hanHeight
        else {
            return nil
        }
        self.width = width
        self.asciiAdvance = asciiAdvance
        self.hanAdvance = hanAdvance
        self.asciiHeight = asciiHeight
        self.hanHeight = hanHeight
    }

    /// 业务作用：混排的真实行宽由两种实际字体步距分别累计。
    /// 参数说明:
    /// - ascii: 当前视觉范围的 ASCII 字形数。
    /// - han: 当前视觉范围的全角字形数。
    /// 返回：不累计逐字浮点误差的完整像素宽度。
    func distance(ascii: Int, han: Int) -> Double {
        Double(ascii) * asciiAdvance + Double(han) * hanAdvance
    }
}
