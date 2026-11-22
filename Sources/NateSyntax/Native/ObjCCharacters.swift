import Foundation

extension ObjCLexing {
    /// 业务作用：原字节扫描在范围之外使用词法哨兵，正文 NUL 不截断完整输入。
    /// 参数说明:
    /// - index: 当前完整物理范围内的相对原字节位置。
    /// 返回：实际原字节或范围外的零值。
    func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < bytes.count ? bytes[index] : 0
    }

    /// 业务作用：字符与正则转义跳过完整 UTF-8 标量，后继续字节不能取得新的结构身份。
    /// 参数说明:
    /// - index: 当前标量首字节或范围末尾。
    /// 返回：标量宽度，末尾为零。
    func width(_ index: Int) -> Int {
        guard index >= 0, index < bytes.count else {
            return 0
        }
        let value = bytes[index]
        return value < 128 ? 1 : (value < 224 ? 2 : (value < 240 ? 3 : 4))
    }

    /// 业务作用：原生操作符规则读取 Unicode 标量的低八位，显示投影仍保留完整标量边界。
    /// 参数说明:
    /// - index: 已确认的 UTF-8 标量首字节。
    /// 返回：完整标量值，范围外为零；不把其它词边界隐式转为低八位比较。
    func scalarValue(_ index: Int) -> UInt32 {
        let count = width(index)
        guard count > 1 else {
            return UInt32(byte(index))
        }
        var value = UInt32(byte(index) & (count == 2 ? 31 : (count == 3 ? 15 : 7)))
        for offset in 1..<count {
            value = value << 6 | UInt32(byte(index + offset) & 63)
        }
        return value
    }

    /// 业务作用：分类变更只发布已完整扫描的局部片段，名称和文档词可在边界确认后整体重分类。
    /// 参数说明:
    /// - mode: 后继原生类别。
    /// 返回：已扫描原字节取得当前类别；预算不足时抛错，不发布局部检查点。
    mutating func change(_ mode: Int) throws {
        let end = min(cursor, bytes.count)
        for index in segment..<end {
            try budget.consume()
            classes[index] = UInt8(state.mode)
        }
        segment = end
        state.mode = mode
    }

    /// 业务作用：词表候选保留大小写和原字节身份，按原生 99 字节窗口及首个 NUL 边界匹配。
    /// 参数说明:
    /// - skipping: 指令与文档词跳过的单字节前缀数量。
    /// 返回：有界原字节候选，不作 Unicode 规范化。
    func candidate(skipping: Int = 0) -> Data {
        let end = min(min(cursor, bytes.count), segment + 99)
        return Data(
            bytes[min(end, segment + skipping)..<end].prefix {
                $0 != 0
            }
        )
    }

    /// 业务作用：名称按指令、主要词、类型和限定词分别归类，UUID 的后继字面资格只来自主要词表。
    /// 参数说明: 无。
    /// 返回：整个名称片段取得准确样式，未知名称保留原生标识符类别。
    mutating func classifyIdentifier() {
        let word = candidate()
        if byte(segment) == 64 {
            if rules.groups[3].contains(candidate(skipping: 1)) {
                state.mode = 20
            }
        }
        else if rules.groups[0].contains(word) {
            state.continuation.lastUUID = word == Data("uuid".utf8)
            state.mode = 5
        }
        else if rules.groups[1].contains(word) {
            state.mode = 16
        }
        else if rules.groups[4].contains(word) {
            state.mode = 21
        }
    }

    /// 业务作用：数字与名称采用 Objective-C 原生 ASCII 外观边界，句点只延续数字而不延续名称。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 字母、数字或下划线为真。
    static func word(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 95
    }

    /// 业务作用：文档词沿 Doxygen 原生字符集合延伸，非空白结束符不能冒充有效文档指令。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：小写字母或明确文档符号为真。
    static func documentation(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || [36, 64, 92, 38, 60, 62, 35, 123, 125, 91, 93].contains(byte)
    }

    /// 业务作用：物理行与预处理边界使用 ASCII 空白规则，不把 Unicode 展示换行视为原生行结束。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：空格或 ASCII 9–13 为真。
    static func space(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    /// 业务作用：代码标点采用 Objective-C 原生操作符集合，注释和字面起点先于操作符处理。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：明确操作符字符为真。
    static func isOperator(_ byte: UInt8) -> Bool {
        [
            37, 94, 38, 42, 40, 41, 45, 43, 61, 124, 123, 125, 91, 93, 58, 59,
            60, 62, 44, 47, 63, 33, 46, 126,
        ].contains(byte)
    }

    /// 业务作用：原生物理行结束与文件末尾证据分开判断，显示片段末尾不结束跨行字面。
    /// 参数说明: 无。
    /// 返回：当前为 LF、独立 CR 或真实文件末尾时为真。
    var lineEnd: Bool {
        byte(cursor) == 10 || byte(cursor) == 13 && byte(cursor + 1) != 10
            || documentEnd && cursor == bytes.count
    }
}
