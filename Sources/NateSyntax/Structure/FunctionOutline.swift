import Foundation
import NateCore

public struct FunctionSymbol: Sendable {
    public let name: String
    public let range: ByteRange
    public let isContainer: Bool
    public let children: [FunctionSymbol]
}

public struct FunctionOutline: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let definitionID: String
    public let symbols: [FunctionSymbol]
}

public typealias StructureSearch = @Sendable (String, ByteRange, Bool) throws -> [ByteRange]

private struct ParsedContainer {
    let name: String
    let nameRange: ByteRange
    let body: ByteRange
    var children: [FunctionSymbol] = []
}

public enum FunctionListEngine {
    /// 业务作用：按独立 XML 规则提取类与函数，正则能力通过窄闭包注入而不引入模块循环。
    /// 参数说明:
    /// - snapshot: 固定的已提交正文。
    /// - definition: 当前语言的完整函数列表规则。
    /// - search: 同一快照中的有界正则搜索，最后一个参数表示只取首个命中。
    /// 返回：与正文身份和修订绑定的可导航结构；任一规则失败则不发布部分列表。
    public static func analyze(
        snapshot: DocumentSnapshot,
        definition: FunctionListDefinition,
        search: @escaping StructureSearch
    ) throws -> FunctionOutline {
        guard snapshot.text.byteCount <= 64 * 1024 * 1024 else {
            throw NateError.message("函数列表正文超过 64 MB 预算。")
        }
        var scanner = OutlineScanner(snapshot: snapshot, definition: definition, search: search)
        return try scanner.analyze()
    }
}

private struct OutlineScanner {
    let snapshot: DocumentSnapshot
    let definition: FunctionListDefinition
    let search: StructureSearch
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    var comments: [ByteRange] = []
    var count = 0

    /// 业务作用：先识别注释和类边界，再归属函数，正文中的注释不成为可导航条目。
    /// 参数说明: 无。
    /// 返回：完整结构快照，名称相同但位置不同的声明独立保留。
    mutating func analyze() throws -> FunctionOutline {
        let full = ByteRange(0, snapshot.text.byteCount)
        if let expression = definition.commentExpression {
            comments = try matches(expression, within: full).filter {
                !$0.isEmpty
            }
        }
        var containers: [ParsedContainer] = []
        if let rule = definition.classRule {
            let openings =
                try rule.openingExpression.map {
                    try matches($0, within: full)
                } ?? []
            let closings =
                try rule.closingExpression.map {
                    try matches($0, within: full)
                } ?? []
            let boundaries =
                (openings.map {
                    ($0, true)
                }
                + closings.map {
                    ($0, false)
                })
                .filter {
                    !$0.0.isEmpty && !inComment($0.0.lower)
                }
                .sorted {
                    $0.0.lower == $1.0.lower ? $0.1 && !$1.1 : $0.0.lower < $1.0.lower
                }
            var stack: [Int] = []
            var ends: [Int: Int] = [:]
            for (range, opening) in boundaries {
                try checkpoint()
                if opening {
                    stack.append(range.upper)
                }
                else if let start = stack.popLast() {
                    ends[start] = range.upper
                }
            }
            for start in stack {
                ends[start] = full.upper
            }
            let validOpenings = boundaries.filter {
                $0.1
            }.map {
                $0.0
            }
            for head in try matches(rule.expression, within: full) where !inComment(head.lower) {
                try checkpoint()
                guard !head.isEmpty,
                    let name = try nameRange(rule.nameExpressions, within: head)
                else {
                    continue
                }
                var end = head.upper
                if rule.openingExpression != nil {
                    var lower = 0
                    var upper = validOpenings.count
                    while lower < upper {
                        let middle = lower + (upper - lower) / 2
                        if validOpenings[middle].upper <= head.upper {
                            lower = middle + 1
                        }
                        else {
                            upper = middle
                        }
                    }
                    guard lower > 0, validOpenings[lower - 1].lower >= head.lower else {
                        throw NateError.message("类主规则没有包含声明的开启边界。")
                    }
                    // 未闭合边界延伸至末尾，不能把内部方法发布为全局函数。
                    end = ends[validOpenings[lower - 1].upper] ?? full.upper
                }
                containers.append(
                    ParsedContainer(name: try title(name), nameRange: name, body: ByteRange(head.lower, end))
                )
            }
        }
        var parents: [Int?] = []
        var stack: [Int] = []
        var childIndices: [Int: [Int]] = [:]
        for index in containers.indices {
            while let last = stack.last, containers[last].body.upper <= containers[index].body.lower {
                stack.removeLast()
            }
            let parent = stack.last
            // 交叉范围无法构成确定的类树，不能把方法任意归属到其中一个声明。
            if let parent, containers[index].body.upper > containers[parent].body.upper {
                throw NateError.message("函数列表类规则产生交叉范围。")
            }
            parents.append(parent)
            if let parent {
                childIndices[parent, default: []].append(index)
            }
            stack.append(index)
            guard stack.count <= 128 else {
                throw NateError.message("函数列表类嵌套超过 128 层。")
            }
        }
        if let rule = definition.classRule {
            for index in containers.indices {
                containers[index].children = try functions(rule.function, within: containers[index].body)
                    .filter {
                        owner(of: $0.range.lower, containers: containers, parents: parents) == index
                    }
            }
        }
        var globals: [FunctionSymbol] = []
        if let rule = definition.functionRule {
            globals = try functions(rule, within: full).filter {
                symbol in
                owner(of: symbol.range.lower, containers: containers, parents: parents) == nil
            }
        }
        var roots = containers.indices.filter {
            parents[$0] == nil
        }.flatMap {
            index in
            containerSymbols(index, containers: containers, childIndices: childIndices)
        }
        roots += globals
        roots.sort {
            $0.range.lower < $1.range.lower
        }
        return FunctionOutline(
            documentID: snapshot.id,
            revision: snapshot.revision,
            definitionID: definition.id,
            symbols: roots
        )
    }

