import Foundation
import NateCore

public struct PreparedStructurePattern: Sendable {
    let options: SearchOptions
    let compiled: CompiledRegex

    /// 业务作用：函数列表发布前编译完整规则，默认使用跨行点号和用户定义的结构语法。
    /// 参数说明:
    /// - expression: XML 解码后的真实规则表达式。
    /// - allowsBundledLookbehind: 已安装的原始随包规则可以继续使用随包的固定长度后行断言。
    /// - permit: 整份资源仍有权使用计算预算的检查。
    /// 返回：适用于同一结构规则的不可变执行树，语法错误、取消或超限时拒绝。
    public init(
        _ expression: String,
        allowsBundledLookbehind: Bool = false,
        permit: @escaping @Sendable () -> Bool = { true }
    ) throws {
        var options = SearchOptions()
        options.mode = .regex
        options.query = expression
        options.dotMatchesNewline = true
        try options.validateInput()
        compiled = try RegexParser.compile(
            expression,
            caseSensitive: options.caseSensitive,
            dotMatchesNewline: options.dotMatchesNewline,
            allowsLookbehind: allowsBundledLookbehind,
            permit: permit
        )
        self.options = options
    }
}

extension PreparedSearchInput {
    /// 业务作用：重复提取结构名称时复用同一已校验的表达式，只保留可回到原正文的非空字节范围。
    /// 参数说明:
    /// - pattern: 按结构规则格式编译的表达式。
    /// - scope: 允许消费的字节范围，前向断言仍能读取同一正文。
    /// - firstOnly: 是否在第一个有效命中后停止。
    /// - permit: 整份函数列表继续执行的检查，所有规则共用同一截止。
    /// 返回：顺序稳定的完整可导航范围，代理项分割、超限或取消时整体失败。
    public func structureRanges(
        _ pattern: PreparedStructurePattern,
        in scope: ByteRange,
        firstOnly: Bool,
        permit: @escaping @Sendable () -> Bool = { true }
    ) throws -> [ByteRange] {
        var ranges: [ByteRange] = []
        _ = try SearchEngine.find(
            in: snapshot,
            input: SearchInput(snapshot.text),
            options: pattern.options,
            scope: scope,
            firstOnly: firstOnly,
            allowEmpty: false,
            limitContextToScope: false,
            permit: permit,
            structurePattern: pattern
        ) {
            range in
            guard let source = snapshot.text.byteRange(range) else {
                throw NateError.invalidRange
            }
            guard ranges.count < pattern.options.maxMatches else {
                throw NateError.message("函数列表表达式命中超过结果上限。")
            }
            ranges.append(source)
        }
        return ranges
    }
}
