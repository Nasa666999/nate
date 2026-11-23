import Foundation

public struct DocumentTextLink: Sendable, Equatable {
    public let range: ByteRange
    public let rawText: String
    public let target: URL

    /// 业务作用：链接身份使用完整原字节及固定系统目标，规范等价文字不能替换原候选。
    /// 参数说明:
    /// - lhs: 已经固定来源的链接。
    /// - rhs: 待比较的链接。
    /// 返回：范围、原文原字节及完整目标全部相同时为真。
    public static func == (lhs: DocumentTextLink, rhs: DocumentTextLink) -> Bool {
        lhs.range == rhs.range && lhs.rawText.utf8.elementsEqual(rhs.rawText.utf8)
            && lhs.target.absoluteString.utf8.elementsEqual(rhs.target.absoluteString.utf8)
    }
}

public struct DocumentTextLinkPage: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let sourceIdentity: UUID
    public let range: ByteRange
    public let settings: TextLinkSettings
    public let links: [DocumentTextLink]

    /// 业务作用：链接只从同一快照的完整物理行准备，来源、配置及所有可点击目标一起固定。
    /// 参数说明:
    /// - snapshot: 不可变正文及所属文档生命周期和修订。
    /// - range: 完整物理行构成的连续范围，末行可不包含结束符。
    /// - settings: 当前完整链接显示与协议定义。
    /// - deadline: 原文读取、候选扫描及系统 URL 构造共同的截止。
    /// - permit: 该正文和配置仍允许本次结果继续准备。
    /// 返回：启用时至多 64 KiB、128 行及 4096 项的完整链接页；关闭时只校验原文范围而不复制正文，失败不提供部分目标。
    public init(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        settings: TextLinkSettings,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)),
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let work = TextLinkWork(deadline: deadline, permit: permit)
        try work.check()
        let text = snapshot.text
        guard range.lower >= 0, range.upper >= range.lower, range.upper <= text.byteCount,
            text.isBoundary(range.lower), text.isBoundary(range.upper)
        else {
            throw NateError.message("链接页范围越界或切开 Unicode 标量，未建立部分页面。")
        }
        documentID = snapshot.id
        revision = snapshot.revision
        sourceIdentity = text.sourceIdentity
        self.range = range
        self.settings = settings
        if settings.mode == .disabled {
            links = []
            return
        }
        guard range.count <= 65_536 else {
            throw NateError.message("链接页原文超过 64 KiB，未截断或估计链接边界。")
        }
        let first = text.lineNumber(at: range.lower)
        let final = text.lineNumber(at: range.upper)
        let endsAtLineStart = range.upper == text.lineStart(final)
        let last = range.upper > range.lower && endsAtLineStart ? max(first, final - 1) : final
        guard text.lineStart(first) == range.lower,
            endsAtLineStart || range.upper == text.lineRange(final, includeEnding: false).upper,
            !range.isEmpty || range.lower == text.byteCount
                || text.lineRange(first, includeEnding: false).isEmpty,
            last - first < 128
        else {
            throw NateError.message("链接页须为至多 128 个完整物理行，未采用局部候选。")
        }
        let original = text.text(in: range)
        var scanner = try TextLinkScanner(
            text: original,
            settings: settings,
            deadline: deadline,
            permit: permit
        )
        let bytes = Array(original.utf8)
        var prepared: [DocumentTextLink] = []
        for candidate in try scanner.candidates() {
            try work.check()
            let lower = scanner.byteOffsets[candidate.range.lowerBound]
            let upper = scanner.byteOffsets[candidate.range.upperBound]
            let value = String(decoding: bytes[lower..<upper], as: UTF8.self)
            if let target = try TextLinkTarget.url(for: value, prefixLength: candidate.prefixLength) {
                prepared.append(
                    DocumentTextLink(
                        range: ByteRange(range.lower + lower, range.lower + upper),
                        rawText: value,
                        target: target
                    )
                )
            }
        }
        try work.check()
        links = prepared
    }

    /// 业务作用：同编号或同修订的另一份正文也不能复用旧链接，完整配置改变同样撤销原点击证据。
    /// 参数说明:
    /// - snapshot: 当前准备绘制或接受点击的完整正文快照。
    /// - settings: 当前视图实际使用的完整链接配置。
    /// 返回：文档身份、修订、不可变根和配置全部保持时为真。
    public func matches(_ snapshot: DocumentSnapshot, settings: TextLinkSettings) -> Bool {
        documentID == snapshot.id && revision == snapshot.revision
            && sourceIdentity == snapshot.text.sourceIdentity && self.settings == settings
    }

    /// 业务作用：点击候选只从已经完整发布的非交叠范围查询，不沿原文重新猜测目标边界。
    /// 参数说明:
    /// - position: 此固定链接页所绑定原文的 UTF-8 字节位置。
    /// 返回：包含该位置的完整链接；页外、链接之外或末端之后为空，正文不变。
    public func link(containing position: Int) -> DocumentTextLink? {
        guard position >= range.lower, position < range.upper else {
            return nil
        }
        var lower = 0
        var upper = links.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if links[middle].range.upper <= position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < links.count, links[lower].range.lower <= position else {
            return nil
        }
        return links[lower]
    }
}
