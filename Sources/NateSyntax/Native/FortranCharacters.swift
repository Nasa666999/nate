import Foundation

enum FortranCharacters {
    /// 业务作用：名称开端采用原生 ASCII 字母与数字，显示用 Unicode 字符不额外取得关键字资格。
    /// 参数说明:
    /// - value: 原文的完整 Unicode 标量或真实边缘哨兵。
    /// 返回：ASCII 字母或数字时为真。
    static func alphanumeric(_ value: UInt32) -> Bool {
        alpha(value) || digit(value)
    }

    /// 业务作用：关键字比较只转换 ASCII 大写，避免把用户词表改写成另一份规则。
    /// 参数说明:
    /// - value: 原候选中的真实原字节。
    /// 返回：ASCII 大写的对应小写，其余字节保持。
    static func folded(_ value: UInt8) -> UInt8 {
        (65...90).contains(value) ? value + 32 : value
    }

    /// 业务作用：Fortran 名称及数字外观保留下划线与百分号，标识符分支另在百分号前收束。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：原生名称后继字符时为真。
    static func word(_ value: UInt32) -> Bool {
        alphanumeric(value) || value == 95 || value == 37
    }

    /// 业务作用：十进制开端同时服务真实行首标签与普通数值，优先级由当前格式决定。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：ASCII 十进制数字时为真。
    static func digit(_ value: UInt32) -> Bool {
        (48...57).contains(value)
    }

    /// 业务作用：指令和点分隔操作符不采用区域或 Unicode 字母扩展。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：ASCII 字母时为真。
    static func alpha(_ value: UInt32) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }

    /// 业务作用：续行及折叠前瞻只跳过原生空格、Tab 和垂直制表符，不越过任意显示空白。
    /// 参数说明:
    /// - value: 当前真实原字节或标量。
    /// 返回：原生有限行内空白成员时为真。
    static func blank(_ value: UInt32) -> Bool {
        [32, 9, 11].contains(value)
    }

    /// 业务作用：续行可穿过 ASCII 物理空白，文档边缘 NUL 不被当作无限空白。
    /// 参数说明:
    /// - value: 当前真实原文标量或边缘哨兵。
    /// 返回：ASCII 空格及控制空白成员时为真。
    static func space(_ value: UInt32) -> Bool {
        value == 32 || (9...13).contains(value)
    }

    /// 业务作用：保留原生操作符分支的 char 转换语义，宽字符的显示与边界仍按完整标量交付。
    /// 参数说明:
    /// - value: 当前原文的完整 Unicode 标量。
    /// 返回：低八位对应原生 ASCII 操作符时为真。
    static func operation(_ value: UInt32) -> Bool {
        [37, 94, 38, 42, 40, 41, 45, 43, 61, 124, 123, 125, 91, 93, 58, 59, 60, 62, 44, 47, 63, 33, 46, 126]
            .contains(UInt8(truncatingIfNeeded: value))
    }
}
