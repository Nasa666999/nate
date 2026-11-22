import Foundation

extension BatchScanner {
    /// 业务作用：行缓冲区外的原生哨兵与真实 NUL 一致，任何读取仍不得越过数组边界。
    /// 参数说明:
    /// - index: 当前物理行中的字节位置。
    /// 返回：对应原字节或范围之外的 NUL 哨兵。
    func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < bytes.count ? bytes[index] : 0
    }

    /// 业务作用：当前 Batch 词的后继哨兵独立于后续实际词，变量边界不能借用下一个词。
    /// 参数说明:
    /// - index: 相对当前词开端的位置。
    /// 返回：当前词中的原字节或词尾 NUL 哨兵。
    func word(_ index: Int) -> UInt8 {
        index >= 0 && index < wordEnd - wordStart ? bytes[wordStart + index] : 0
    }

    /// 业务作用：Batch 命令词沿原生 ASCII 空白定义分隔，不把 NUL 或 Unicode 空白隐式删去。
    /// 参数说明:
    /// - byte: 待分类原字节。
    /// 返回：ASCII 空格或水平及垂直空白范围时为真。
    static func space(_ byte: UInt8) -> Bool {
        byte == 32 || byte >= 9 && byte <= 13
    }

    /// 业务作用：盘符与路径扩展只采用原生 ASCII 字母范围。
    /// 参数说明:
    /// - byte: 已按 ASCII 小写的原字节。
    /// 返回：ASCII 字母时为真。
    static func alpha(_ byte: UInt8) -> Bool {
        byte >= 97 && byte <= 122
    }

    /// 业务作用：位置参数仅允许单个 ASCII 数字，不扩展 Unicode 数字语义。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：零至九的 ASCII 字节时为真。
    static func digit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    /// 业务作用：操作符集合固定对应 Batch 的命令及赋值分支。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：属于原生操作符集合时为真。
    static func op(_ byte: UInt8) -> Bool {
        [61, 43, 62, 60, 124, 63, 42, 38, 40, 41].contains(byte)
    }

    /// 业务作用：路径与引用分隔符保持逐段处理，不整体声明为字符串。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：属于原生分隔符集合时为真。
    static func separator(_ byte: UInt8) -> Bool {
        [92, 46, 59, 34, 39, 47].contains(byte)
    }

    /// 业务作用：特殊命令紧邻标点及变量扩展使用同一原生终止集合。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：操作符或路径及引用分隔符时为真。
    static func punctuation(_ byte: UInt8) -> Bool {
        op(byte) || separator(byte)
    }

    /// 业务作用：跳过命令位置前的实际 ASCII 空白，逐字节计入共同预算。
    /// 参数说明:
    /// - start: 当前物理行中的起点。
    /// 返回：第一个非空白位置，最远为行缓冲区末端。
    mutating func skippedSpace(_ start: Int) throws -> Int {
        var end = start
        while end < bytes.count && Self.space(byte(end)) {
            try budget.consume()
            end += 1
        }
        return end
    }

    /// 业务作用：取得完整词末端，后续细分不得把截断词当作已确认的命令。
    /// 参数说明:
    /// - start: 当前物理行中的起点。
    /// 返回：下一个 ASCII 空白或真实行末端。
    mutating func skippedNonSpace(_ start: Int) throws -> Int {
        var end = start
        while end < bytes.count && !Self.space(byte(end)) {
            try budget.consume()
            end += 1
        }
        return end
    }

    /// 业务作用：普通词在操作符、分隔符或变量标记之前结束，原文仍逐段完整保留。
    /// 参数说明: 无。
    /// 返回：本词的最长普通前缀原字节数。
    mutating func wordLength() throws -> Int {
        var count = 0
        while count < wordEnd - wordStart && !Self.punctuation(word(count))
            && word(count) != 37 && word(count) != 33
        {
            try budget.consume()
            count += 1
        }
        return count
    }
}
