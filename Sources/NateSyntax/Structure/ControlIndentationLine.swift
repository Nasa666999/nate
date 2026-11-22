import Foundation
import NateCore

struct ControlIndentationLine {
    private let endings: [Bool]

    /// 业务作用：一行代码只扫描一次控制语句边界，多光标查询不重复回扫整行或解释不透明文字。
    /// 参数说明:
    /// - code: 已将字符串和注释按词法证据遮蔽的完整行字节。
    /// - caseInsensitive: 当前语言的条件关键字是否忽略 ASCII 大小写。
    /// - deadline: 语言输入动作共同持有的截止。
    /// - permit: 当前整批缩进仍有准备资格。
    /// 返回：条件头结束位置的有界索引；过量嵌套、失权或截止失败时不提供部分判断。
    init(
        code: [UInt8],
        caseInsensitive: Bool,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws {
        guard code.count <= 1_048_576 else {
            throw NateError.message("控制语句缩进单行超过 1 MiB。")
        }
        var ends = Array(repeating: false, count: code.count)
        var parentheses: [Bool] = []
        var previousControls = false
        var cursor = 0
        while cursor < code.count {
            if cursor & 255 == 0 {
                try Self.check(deadline: deadline, permit: permit)
            }
            let byte = code[cursor]
            if Self.word(byte) {
                let start = cursor
                while cursor < code.count, Self.word(code[cursor]) {
                    if cursor & 255 == 0 {
                        try Self.check(deadline: deadline, permit: permit)
                    }
                    cursor += 1
                }
                let token = code[start..<cursor]
                previousControls =
                    Self.matches(token, word: [105, 102], folded: caseInsensitive)
                    || Self.matches(token, word: [102, 111, 114], folded: caseInsensitive)
                    || Self.matches(token, word: [119, 104, 105, 108, 101], folded: caseInsensitive)
                    || Self.matches(token, word: [101, 108, 115, 101, 105, 102], folded: caseInsensitive)
                // 换行可能位于标识符内部，只有实际切成独立 else 的那个前缀才具有条件头身份。
                if cursor - start >= 4,
                    Self.matches(
                        code[start..<(start + 4)],
                        word: [101, 108, 115, 101],
                        folded: caseInsensitive
                    )
                {
                    ends[start + 3] = true
                }
                continue
            }
            if byte == 40 {
                guard parentheses.count < 65_536 else {
                    throw NateError.message("控制语句缩进括号嵌套超过 65536 层。")
                }
                parentheses.append(previousControls)
                previousControls = false
            }
            else if byte == 41 {
                if parentheses.popLast() == true {
                    ends[cursor] = true
                }
                previousControls = false
            }
            else if ![9, 10, 13, 32].contains(byte) {
                previousControls = false
            }
            cursor += 1
        }
        try Self.check(deadline: deadline, permit: permit)
        endings = ends
    }

    /// 业务作用：每个真实换行目标通过已确认的最后代码位置取得完整条件头身份。
    /// 参数说明:
    /// - position: 当前插入边界前最后一个非空白代码字节，没有前置代码时为空。
    /// 返回：该位置恰好结束完整控制语句头时为真，未知或越界位置为假。
    func contains(_ position: Int?) -> Bool {
        guard let position, endings.indices.contains(position) else {
            return false
        }
        return endings[position]
    }

    /// 业务作用：控制关键字必须是完整代码词，非 ASCII 标识符不能因尾部相似而成为条件头。
    /// 参数说明:
    /// - byte: 已遮蔽字符串与注释的当前原字节。
    /// 返回：属于连续标识符外观时为真，空白、标点和遮蔽占位为假。
    private static func word(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || byte == 95 || byte >= 128
    }

    /// 业务作用：条件词按当前语言的明确大小写规则识别，不改变原文或归一化其它字符。
    /// 参数说明:
    /// - token: 当前连续代码词的原字节。
    /// - word: 当前支持的固定 ASCII 关键字。
    /// - folded: 是否仅折叠 ASCII 大写，PHP 使用此规则。
    /// 返回：长度和各字节按所选规则完全一致时为真。
    private static func matches(_ token: ArraySlice<UInt8>, word: [UInt8], folded: Bool) -> Bool {
        guard token.count == word.count else {
            return false
        }
        return zip(token, word).allSatisfy { byte, expected in
            let value = folded && (65...90).contains(byte) ? byte + 32 : byte
            return value == expected
        }
    }

    /// 业务作用：控制行分类继续使用整批输入的资格和截止，单行不能另取完整运行预算。
    /// 参数说明:
    /// - deadline: 本次完整输入的共同截止。
    /// - permit: 当前仍有完整准备资格。
    /// 返回：资格与时间仍有效时继续，否则不发布部分条件分类。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("控制语句缩进已取消或超过共同截止。")
        }
    }
}
