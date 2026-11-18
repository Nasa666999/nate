import Foundation
import NateCore

struct LiteralSourceScalar {
    let value: UInt32
    let lower: Int
    let upper: Int
}

struct LiteralScalarCursor {
    let input: SearchInput
    let lower: Int
    let upper: Int
    let backwards: Bool
    var position: Int

    /// 业务作用：字面匹配按完整源标量遍历有界 UTF-16 读取器，补充平面字符不被拆成两个搜索单位。
    /// 参数说明:
    /// - input: 本轮独占的不可变正文投影读取器。
    /// - range: 已授权消费的 UTF-16 范围。
    /// - backwards: 是否从范围右边界反向遍历。
    /// 返回：合法源标量边界上的游标，非法范围或半代理项端点整体失败。
    init(input: SearchInput, range: NSRange, backwards: Bool) throws {
        guard range.location >= 0, range.location <= input.count,
            range.length >= 0, range.length <= input.count - range.location
        else {
            throw NateError.invalidRange
        }
        let end = range.location + range.length
        for boundary in [range.location, end] {
            // 授权范围不能切开代理对，否则完整折叠会把范围外的半个字符借入当前搜索。
            if boundary > 0 && boundary < input.count,
                (0xd800...0xdbff).contains(input[boundary - 1]),
                (0xdc00...0xdfff).contains(input[boundary])
            {
                throw NateError.invalidRange
            }
        }
        self.input = input
        lower = range.location
        upper = end
        self.backwards = backwards
        position = backwards ? end : range.location
    }

    /// 业务作用：每次消费一个完整源标量并保留其真实 UTF-16 起止，折叠长度变化不改变文档坐标。
    /// 参数说明: 无。
    /// 返回：下一个完整标量；范围结束为空，非法源编码或越过授权边界失败。
    mutating func next() throws -> LiteralSourceScalar? {
        guard backwards ? position > lower : position < upper else {
            return nil
        }
        guard
            let value = backwards
                ? Self.ending(in: input, at: position) : Self.starting(in: input, at: position),
            value.lower >= lower, value.upper <= upper
        else {
            throw NateError.invalidRange
        }
        position = backwards ? value.lower : value.upper
        return value
    }

    /// 业务作用：解码指定位置开始的一个源标量，词边界可以读取授权范围外的真实相邻正文。
    /// 参数说明:
    /// - input: 同一快照的有界 UTF-16 读取器。
    /// - position: 源 UTF-16 起点。
    /// 返回：完整标量及其真实起止；文末、越界或半代理项为空。
    static func starting(in input: SearchInput, at position: Int) -> LiteralSourceScalar? {
        guard position >= 0, position < input.count else {
            return nil
        }
        let first = input[position]
        if (0xd800...0xdbff).contains(first) {
            guard position + 1 < input.count else {
                return nil
            }
            let second = input[position + 1]
            guard (0xdc00...0xdfff).contains(second) else {
                return nil
            }
            let scalar = 0x10000 + (UInt32(first) - 0xd800) * 0x400 + UInt32(second) - 0xdc00
            return LiteralSourceScalar(value: scalar, lower: position, upper: position + 2)
        }
        guard !(0xdc00...0xdfff).contains(first) else {
            return nil
        }
        return LiteralSourceScalar(value: UInt32(first), lower: position, upper: position + 1)
    }

    /// 业务作用：反向读取完整源标量，反向导航和词左边界不误把低代理项当作分隔符。
    /// 参数说明:
    /// - input: 同一快照的有界 UTF-16 读取器。
    /// - position: 源标量右侧的 UTF-16 位置。
    /// 返回：当前位置前的完整标量；文首、越界或半代理项为空。
    static func ending(in input: SearchInput, at position: Int) -> LiteralSourceScalar? {
        guard position > 0, position <= input.count else {
            return nil
        }
        let last = input[position - 1]
        if (0xdc00...0xdfff).contains(last) {
            guard position >= 2 else {
                return nil
            }
            return starting(in: input, at: position - 2).flatMap {
                $0.upper == position ? $0 : nil
            }
        }
        return starting(in: input, at: position - 1).flatMap {
            $0.upper == position ? $0 : nil
        }
    }
}