    /// 业务作用：提取函数主规则并逐层收窄名称范围，外部类名规则形成独立分组。
    /// 参数说明:
    /// - rule: 单位函数或类内函数规则。
    /// - scope: 该规则允许消费的正文范围。
    /// 返回：带精确导航范围的条目；未参与的名称不显示为空函数。
    mutating func functions(_ rule: FunctionRule, within scope: ByteRange) throws -> [FunctionSymbol] {
        var result: [FunctionSymbol] = []
        var groups: [String: Int] = [:]
        var groupedChildren: [Int: [FunctionSymbol]] = [:]
        var seen: Set<ByteRange> = []
        for hit in try matches(rule.expression, within: scope) {
            try checkpoint()
            guard !hit.isEmpty, !inComment(hit.lower),
                let name = try nameRange(rule.nameExpressions, within: hit), !inComment(name.lower),
                seen.insert(name).inserted
            else {
                continue
            }
            let symbol = FunctionSymbol(name: try title(name), range: name, isContainer: false, children: [])
            if !rule.classExpressions.isEmpty,
                let parent = try nameRange(rule.classExpressions, within: hit)
            {
                let label = try title(parent)
                if let mode = rule.displayMode, mode.contains("$functionName") {
                    result.append(
                        FunctionSymbol(
                            name: mode.replacingOccurrences(of: "$className", with: label)
                                .replacingOccurrences(of: "$functionName", with: symbol.name),
                            range: name,
                            isContainer: false,
                            children: []
                        )
                    )
                    continue
                }
                if let index = groups[label] {
                    groupedChildren[index, default: []].append(symbol)
                }
                else {
                    groups[label] = result.count
                    groupedChildren[result.count] = [symbol]
                    result.append(
                        FunctionSymbol(name: label, range: parent, isContainer: true, children: [])
                    )
                }
            }
            else {
                result.append(symbol)
            }
        }
        for (index, children) in groupedChildren {
            let group = result[index]
            result[index] = FunctionSymbol(
                name: group.name,
                range: group.range,
                isContainer: true,
                children: children
            )
        }
        return result
    }

    /// 业务作用：按已配对的类范围寻找最内层归属，类结束后的函数不会继承最近一个类名。
    /// 参数说明:
    /// - position: 函数名称起点。
    /// - containers: 按源码位置排序的类范围。
    /// - parents: 对应的直接父类索引。
    /// 返回：最内层包含该位置的类；全局函数为空。
    func owner(of position: Int, containers: [ParsedContainer], parents: [Int?]) -> Int? {
        var lower = 0
        var upper = containers.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if containers[middle].body.lower <= position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        var candidate: Int? = lower > 0 ? lower - 1 : nil
        while let index = candidate {
            if position < containers[index].body.upper {
                return index
            }
            candidate = parents[index]
        }
        return nil
    }

