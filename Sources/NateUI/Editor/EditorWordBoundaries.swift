import Foundation
import NateCore

extension EditorView {
    public var wordBoundaries: WordBoundarySettings {
        boundaries.words
    }
    public var wordBoundaryGeneration: UUID {
        boundaries.wordGeneration
    }

    /// 业务作用：来源词规则改变后撤销旧候选及临时高亮，既有原文与选择范围保持原样。
    /// 参数说明:
    /// - settings: 已完整验证的默认及附加词字符规则。
    /// 返回：后续选词、补全、导航及临时匹配使用新规则，旧后台结果失去发布资格。
    public func setWordBoundaries(_ settings: WordBoundarySettings) {
        guard wordBoundaries != settings else {
            return
        }
        // 规则改回相同字符也不恢复旧来源权限，运行变量与颜色计划使用独立代次复验。
        boundaries.wordGeneration = UUID()
        boundaries.words = settings
        dismissCompletion()
        cancelSelectedTextHighlights()
        setTextHighlights(nil, for: .incremental)
        needsDisplay = true
    }
}
