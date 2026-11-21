import Foundation
import NateCore

public enum SelectedTextHighlighting {
    /// 业务作用：仅从单个实际非空选区生成智能高亮表达式，整词模式要求选择恰好覆盖完整词。
    /// 参数说明:
    /// - source: 选区所属的不可变正文。
    /// - selections: 来源视图的真实选区，不从共享文档推断克隆位置。
    /// - wholeWord: 是否要求整个选区恰好为完整词。
    /// - wordBoundaries: 来源视图固定的完整词字符规则。
    /// 返回：最多 1 MiB 的完整单行原文；普通空选区、多选、虚拟列、跨行或部分词不生成表达式，非法范围和超限失败。
    public static func expression(
        source: DocumentSnapshot,
        selections: [TextSelection],
        wholeWord: Bool,
        wordBoundaries: WordBoundarySettings = WordBoundarySettings()
    ) throws -> String? {
        guard selections.count == 1, let selection = selections.first,
            !selection.range.isEmpty, selection.virtualColumn == 0
        else {
            return nil
        }
        let range = selection.range
        guard source.text.isBoundary(range.lower), source.text.isBoundary(range.upper) else {
            throw NateError.invalidRange
        }
        guard range.count <= 1_048_576 else {
            throw NateError.message("智能高亮选区超过 1 MiB，未截断原文。")
        }
        let row = source.text.lineNumber(at: range.lower)
        guard range.upper <= source.text.lineRange(row, includeEnding: false).upper else {
            return nil
        }
        if wholeWord {
            switch source.text.wordSelection(
                at: range.lower,
                maximumScalars: 262_144,
                wordBoundaries: wordBoundaries
            ) {
            case .word(let word):
                guard word == range else {
                    return nil
                }
            case .noWord: return nil
            case .exceedsLimit:
                throw NateError.message("智能高亮单词超过 262144 个标量，未截断匹配。")
            }
        }
        return source.text.text(in: range)
    }

    /// 业务作用：仅匹配目标视口中的逻辑行，所选原文不作为正则或扩展转义解释。
    /// 参数说明:
    /// - source: 选区所属的固定正文。
    /// - selections: 原视图的完整实际选区。
    /// - target: 要显示高亮的固定正文，可以来自另一视图。
    /// - scopes: 至多 400 个有序、不交叠的可见行区间，折叠内容不扩大匹配范围。
    /// - caseSensitive: 当前实际匹配是否区分大小写。
    /// - wholeWord: 当前实际匹配是否只接受完整词。
    /// - wordBoundaries: 来源表达式及目标整词查找共同采用的完整字符规则。
    /// - permit: 本次临时匹配仍有效的执行资格。
    /// 返回：至多十万项的完整视口索引与不可定位数量；普通无效选择为空，取消、超限或两秒预算失败不返回部分索引。
    public static func prepare(
        source: DocumentSnapshot,
        selections: [TextSelection],
        target: DocumentSnapshot,
        scopes: [ByteRange],
        caseSensitive: Bool,
        wholeWord: Bool,
        wordBoundaries: WordBoundarySettings = WordBoundarySettings(),
        permit: @escaping @Sendable () -> Bool
    ) throws -> (highlights: PreparedTextHighlights?, unmapped: Int) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let allowed: @Sendable () -> Bool = {
            permit() && !Task.isCancelled && ContinuousClock.now < deadline
        }
        guard allowed() else {
            throw CancellationError()
        }
        guard
            let query = try expression(
                source: source,
                selections: selections,
                wholeWord: wholeWord,
                wordBoundaries: wordBoundaries
            )
        else {
            return (nil, 0)
        }
        guard scopes.count <= 400 else {
            throw NateError.message("智能高亮视口超过 400 个逻辑行区间。")
        }
        var options = SearchOptions()
        options.query = query
        options.caseSensitive = caseSensitive
        options.wholeWord = wholeWord
        options.wordBoundaries = wordBoundaries
        var ranges: [ByteRange] = []
        var unmapped = 0
        var previousEnd = 0
        do {
            for scope in scopes {
                guard scope.lower >= previousEnd, scope.upper >= scope.lower,
                    target.text.isBoundary(scope.lower), target.text.isBoundary(scope.upper)
                else {
                    throw NateError.invalidRange
                }
                previousEnd = scope.upper
                options.maxMatches = 100_000 - ranges.count - unmapped
                let found = try SearchEngine.find(in: target, options: options, scope: scope, permit: allowed)
                for hit in found.hits {
                    if let range = hit.range {
                        ranges.append(range)
                    }
                    else {
                        unmapped += 1
                    }
                }
            }
            let highlights = try PreparedTextHighlights(snapshot: target, ranges: ranges, permit: allowed)
            return (highlights, unmapped)
        }
        catch {
            if permit(), !Task.isCancelled, ContinuousClock.now >= deadline {
                throw NateError.message("智能高亮超过两秒，未显示部分结果；正文与选区保留。")
            }
            throw error
        }
    }
}
