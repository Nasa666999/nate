import Foundation
import NateCore

struct RustLexing {
    static let groupNames = ["instre1", "instre2", "type1", "type2", "type3", "type4", "type5"]
    let bytes: [UInt8]
    let base: Int
    let groups: [Set<Data>]
    var state: RustLexicalState
    var budget: ANSILexingBudget
    var cursor = 0
    var segment = 0
    var classes: [UInt8]

    /// 业务作用：Rust 的原字节分类使用独立七组词表与字面状态，显示断行不截断同一物理行。
    /// 参数说明:
    /// - text: 当前请求的完整原标量范围。
    /// - base: 请求在固定正文中的原字节起点。
    /// - snapshot: 用于物理行、原字节和来源身份的固定正文。
    /// - language: 当前完整 Rust 资源。
    /// - resource: 扫描器建立时固定的完整规则字节。
    /// - deadline: 所属完整操作的共同截止。
    /// - state: 连续范围状态，任何失败只设置诊断。
    /// 返回：完整标量上的样式；来源、词表、容量或执行资格不足时不发布部分检查点。
    static func highlight(
        _ text: String,
        base: Int,
        snapshot: DocumentSnapshot?,
        language: LanguageDefinition,
        resource: Data?,
        deadline: ContinuousClock.Instant,
        state: inout SyntaxState
    ) -> [SyntaxToken] {
        guard state.diagnostic == nil else {
            return []
        }
        do {
            var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 16_777_216)
            try budget.check()
            guard text.utf8.count <= 1_048_576, base >= 0, base <= Int.max - text.utf8.count,
                state.rust.nextOffset == nil || state.rust.nextOffset == base,
                let styles = language.lexicalStyles, styles.count <= 256,
                (0...25).allSatisfy({
                    styles[String($0)] != nil
                }),
                let resource, resource.count <= 4 * 1024 * 1024,
                let words = language.keywordGroups,
                groupNames.allSatisfy({
                    words[$0] != nil
                }),
                state.rust.resource == nil || state.rust.resource == resource
            else {
                throw NateError.message("Rust 高亮缺少完整样式、连续范围或相同规则来源。")
            }
            let requested = ByteRange(base, base + text.utf8.count)
            var current = state.rust
            if let snapshot {
                let tree = snapshot.text
                // 修订和文档名相同仍不足以证明同一正文，结构共享根身份必须同时一致。
                guard current.documentID == nil || current.documentID == snapshot.id,
                    current.nextOffset != nil || base == 0,
                    current.revision == nil || current.revision == snapshot.revision,
                    current.sourceIdentity == nil || current.sourceIdentity == tree.sourceIdentity,
                    tree.isBoundary(requested.lower), tree.isBoundary(requested.upper),
                    !(tree.byte(at: requested.lower - 1) == 13 && tree.byte(at: requested.lower) == 10),
                    !(tree.byte(at: requested.upper - 1) == 13 && tree.byte(at: requested.upper) == 10),
                    tree.bytes(in: requested).elementsEqual(text.utf8)
                else {
                    throw NateError.message("Rust 高亮范围与固定正文或检查点来源不一致。")
                }
                current.documentID = snapshot.id
                current.revision = snapshot.revision
                current.sourceIdentity = tree.sourceIdentity
            }
            else if current.sourceIdentity != nil {
                throw NateError.message("Rust 连续高亮不能失去原固定正文证据。")
            }
            if current.cachedRange == nil {
                let range: ByteRange
                let source: [UInt8]
                if let snapshot, !requested.isEmpty {
                    range = try ANSILexing.physicalRange(requested, tree: snapshot.text, budget: &budget)
                    guard range.lower == requested.lower, range.count <= 1_048_576 else {
                        throw NateError.message("Rust 高亮缺少物理行首检查点或超过单行 1 MiB。")
                    }
                    source = snapshot.text.bytes(in: range)
                }
                else {
                    range = requested
                    source = Array(text.utf8)
                }
                let groups = groupNames.map {
                    Set(
                        (words[$0] ?? []).map {
                            Data($0.utf8)
                        }
                    )
                }
                var scanner = RustLexing(
                    bytes: source,
                    base: range.lower,
                    groups: groups,
                    state: current,
                    budget: budget,
                    classes: Array(repeating: 0, count: source.count)
                )
                let initial = RustLiteralState(
                    style: current.style,
                    depth: current.depth,
                    hashes: current.hashes,
                    lineComment: current.lineComment
                )
                try scanner.scan()
                current = scanner.state
                current.cachedInitial = initial
                current.cachedRange = range
                current.cachedClasses = scanner.classes
                budget = scanner.budget
            }
            guard let range = current.cachedRange, requested.lower >= range.lower,
                requested.upper <= range.upper, current.cachedClasses.count == range.count
            else {
                throw NateError.message("Rust 显示分段不属于已确认的完整物理范围。")
            }
            let output = try tokens(
                text,
                base: base,
                origin: range.lower,
                classes: current.cachedClasses,
                styles: styles,
                budget: &budget
            )
            if requested.upper == range.upper {
                current.cachedRange = nil
                current.cachedClasses = []
                current.cachedInitial = nil
            }
            current.resource = resource
            current.nextOffset = requested.upper
            // 完整物理范围与当前显示投影均准备成功后才发布状态，旧任务不能留下可复用的半份类别。
            try budget.check()
            state.rust = current
            return output
        }
        catch {
            state.diagnostic = error.localizedDescription
            return []
        }
    }

    /// 业务作用：原字节类别按标量首字节投影为完整 Unicode 范围，词法错误也不能切开 UTF-8。
    /// 参数说明:
    /// - text: 当前已验证的请求正文。
    /// - base: 请求原字节起点。
    /// - origin: 完整物理类别的原字节起点。
    /// - classes: 完整物理范围的原字节类别。
    /// - styles: 固定资源中的全部样式。
    /// - budget: 与扫描共用的执行预算。
    /// 返回：最多 65536 个完整词元，超量或样式缺席时整体拒绝。
    static func tokens(
        _ text: String,
        base: Int,
        origin: Int,
        classes: [UInt8],
        styles: [String: LanguageTokenStyle],
        budget: inout ANSILexingBudget
    ) throws -> [SyntaxToken] {
        var output: [SyntaxToken] = []
        var offset = base
        var start = base
        var style: UInt8?
        for scalar in text.unicodeScalars {
            try budget.consume()
            let actual = classes[offset - origin]
            if let previous = style, actual != previous {
                try appendToken(start..<offset, style: previous, styles: styles, output: &output)
                start = offset
            }
            style = actual
            offset += scalar.utf8.count
        }
        if let style {
            try appendToken(start..<offset, style: style, styles: styles, output: &output)
        }
        return output
    }

    /// 业务作用：同一词法身份映射到独立默认类别，字符串与注释对结构分析保持不透明。
    /// 参数说明:
    /// - range: 已确认的完整原标量范围。
    /// - style: Rust 原生样式编号。
    /// - styles: 当前完整资源样式。
    /// - output: 尚未对外发布的全部词元。
    /// 返回：完整词元加入有界结果，缺少配置不降级为另一类别。
    private static func appendToken(
        _ range: Range<Int>,
        style: UInt8,
        styles: [String: LanguageTokenStyle],
        output: inout [SyntaxToken]
    ) throws {
        guard output.count < 65_536, let attributes = styles[String(style)] else {
            throw NateError.message("Rust 高亮超过词元容量或缺少当前样式。")
        }
        let kind: SyntaxKind
        switch style {
        case 1...4: kind = .comment
        case 5: kind = .number
        case 6...12: kind = .keyword
        case 13...15, 21...25: kind = .string
        case 16: kind = .punctuation
        case 18, 19: kind = .tag
        default: kind = .text
        }
        output.append(
            SyntaxToken(
                range: ByteRange(range.lowerBound, range.upperBound),
                kind: kind,
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: "rust:" + String(style)
            )
        )
    }
}
