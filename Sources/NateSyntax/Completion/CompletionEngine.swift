import Foundation
import NateCore

public struct CompletionCandidate: Sendable {
    public let text: String
    public let detail: String

    /// 业务作用：携带待插入候选与可检查来源，不持有文档正文。
    /// 参数说明:
    /// - text: 确认后插入的完整候选。
    /// - detail: 来源或签名。
    /// 返回：独立候选值。
    public init(text: String, detail: String) {
        self.text = text
        self.detail = detail
    }
}

public struct CompletionContext: Sendable {
    public let range: ByteRange
    public let prefix: String
    public let prefixExceedsLimit: Bool

    /// 业务作用：固定候选替换的前缀范围，确认时必须复验修订。
    /// 参数说明:
    /// - range: 修改前 UTF-8 前缀范围。
    /// - prefix: 用户已输入前缀。
    /// - prefixExceedsLimit: 当前词的前缀超限时，仅保留原光标供参数提示定位。
    /// 返回：待补全上下文。
    public init(range: ByteRange, prefix: String, prefixExceedsLimit: Bool = false) {
        self.range = range
        self.prefix = prefix
        self.prefixExceedsLimit = prefixExceedsLimit
    }
}

public struct CompletionResult: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let context: CompletionContext
    public let candidates: [CompletionCandidate]
    public let limited: Bool

    /// 业务作用：将后台候选绑定原文档和修订，界面只发布有证据的建议。
    /// 参数说明:
    /// - documentID: 文档生命周期。
    /// - revision: 原始正文修订。
    /// - context: 前缀范围。
    /// - candidates: 有界候选集合。
    /// - limited: 是否触及扫描或输出预算。
    /// 返回：可跨执行域传递的完整结果。
    public init(
        documentID: UUID,
        revision: UInt64,
        context: CompletionContext,
        candidates: [CompletionCandidate],
        limited: Bool
    ) {
        self.documentID = documentID
        self.revision = revision
        self.context = context
        self.candidates = candidates
        self.limited = limited
    }
}

public struct SignatureHint: Sendable {
    public let name: String
    public let argument: Int
    public let openingByte: Int
    public let overloads: [CompletionOverload]
}

public enum CompletionEngine {
    private static let maximumPrefixBytes = 4096

    /// 业务作用：从当前光标提取待补全前缀，多选区不静默缩为一个目标。
    /// 参数说明:
    /// - snapshot: 固定正文快照。
    /// - selections: 当前视图选区。
    /// - additional: 语言补全表允许的额外词字符。
    /// - wordBoundaries: 当前编辑器固定的默认及附加词字符规则。
    /// 返回：原标量边界上的完整替换前缀；超限时只保留光标，非单一普通光标时拒绝。
    public static func context(
        in snapshot: DocumentSnapshot,
        selections: [TextSelection],
        additional: String = "",
        wordBoundaries: WordBoundarySettings = WordBoundarySettings()
    ) throws -> CompletionContext {
        guard selections.count == 1, let selection = selections.first, selection.range.isEmpty,
            selection.virtualColumn == 0, snapshot.text.isBoundary(selection.head)
        else {
            throw NateError.message("补全需要一个普通光标，不能应用到多选区或虚拟空白列。")
        }
        let head = selection.head
        let lineStart = snapshot.text.lineStart(snapshot.text.lineNumber(at: head))
        var start = max(lineStart, head - maximumPrefixBytes)
        while !snapshot.text.isBoundary(start) {
            start += 1
        }
        let preceding = snapshot.text.text(in: ByteRange(start, head))
        let words = CompletionWordCharacters(settings: wordBoundaries, additional: additional)
        let suffix = preceding.unicodeScalars.reversed().prefix(while: words.contains).reversed()
        let prefix = String(String.UnicodeScalarView(suffix))
        let lower = head - prefix.utf8.count
        // 窗口从同一个词的中间开始时，仅保留光标。后缀的原字节即使匹配，也不能冒充完整前缀。
        if lower == start, start > lineStart,
            words.continues(in: snapshot.text, at: start, preceding: true)
        {
            return CompletionContext(range: ByteRange(head, head), prefix: "", prefixExceedsLimit: true)
        }
        return CompletionContext(range: ByteRange(lower, head), prefix: prefix)
    }

