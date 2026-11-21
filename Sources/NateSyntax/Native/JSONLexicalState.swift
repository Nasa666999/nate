import Foundation
import NateCore

enum JSONContainer: Sendable, Equatable {
    case object(expectingKey: Bool)
    case array
}

struct JSONLexicalState: Sendable, Equatable {
    var extended: Bool?
    var containers: [JSONContainer] = []
    var quote: UInt8?
    var propertyString = false
    var escape = false
    var invalidEscape = false
    var hexadecimalDigits = 0
    var skipLineFeed = false
    var lineComment = false
    var blockComment = false
    var blockStar = false

    var expectsProperty: Bool {
        if case .object(let expecting)? = containers.last {
            return expecting
        }
        return false
    }

    /// 业务作用：属性起点已被字符串或名称占用后，后续值不再继承属性呈现类别。
    /// 参数说明: 无。
    /// 返回：只推进当前对象的属性阶段，数组与外层容器保持原状。
    mutating func consumeProperty() {
        if case .object? = containers.last {
            containers[containers.count - 1] = .object(expectingKey: false)
        }
    }
}

struct JSONLexingBudget {
    let deadline: ContinuousClock.Instant
    private var remaining = 4_194_304
    private var steps = 0

    /// 业务作用：本行词法遍历、数字验证和转义处理共用所属扫描器的截止，不为长词元重新授予时间。
    /// 参数说明:
    /// - deadline: 当前快照扫描器已经取得的共同截止。
    /// 返回：有四百万步上限且仍沿原截止的独立行预算。
    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    /// 业务作用：所有字符处理共用有限工作量，并在固定间隔响应真实取消与超时。
    /// 参数说明: 无。
    /// 返回：仍有完整执行资格时继续，超限或取消时抛错，调用方不得发布部分词法状态。
    mutating func consume() throws {
        guard remaining > 0 else {
            throw NateError.message("JSON 词法扫描超过四百万步，当前范围保持中性呈现。")
        }
        remaining -= 1
        steps += 1
        if steps & 255 == 0 {
            try check()
        }
    }

    /// 业务作用：原子发布前复验共同截止，最后不足检查间隔的词元也不能绕过失权门禁。
    /// 参数说明: 无。
    /// 返回：取消或超时明确失败，正文及前一个完整检查点不被改写。
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("JSON 词法扫描超过共同截止，当前范围保持中性呈现。")
        }
    }
}