    /// 业务作用：嵌套类和方法只归属一个父节点，资源要求扁平模板时保留其显示约定。
    /// 参数说明:
    /// - index: 当前类索引。
    /// - containers: 已完成函数归属的类列表。
    /// - childIndices: 每个类的直接子类索引。
    /// 返回：当前类树，或资源模板指定的函数条目。
    func containerSymbols(
        _ index: Int,
        containers: [ParsedContainer],
        childIndices: [Int: [Int]]
    ) -> [FunctionSymbol] {
        let container = containers[index]
        var children = container.children
        children += (childIndices[index] ?? []).flatMap {
            containerSymbols($0, containers: containers, childIndices: childIndices)
        }
        children.sort {
            $0.range.lower < $1.range.lower
        }
        if let mode = definition.classRule?.displayMode, mode.contains("$functionName") {
            return children.map {
                FunctionSymbol(
                    name: mode.replacingOccurrences(of: "$className", with: container.name)
                        .replacingOccurrences(of: "$functionName", with: $0.name),
                    range: $0.range,
                    isContainer: false,
                    children: $0.children
                )
            }
        }
        return [
            FunctionSymbol(
                name: container.name,
                range: container.nameRange,
                isContainer: true,
                children: children
            )
        ]
    }

    /// 业务作用：名称链的每一层仅在上一层首个命中内运行，保留原正文坐标。
    /// 参数说明:
    /// - expressions: 有序子层表达式；为空时使用完整主命中。
    /// - scope: 主规则命中范围。
    /// 返回：最终非空范围；任何一层未匹配时为空。
    mutating func nameRange(_ expressions: [String], within scope: ByteRange) throws -> ByteRange? {
        var range = scope
        for expression in expressions {
            guard let next = try matches(expression, within: range, firstOnly: true).first, !next.isEmpty
            else {
                return nil
            }
            range = next
        }
        return range.isEmpty ? nil : range
    }

    /// 业务作用：所有外部规则共享总预算，错误和取消不得转换成误导性的空列表。
    /// 参数说明:
    /// - expression: 原始规则文本。
    /// - scope: 允许的字节范围。
    /// - firstOnly: 是否只取名称链的首个命中。
    /// 返回：已验证的半开范围，任何越界或代理项分割均拒绝。
    mutating func matches(_ expression: String, within scope: ByteRange, firstOnly: Bool = false) throws
        -> [ByteRange]
    {
        try checkpoint()
        let matches = try search(expression, scope, firstOnly)
        guard matches.count <= 100_000, !firstOnly || matches.count <= 1,
            zip(matches, matches.dropFirst()).allSatisfy({
                $0.upper <= $1.lower
            }),
            matches.allSatisfy({
                $0.lower >= scope.lower && $0.upper <= scope.upper && $0.lower <= $0.upper
                    && snapshot.text.isBoundary($0.lower) && snapshot.text.isBoundary($0.upper)
            })
        else {
            throw NateError.message("函数规则产生无效范围或超过结果预算。")
        }
        return matches
    }

    /// 业务作用：检查名称长度并准备展示文本，导航继续使用未经改写的原始范围。
    /// 参数说明:
    /// - range: 最终名称范围。
    /// 返回：可读名称；超长或空白名称明确失败。
    func title(_ range: ByteRange) throws -> String {
        guard range.count <= 16_384 else {
            throw NateError.message("函数名称超过 16 KB。")
        }
        let name = snapshot.text.text(in: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NateError.message("函数规则只提取了空白名称。")
        }
        return name
    }

    /// 业务作用：用有序注释范围拒绝被注释的声明，避免每个名称重新扫描所有注释。
    /// 参数说明:
    /// - position: 声明或名称的起始字节。
    /// 返回：位置处于注释半开范围内时为真。
    func inComment(_ position: Int) -> Bool {
        var lower = 0
        var upper = comments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if comments[middle].upper <= position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower < comments.count && comments[lower].lower <= position
    }

    /// 业务作用：限制结构提取的总工作与取消延迟，失效任务不能长期占用后台执行器。
    /// 参数说明: 无。
    /// 返回：预算内继续；取消、超时或结构过多立即失败。
    mutating func checkpoint() throws {
        count += 1
        try Task.checkCancellation()
        guard count <= 500_000, ContinuousClock.now < deadline else {
            throw NateError.message("函数列表超过 8 秒或结构数量预算，请缩小文档。")
        }
    }
}