    /// 业务作用：合并语言与文档候选，扫描和结果均有容量界限且可取消。
    /// 参数说明:
    /// - snapshot: 任务固定快照。
    /// - context: 同一快照中的前缀范围。
    /// - definition: 独立补全表，可为空。
    /// - keywords: 当前语言或 UDL 关键字。
    /// - documentWords: 是否包含文档单词。
    /// - languageWords: 是否包含语言关键字与函数。
    /// - wordBoundaries: 与前缀提取相同的编辑器词字符规则。
    /// 返回：至多 200 个候选及范围受限标志，不携带全文副本。
    public static func suggest(
        snapshot: DocumentSnapshot,
        context: CompletionContext,
        definition: CompletionDefinition?,
        keywords: [String],
        documentWords: Bool = true,
        languageWords: Bool = true,
        wordBoundaries: WordBoundarySettings = WordBoundarySettings()
    ) throws -> CompletionResult {
        try Task.checkCancellation()
        guard context.range.lower <= context.range.upper,
            snapshot.text.isBoundary(context.range.lower), snapshot.text.isBoundary(context.range.upper),
            context.range.count <= maximumPrefixBytes,
            snapshot.text.bytes(in: context.range).elementsEqual(context.prefix.utf8)
        else {
            throw NateError.invalidRange
        }
        if context.prefixExceedsLimit {
            return CompletionResult(
                documentID: snapshot.id,
                revision: snapshot.revision,
                context: context,
                candidates: [],
                limited: true
            )
        }
        let fold = definition?.ignoresCase == true
        let prefix = fold ? context.prefix.lowercased() : context.prefix
        var values: [String: CompletionCandidate] = [:]
        var limited = false
        if languageWords {
            for entry in definition?.entries ?? [] {
                try Task.checkCancellation()
                let name = fold ? entry.name.lowercased() : entry.name
                guard name.hasPrefix(prefix), entry.name != context.prefix else {
                    continue
                }
                let detail: String
                if let overload = entry.overloads.first {
                    let parameters = overload.parameters.joined(separator: ", ")
                    detail = "\(entry.name)(\(parameters)) → \(overload.returnType)\n\(overload.description)"
                }
                else {
                    detail = entry.isFunction ? "语言函数" : "语言关键字"
                }
                values[entry.name] = CompletionCandidate(text: entry.name, detail: detail)
            }
            for word in keywords
            where (fold ? word.lowercased() : word).hasPrefix(prefix) && word != context.prefix {
                if values[word] == nil {
                    values[word] = CompletionCandidate(text: word, detail: "语言关键字")
                }
            }
        }
        if documentWords {
            let budget = 16 * 1024 * 1024
            var lower = max(0, context.range.upper - budget / 2)
            var upper = min(snapshot.text.byteCount, lower + budget)
            if upper == snapshot.text.byteCount {
                lower = max(0, upper - budget)
            }
            while !snapshot.text.isBoundary(lower) {
                lower += 1
            }
            while !snapshot.text.isBoundary(upper) {
                upper -= 1
            }
            limited = lower > 0 || upper < snapshot.text.byteCount
            let text = snapshot.text.text(in: ByteRange(lower, upper))
            let words = CompletionWordCharacters(
                settings: wordBoundaries,
                additional: definition?.additionalWordCharacters ?? ""
            )
            var word = String.UnicodeScalarView()
            var wordLength = 0
            // 只把窗口内确认了两端的完整词加入候选，文档范围截断的左右词片段没有替换资格。
            var wordOverflowed = words.continues(in: snapshot.text, at: lower, preceding: true)
            var wordStart = lower
            var position = lower
            var visited = 0

            /// 业务作用：候选来自光标以外的完整词，光标右侧已有后缀只保留在原正文。
            /// 参数说明:
            /// - end: 当前文档词的末尾字节位置。
            /// 返回：范围有资格且符合前缀时保存候选，源文字节保持不变。
            func recordWord(endingAt end: Int) {
                guard !wordOverflowed, !word.isEmpty,
                    context.range.upper < wordStart || context.range.upper > end
                else {
                    return
                }
                let value = String(word)
                if value != context.prefix && (fold ? value.lowercased() : value).hasPrefix(prefix)
                    && values[value] == nil
                {
                    values[value] = CompletionCandidate(text: value, detail: "文档单词")
                }
            }

            for scalar in text.unicodeScalars {
                let start = position
                position += scalar.utf8.count
                visited += 1
                if visited % 4096 == 0 {
                    try Task.checkCancellation()
                }
                if words.contains(scalar) {
                    if !wordOverflowed && wordLength < 4096 {
                        if wordLength == 0 {
                            wordStart = start
                        }
                        word.append(scalar)
                        wordLength += 1
                    }
                    else {
                        wordOverflowed = true
                    }
                }
                else if !word.isEmpty || wordOverflowed {
                    recordWord(endingAt: start)
                    word = String.UnicodeScalarView()
                    wordLength = 0
                    wordOverflowed = false
                    if values.count >= 100_000 {
                        limited = true
                        break
                    }
                }
            }
            if !words.continues(in: snapshot.text, at: upper, preceding: false) {
                recordWord(endingAt: upper)
            }
        }
        if values.count > 200 {
            limited = true
        }
        let ordered = values.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.prefix(200)
        return CompletionResult(
            documentID: snapshot.id,
            revision: snapshot.revision,
            context: context,
            candidates: ordered.compactMap {
                values[$0]
            },
            limited: limited
        )
    }

