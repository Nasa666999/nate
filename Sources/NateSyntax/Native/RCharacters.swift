import Foundation

extension RLexing {
    /// 业务作用：扫描只访问当前已经确认的完整物理范围，范围外哨兵不替代实际 NUL。
    /// 参数说明:
    /// - index: 当前物理范围内的相对原字节位置。
    /// 返回：实际原字节，范围外为零。
    func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < bytes.count ? bytes[index] : 0
    }

    /// 业务作用：转义和原始字符串前移跨越完整 UTF-8 标量，不把尾字节识别成新的代码。
    /// 参数说明:
    /// - index: 已确认的标量首字节或范围末尾。
    /// 返回：标量宽度，范围末尾为零。
    func width(_ index: Int) -> Int {
        guard index >= 0, index < bytes.count else {
            return 0
        }
        let first = bytes[index]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：类别变更只确认完整已扫描片段，词表及未闭合运算符可在边界处重分类。
    /// 参数说明:
    /// - mode: 完整片段之后的原生类别。
    /// 返回：局部原字节类别更新；预算不足时拒绝整次状态发布。
    mutating func change(_ mode: Int) throws {
        let end = min(cursor, bytes.count)
        for index in segment..<end {
            try budget.consume()
            classes[index] = UInt8(state.mode)
        }
        segment = end
        state.mode = mode
    }

    /// 业务作用：R 名称保留 ASCII 大小写和原生 99 字节候选窗口，三组词表按独立优先顺序匹配。
    /// 参数说明: 无。
    /// 返回：整个名称取得主要词、基础函数或其它包函数类别，未知名称继续使用标识符类别。
    mutating func classifyIdentifier() {
        let end = min(min(cursor, bytes.count), segment + 99)
        let candidate = Data(
            bytes[segment..<end].prefix {
                $0 != 0
            }
        )
        for index in 0..<3 where rules.groups[index].contains(candidate) {
            state.mode = index + 2
            break
        }
    }

    /// 业务作用：R 名称及数字边界采用原生 ASCII 字母数字规则，标量投影另行保留完整原字符。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 字母、数字或下划线为真。
    static func word(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 95
    }

    /// 业务作用：指数、十六进制外观和转义分别复用明确 ASCII 数字集合，不进行数值求值。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 十进制数字为真。
    static func digit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    /// 业务作用：十六进制数字和转义只承认固定字母集合，不采用区域或 Unicode 大小写转换。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 0–9、a–f 或 A–F 为真。
    static func hexadecimal(_ byte: UInt8) -> Bool {
        digit(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    /// 业务作用：R 普通操作符保持独立，句点用于数字和名称，百分号进入专用命名运算符状态。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：原生操作符集合成员为真。
    static func isOperator(_ byte: UInt8) -> Bool {
        [
            45, 43, 33, 126, 63, 58, 42, 47, 94, 60, 62, 61, 38, 124, 36, 40, 41,
            125, 123, 91, 93,
        ].contains(byte)
    }

    /// 业务作用：只有真实 LF、独立 CR 与文件末尾提供行结束证据，显示片段边界不结束字面状态。
    /// 参数说明: 无。
    /// 返回：当前处于真实物理行末或文件末尾时为真。
    var lineEnd: Bool {
        byte(cursor) == 10 || byte(cursor) == 13 && byte(cursor + 1) != 10
            || documentEnd && cursor == bytes.count
    }
}
