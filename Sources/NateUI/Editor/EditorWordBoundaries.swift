import Foundation
import NateCore

extension EditorView {
    public var wordBoundaries: WordBoundarySettings {
        boundaries.words
    }
    public var wordBoundaryGeneration: UUID {
        boundaries.wordGeneration
    }

    /// 业务作用：来源词规则改变后撤销旧临时高亮，既有原文与选择范围不按新词规则重新解释。
    /// 参数说明:
    /// - settings: 已完整验证的默认及附加词字符规则。
    /// 返回：只影响后续选词、导航和临时匹配，旧后台结果失去发布资格。
    public func setWordBoundaries(_ settings: WordBoundarySettings) {
        guard wordBoundaries != settings else {
            return
        }
        // 规则改回相同字符也不恢复旧来源权限，运行变量与颜色计划使用独立代次复验。
        boundaries.wordGeneration = UUID()
        boundaries.words = settings
        cancelSelectedTextHighlights()
        setTextHighlights(nil, for: .incremental)
        needsDisplay = true
    }
}
