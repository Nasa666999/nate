import Foundation

public struct ClipboardPayload: Sendable, Equatable, Codable {
    public let fragments: [ClipboardFragment]
    public let primaryIndex: Int
    public let shape: ClipboardShape
    public let lineEnding: LineEnding
    public let plainByteCount: Int
    let documentIndices: [Int]

    /// 业务作用：建立完整复制载荷，片段数组保留建立顺序，另存文档顺序与明确主项。
    /// 参数说明:
    /// - fragments: 一至十万项原始片段，源文档顺序须为完整唯一排列。
    /// - primaryIndex: 主片段在建立顺序数组中的位置。
    /// - shape: 普通片段、整行内容或完整矩形。
    /// - lineEnding: 片段之间构建普通文本时使用的明确换行规则。
    /// 返回：普通文本合计不超过 64 MiB 的完整载荷；数量、端点、虚拟边缘或行形态无效时失败。
    public init(
        fragments: [ClipboardFragment],
        primaryIndex: Int,
        shape: ClipboardShape = .stream,
        lineEnding: LineEnding = .lf
    ) throws {
        guard !fragments.isEmpty, fragments.count <= ClipboardLimits.fragments,
            fragments.indices.contains(primaryIndex),
            Set(fragments.map(\.documentOrder)).count == fragments.count,
            fragments.allSatisfy({
                $0.documentOrder < fragments.count
            })
        else {
            throw NateError.message("剪贴板载荷缺少完整片段顺序或明确主项。")
        }
        var bytes = (fragments.count - 1) * lineEnding.text.utf8.count
        var indices = Array(repeating: 0, count: fragments.count)
        for (index, fragment) in fragments.enumerated() {
            let size = fragment.text.utf8.count + fragment.virtualTail
            guard size <= ClipboardLimits.contentBytes - bytes else {
                throw NateError.message("复制内容、虚拟尾部与分隔换行合计超过 64 MiB。")
            }
            bytes += size
            indices[fragment.documentOrder] = index
        }
        switch shape {
        case .stream:
            break
        case .lines:
            // 结束符属于原字节协议，CRLF 的整体字形不能让合法整行载荷失去结束符身份。
            guard fragments.count == 1, let first = fragments.first,
                first.virtualStart == 0, first.virtualTail == 0,
                first.text.utf8.last == 10 || first.text.utf8.last == 13
            else {
                throw NateError.message("整行剪贴板必须包含一份带明确结束符的完整内容。")
            }
        case .rectangle(let rectangle):
            guard min(rectangle.anchorRow, rectangle.headRow) == 0,
                max(rectangle.anchorRow, rectangle.headRow) == fragments.count - 1,
                fragments.allSatisfy({
                    !$0.text.utf8.contains(13) && !$0.text.utf8.contains(10)
                        && (!rectangle.zeroWidth || $0.text.isEmpty && $0.virtualTail == 0)
                })
            else {
                throw NateError.message("矩形剪贴板的真实行、纵向端点或零宽内容不完整。")
            }
        }
        self.fragments = fragments
        self.primaryIndex = primaryIndex
        self.shape = shape
        self.lineEnding = lineEnding
        plainByteCount = bytes
        documentIndices = indices
    }

    /// 业务作用：片段数与目标数一致时按源文档顺序配对，不把建立顺序当成物理行顺序。
    /// 参数说明: 无。
    /// 返回：全部真实片段的源文档顺序视图，不改变原数组或主项。
    public var documentFragments: [ClipboardFragment] {
        documentIndices.map {
            fragments[$0]
        }
    }

    /// 业务作用：对外普通文本保留片段建立顺序、NUL 和实际选中虚拟尾部，不复制定位空白。
    /// 参数说明:
    /// - deadline: 所属复制或粘贴的共同处理截止。
    /// - permit: 本轮仍可继续构建普通文本。
    /// 返回：完整普通文本，不添加额外末行；取消或超时不返回部分内容。
    public func plainText(
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> String {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        var result = ""
        result.reserveCapacity(plainByteCount)
        for (index, fragment) in fragments.enumerated() {
            try budget.check()
            if index > 0 {
                result += lineEnding.text
            }
            result += fragment.text
            if fragment.virtualTail > 0 {
                result += String(repeating: " ", count: fragment.virtualTail)
            }
        }
        try budget.check()
        return result
    }

    /// 业务作用：宏和配置封装同一受限二进制载荷，不让外层格式改变原 UTF-8 或矩形元数据。
    /// 参数说明:
    /// - encoder: 所属配置提供的编码器。
    /// 返回：完整且有格式身份的数据字段，准备失败不输出部分载荷。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded())
    }

    /// 业务作用：配置中的剪贴板内容沿同一格式与容量门禁恢复，不能绕过普通剪贴板校验。
    /// 参数说明:
    /// - decoder: 已由外层配置限制原始容量的解码器。
    /// 返回：完整有效载荷；未知格式、非法边界或内容超量时失败。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try Self.decode(container.decode(Data.self))
    }
}