    /// 业务作用：识别函数名称中的原语言标识字符及调用语法使用的附加符号。
    /// 参数说明:
    /// - scalar: 当前 Unicode 标量。
    /// - additional: 语言显式词字符。
    /// 返回：可以连续构成补全前缀时为真。
    static func isWord(_ scalar: Unicode.Scalar, additional: String) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            || [.nonspacingMark, .spacingMark, .enclosingMark].contains(scalar.properties.generalCategory)
            || scalar == "_" || scalar == "$" || additional.unicodeScalars.contains(scalar)
    }
}

private struct CompletionWordCharacters {
    let settings: WordBoundarySettings
    let additional: Set<UInt32>

    /// 业务作用：固定同一次候选计算的编辑器词规则与语言附加字符。
    /// 参数说明:
    /// - settings: 用户实际启用的编辑器词规则及其草稿。
    /// - additional: 当前语言补全词表定义的附加字符。
    /// 返回：可用于完整前缀和文档单词的同一分类器，行段边界不会进入单词。
    init(settings: WordBoundarySettings, additional: String) {
        self.settings = settings
        self.additional = Set(additional.unicodeScalars.map(\.value)).subtracting([
            0, 10, 13, 0x85, 0x2028, 0x2029,
        ])
    }

    /// 业务作用：判断前缀与候选词使用的完整标量，支持语言资源和用户附加字符。
    /// 参数说明:
    /// - scalar: 当前正文中的完整 Unicode 标量。
    /// 返回：属于文档补全词时为真，保留语言标识常用的美元符号。
    func contains(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 36 || settings.contains(scalar.value) || additional.contains(scalar.value)
    }

    /// 业务作用：只检查窗口之外相邻的一个标量，确认窗口内的词是否被截断。
    /// 参数说明:
    /// - text: 建立候选窗口时使用的同一正文树。
    /// - offset: 已对齐完整标量的窗口边界。
    /// - preceding: 取窗口左边界之前的字符；关闭时取右边界之后的字符。
    /// 返回：界外相邻字符仍属于词时为真；抵达文件边界时为假。
    func continues(in text: PieceTree, at offset: Int, preceding: Bool) -> Bool {
        guard preceding ? offset > 0 : offset < text.byteCount else {
            return false
        }
        var adjacent = offset + (preceding ? -1 : 1)
        while !text.isBoundary(adjacent) {
            adjacent += preceding ? -1 : 1
        }
        let range = preceding ? ByteRange(adjacent, offset) : ByteRange(offset, adjacent)
        return text.text(in: range).unicodeScalars.first.map(contains) ?? false
    }
}
