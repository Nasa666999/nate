import AppKit

enum EditorNativeLayoutPolicy {
    static let asciiMinimumBytes = 65_536
    static let maximumWindowCharacters = 65_536
    static let maximumParagraphBytes = 1_048_576
    static let maximumCachedCharacters = 1_048_576
    static let maximumCachedLines = 256
    static let maximumDocumentBytes = 1_073_741_824

    /// 业务作用：实际原生布局规则参与持久矩形样式身份，规则改变后旧视觉列不能沿原授权继续修改。
    /// 参数说明: 无。
    /// 返回：当前窗口、段落与连字字距策略的稳定完整配置字节。
    static var identityData: Data {
        Data(
            "asciiMinimum=\(asciiMinimumBytes);windowCharacters=\(maximumWindowCharacters);paragraphBytes=\(maximumParagraphBytes);documentBytes=\(maximumDocumentBytes);asciiLigature=0;asciiKern=0"
                .utf8
        )
    }
}

extension EditorView {
    /// 业务作用：原生段落超预算时持续显示明确边界，周期保存不得把暂停呈现误报成完整显示。
    /// 参数说明: 无。
    /// 返回：当前视口实际不可布局行的原因，其它视口为空。
    public var layoutAnalysisStatus: String? {
        let first = projection.line(at: max(0, visibleRect.minY - 8))
        let last = projection.line(at: visibleRect.maxY)
        return layouts.first {
            $0.key >= first && $0.key <= last && $0.value.unavailableReason != nil
        }?.value.unavailableReason
    }
}
