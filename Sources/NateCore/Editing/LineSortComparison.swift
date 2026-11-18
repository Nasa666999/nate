import Darwin
import Foundation

enum LineSortKey {
    case units([UInt16])
    case text(String)
    case number(Double?)
    case length(Int)
}

final class DecimalLineParser {
    private let locale: locale_t

    /// 业务作用：小数转换使用独立 C 数值 locale，不改变其它线程或语言排序的全局规则。
    /// 参数说明: 无。
    /// 返回：可供本次后台计划使用的解析器；系统无法提供 locale 时整体失败。
    init() throws {
        guard let locale = newlocale(LC_NUMERIC_MASK, "C", nil) else {
            throw NateError.message("无法建立独立小数解析环境。")
        }
        self.locale = locale
    }

    /// 业务作用：同步转换已恢复原线程规则后归还本次解析器的独立 locale。
    /// 参数说明: 无。
    /// 返回：释放解析资源，不改变进程或其它线程的语言地区规则。
    deinit {
        freelocale(locale)
    }

    /// 业务作用：解释所选小数分隔符之前允许的数字前缀，非数字尾部不扩大转换权限。
    /// 参数说明:
    /// - text: 完整原键，包含 NUL 时仍按明确前缀规则处理。
    /// - comma: 是否把逗号解释为小数点。
    /// - budget: 本次准备的共同预算。
    /// 返回：空白前缀为空值；有效前缀返回 binary64，不能转换、上溢或下溢时失败。
    func parse(_ text: String, comma: Bool, budget: LineSortBudget) throws -> Double? {
        var prefix: [CChar] = []
        var hasNumber = false
        for (index, byte) in text.utf8.enumerated() {
            if index & 1023 == 0 {
                try budget.check()
            }
            let whitespace = byte == 32 || byte == 9 || byte == 13 || byte == 10
            guard whitespace || byte >= 48 && byte <= 57 || byte == 45 || byte == (comma ? 44 : 46)
            else {
                break
            }
            hasNumber = hasNumber || !whitespace
            prefix.append(CChar(byte == 44 ? 46 : byte))
        }
        guard hasNumber else {
            return nil
        }
        prefix.append(0)
        return try prefix.withUnsafeBufferPointer {
            bytes in
            guard let base = bytes.baseAddress else {
                throw NateError.invalidText
            }
            var end: UnsafeMutablePointer<CChar>?
            // 数值转换只临时使用本线程的独立 locale；同步调用不挂起，任意返回路径均恢复原线程规则。
            guard let previous = uselocale(locale) else {
                throw NateError.message("无法进入独立小数解析环境。")
            }
            defer {
                uselocale(previous)
            }
            errno = 0
            let value = strtod(base, &end)
            let conversionError = errno
            let parsedEnd = end.map {
                UnsafePointer<CChar>($0)
            }
            guard parsedEnd != base,
                conversionError != ERANGE, value.isFinite
            else {
                throw NateError.message("小数排序键无法转换或超出 binary64 范围。")
            }
            return value
        }
    }
}

enum LineSortComparison {
    /// 业务作用：每个目标只生成一次完整排序键，取键与保存键的内存均受整轮预算约束。
    /// 参数说明:
    /// - tree: 固定源正文。
    /// - range: 已验证在同一逻辑行内的实际键。
    /// - options: 键解释方式。
    /// - parser: 小数排序的独立解析器。
    /// - retained: 已保留键的估计字节数，成功时累计当前键。
    /// - budget: 所有键与比较共享的执行资格。
    /// 返回：完整键；单键超过 1 MiB 或累计超过 256 MiB 时整体拒绝，长度键不复制原文。
    static func key(
        in tree: PieceTree,
        range: ByteRange,
        options: LineSortOptions,
        parser: DecimalLineParser?,
        retained: inout Int,
        budget: LineSortBudget
    ) throws -> LineSortKey {
        try budget.check()
        if options.kind == .length {
            return .length(try tree.slicing(range).utf16Count)
        }
        guard range.count <= 1_048_576 else {
            throw NateError.message("单个排序键超过 1 MiB，未截断原行；可选择矩形列或按行长度排序。")
        }
        let text = tree.text(in: range)
        switch options.kind {
        case .decimalComma, .decimalDot:
            guard let parser else {
                throw NateError.message("小数排序缺少独立解析环境。")
            }
            return .number(try parser.parse(text, comma: options.kind == .decimalComma, budget: budget))
        case .lexicographic, .integer:
            retained += text.utf16.count * MemoryLayout<UInt16>.stride
            guard retained <= 256 * 1024 * 1024 else {
                throw NateError.message("排序键合计超过 256 MiB，原正文保留。")
            }
            return .units(Array(text.utf16))
        default:
            retained += range.count
            guard retained <= 256 * 1024 * 1024 else {
                throw NateError.message("排序键合计超过 256 MiB，原正文保留。")
            }
            return .text(text)
        }
    }

    /// 业务作用：明确区分原码元、语言、小数和长度比较，同键由调用者保留原始相对行序。
    /// 参数说明:
    /// - a: 左侧已准备的完整键。
    /// - b: 右侧已准备的完整键。
    /// - options: 用户确认的解释与方向。
    /// - budget: 每次比较仍须具备的共享预算。
    /// 返回：方向应用之前的负、零、正三态；键类型不匹配或取消时失败。
    static func compare(
        _ a: LineSortKey,
        _ b: LineSortKey,
        options: LineSortOptions,
        budget: LineSortBudget
    ) throws -> Int {
        try budget.check()
        switch (a, b) {
        case (.units(let a), .units(let b)):
            return try options.kind == .integer
                ? IntegerLineComparison.compare(a, b, budget: budget)
                : IntegerLineComparison.lexical(a, 0..<a.count, b, 0..<b.count, budget: budget)
        case (.length(let a), .length(let b)):
            return a == b ? 0 : a < b ? -1 : 1
        case (.number(let a), .number(let b)):
            guard let a else {
                return b == nil ? 0 : -1
            }
            guard let b else {
                return 1
            }
            return a == b ? 0 : a < b ? -1 : 1
        case (.text(let a), .text(let b)):
            let result =
                options.kind == .ignoringCase
                ? a.compare(b, options: [.caseInsensitive, .literal])
                : a.compare(b, locale: Locale(identifier: options.localeIdentifier))
            try budget.check()
            return result.rawValue
        default:
            throw NateError.message("排序键类型不一致，原正文保留。")
        }
    }
}
