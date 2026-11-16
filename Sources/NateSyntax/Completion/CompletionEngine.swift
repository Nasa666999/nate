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

    /// 业务作用：固定候选替换的前缀范围，确认时必须复验修订。
    /// 参数说明:
    /// - range: 修改前 UTF-8 前缀范围。
    /// - prefix: 用户已输入前缀。
    /// 返回：待补全上下文。
    public init(range: ByteRange, prefix: String) {
        self.range = range
        self.prefix = prefix
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
    public let overloads: [CompletionOverload]
}

public enum CompletionEngine {
    /// 业务作用：从当前光标提取待补全前缀，多选区不静默缩为一个目标。
    /// 参数说明:
    /// - snapshot: 固定正文快照。
    /// - selections: 当前视图选区。
    /// - additional: 语言补全表允许的额外词字符。
    /// 返回：原标量边界上的替换前缀；非单一普通光标时明确拒绝。
    public static func context(
        in snapshot: DocumentSnapshot,
        selections: [TextSelection],
        additional: String = ""
    ) throws -> CompletionContext {
        guard selections.count == 1, let selection = selections.first, selection.range.isEmpty,
            selection.virtualColumn == 0, snapshot.text.isBoundary(selection.head)
        else {
            throw NateError.message("补全需要一个普通光标，不能应用到多选区或虚拟空白列。")
        }
        let head = selection.head
        var start = max(snapshot.text.lineStart(snapshot.text.lineNumber(at: head)), head - 4096)
        while !snapshot.text.isBoundary(start) {
            start += 1
        }
        let preceding = snapshot.text.text(in: ByteRange(start, head))
        let suffix = preceding.unicodeScalars.reversed().prefix {
            isWord($0, additional: additional)
        }.reversed()
        let prefix = String(String.UnicodeScalarView(suffix))
        return CompletionContext(range: ByteRange(head - prefix.utf8.count, head), prefix: prefix)
    }

    /// 业务作用：合并语言与文档候选，扫描和结果均有容量界限且可取消。
    /// 参数说明:
    /// - snapshot: 任务固定快照。
    /// - context: 同一快照中的前缀范围。
    /// - definition: 独立补全表，可为空。
    /// - keywords: 当前语言或 UDL 关键字。
    /// - documentWords: 是否包含文档单词。
    /// - languageWords: 是否包含语言关键字与函数。
    /// 返回：至多 200 个候选及范围受限标志，不携带全文副本。
    public static func suggest(
        snapshot: DocumentSnapshot,
        context: CompletionContext,
        definition: CompletionDefinition?,
        keywords: [String],
        documentWords: Bool = true,
        languageWords: Bool = true
    ) throws -> CompletionResult {
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
                let detail =
                    entry.overloads.first.map {
                        entry.name + "(" + $0.parameters.joined(separator: ", ") + ") → " + $0.returnType
                            + "\n" + $0.description
                    } ?? (entry.isFunction ? "语言函数" : "语言关键字")
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
            var word = String.UnicodeScalarView()
            var wordLength = 0
            var wordOverflowed = false
            var visited = 0
            for scalar in text.unicodeScalars {
                visited += 1
                if visited % 4096 == 0 {
                    try Task.checkCancellation()
                }
                if isWord(scalar, additional: definition?.additionalWordCharacters ?? "") {
                    if wordLength < 4096 {
                        word.append(scalar)
                        wordLength += 1
                    }
                    else {
                        wordOverflowed = true
                    }
                }
                else if !word.isEmpty {
                    let value = String(word)
                    if !wordOverflowed && value != context.prefix
                        && (fold ? value.lowercased() : value).hasPrefix(prefix)
                        && values[value] == nil
                    {
                        values[value] = CompletionCandidate(text: value, detail: "文档单词")
                    }
                    word = String.UnicodeScalarView()
                    wordLength = 0
                    wordOverflowed = false
                    if values.count >= 100_000 {
                        limited = true
                        break
                    }
                }
            }
            let value = String(word)
            if !wordOverflowed && !value.isEmpty && value != context.prefix
                && (fold ? value.lowercased() : value).hasPrefix(prefix) && values[value] == nil
            {
                values[value] = CompletionCandidate(text: value, detail: "文档单词")
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

    /// 业务作用：识别 Unicode 标识词及语言资源明确添加的字符，保留组合附加符号。
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
