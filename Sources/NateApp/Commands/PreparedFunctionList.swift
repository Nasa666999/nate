import Foundation
import NateCore
import NateSearch
import NateSyntax

struct PreparedFunctionList: Sendable {
    let definition: FunctionListDefinition
    private let patterns: [Data: PreparedStructurePattern]

    /// 业务作用：原始规则、全部可编译表达式和独立类别容量一起校验，未通过的用户 XML 不可覆盖已有资源。
    /// 参数说明:
    /// - definition: 已通过 XML 结构校验的函数列表定义。
    /// - allowsBundledLookbehind: 规则是否由应用包原始资源直接取得，用于保留少数随包规则兼容性。
    /// - permit: 当前资源继续解析的资格。
    /// 返回：不可变的结构规则和执行树，任意表达式失败均不交付部分定义。
    init(
        _ definition: FunctionListDefinition,
        allowsBundledLookbehind: Bool = false,
        permit: @escaping @Sendable () -> Bool = { true }
    ) throws {
        self.definition = definition
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var patterns: [Data: PreparedStructurePattern] = [:]
        for expression in definition.expressions {
            let key = Data(expression.utf8)
            if patterns[key] == nil {
                do {
                    patterns[key] = try PreparedStructurePattern(
                        expression,
                        allowsBundledLookbehind: allowsBundledLookbehind,
                        permit: { permit() && ContinuousClock.now < deadline }
                    )
                }
                catch is CancellationError {
                    try Self.requireTime(until: deadline)
                    throw CancellationError()
                }
                catch {
                    throw NateError.message(
                        "函数列表第 \(patterns.count + 1) 项表达式无法编译：\(error.localizedDescription)"
                    )
                }
            }
        }
        try Self.requireTime(until: deadline)
        guard permit() else {
            throw CancellationError()
        }
        self.patterns = patterns
    }

    /// 业务作用：同一正文的主规则、名称链和类边界共用已经编译的规则和一次实际截止。
    /// 参数说明:
    /// - snapshot: 本次结构导航所依赖的完整不可变正文。
    /// 返回：所有结构结果属于该修订，缺失规则、越界、取消或超时拒绝整份结果。
    func outline(in snapshot: DocumentSnapshot) throws -> FunctionOutline {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let input = PreparedSearchInput(snapshot: snapshot)
        let outline = try FunctionListEngine.analyze(snapshot: snapshot, definition: definition) {
            expression,
            scope,
            first in
            try Self.requireTime(until: deadline)
            guard let pattern = patterns[Data(expression.utf8)] else {
                throw NateError.message("函数列表执行缺失已验证的表达式。")
            }
            do {
                return try input.structureRanges(
                    pattern,
                    in: scope,
                    firstOnly: first,
                    permit: { ContinuousClock.now < deadline }
                )
            }
            catch is CancellationError {
                try Self.requireTime(until: deadline)
                throw CancellationError()
            }
        }
        try Self.requireTime(until: deadline)
        return outline
    }

    /// 业务作用：取消与真实计算超时分别报告，函数列表不能把超限伪装成零条结果。
    /// 参数说明:
    /// - deadline: 当前整份规则准备或结构执行的总截止。
    /// 返回：正在执行且未超时才允许继续，否则拒绝发布旧结构。
    private static func requireTime(until deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("函数列表超过整份规则的 8 秒预算。")
        }
    }
}
