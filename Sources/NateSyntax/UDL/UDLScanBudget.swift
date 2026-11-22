import Foundation
import NateCore

final class UDLScanBudget {
    let deadline: ContinuousClock.Instant
    private let permit: @Sendable () -> Bool
    private var remaining = 33_554_432
    private var pending = 0
    private var nodes = 0
    private var matchers: [String: UDLLiteralMatcher] = [:]

    /// 业务作用：整行 UDL 的规则构建、字面匹配与状态发布共用工作量和所属任务截止。
    /// 参数说明:
    /// - deadline: 所属分析的共同截止，不提供时本行仍至多五秒。
    /// - permit: 当前任务继续准备的资格。
    /// 返回：独立且有界的本行预算，不向后续规则重新授予运行时间。
    init(deadline: ContinuousClock.Instant?, permit: @escaping @Sendable () -> Bool) {
        self.deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        self.permit = permit
    }

    /// 业务作用：在分配规则索引之前校验整份可变定义，运行时规则不能绕过导入容量。
    /// 参数说明:
    /// - definition: 本次固定 UDL 定义。
    /// 返回：列表、候选及字节规模合法时继续，否则不提供部分样式。
    func validate(_ definition: UDLDefinition) throws {
        try check()
        guard definition.lists.count <= 128, definition.styles.count <= 256,
            definition.originalXML.count <= 4_194_304
        else {
            throw NateError.message("UDL 定义超过列表、样式或原 XML 容量。")
        }
        var count = 0, size = 0
        for list in definition.lists.values {
            for pattern in list {
                try consume()
                count += 1
                let length = pattern.utf8.count
                guard count <= 65_536, length <= 65_536, length <= 4_194_304 - size else {
                    throw NateError.message("UDL 规则超过 65536 项、单项 64 KiB 或合计 4 MiB。")
                }
                size += length
            }
        }
    }

    /// 业务作用：规则组首次使用时建立有界字面索引，后续字节和嵌套上下文复用相同组。
    /// 参数说明:
    /// - key: 同一固定定义内明确的规则组身份。
    /// - patterns: 该组按原定义顺序排列的字面候选。
    /// - bytes: 当前完整行原字节。
    /// - offset: 当前已确认的标量边界。
    /// - ignoreCase: 当前定义的大小写规则。
    /// 返回：最长且同长优先原顺序的实际规则，不匹配时为空。
    func longest(
        key: String,
        patterns: [String],
        bytes: [UInt8],
        offset: Int,
        ignoreCase: Bool
    ) throws -> String? {
        let matcher: UDLLiteralMatcher
        if let existing = matchers[key] {
            matcher = existing
        }
        else {
            matcher = try UDLLiteralMatcher(patterns: patterns, ignoreCase: ignoreCase, budget: self)
            matchers[key] = matcher
        }
        return try matcher.longest(in: bytes, at: offset, budget: self)
    }

    /// 业务作用：规则树节点共享容量上限，多个小组不能分别申请完整索引空间。
    /// 参数说明: 无。
    /// 返回：整行所有规则组累计不超过 262144 节点时继续，否则拒绝全部结果。
    func reserveNode() throws {
        try consume()
        guard nodes < 262_144 else {
            throw NateError.message("UDL 字面索引超过 262144 个共享节点。")
        }
        nodes += 1
    }

    /// 业务作用：逐字节匹配和候选比较都有有限工作量，长规则内部仍能响应取消。
    /// 参数说明:
    /// - amount: 本步骤确定需要消费的工作量。
    /// 返回：三千二百万步以内且仍有执行资格时继续，超量或失权时抛错。
    func consume(_ amount: Int = 1) throws {
        guard amount >= 0, amount <= remaining else {
            throw NateError.message("UDL 扫描超过共同工作量预算。")
        }
        remaining -= amount
        pending += amount
        if pending >= 256 {
            pending = 0
            try check()
        }
    }

    /// 业务作用：入口及完整发布前复验资格，最后不足检查间隔的规则也不能绕过截止。
    /// 参数说明: 无。
    /// 返回：任务未取消且资格与截止有效时继续，否则保留原上下文。
    func check() throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("UDL 扫描已取消或超过共同截止。")
        }
    }
}
