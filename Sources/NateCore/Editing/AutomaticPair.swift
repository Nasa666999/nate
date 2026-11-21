import Foundation

public struct AutomaticPair: Sendable, Equatable, Codable {
    public let opening: String
    public let closing: String

    static let standardPairs: [AutomaticPair] = [
        AutomaticPair(
            standardOpening: "(",
            standardClosing: ")"
        ),
        AutomaticPair(
            standardOpening: "[",
            standardClosing: "]"
        ),
        AutomaticPair(
            standardOpening: "{",
            standardClosing: "}"
        ),
        AutomaticPair(
            standardOpening: "\"",
            standardClosing: "\""
        ),
        AutomaticPair(
            standardOpening: "'",
            standardClosing: "'"
        ),
        AutomaticPair(
            standardOpening: "`",
            standardClosing: "`"
        ),
    ]

    /// 业务作用：预装常量已经具有明确 ASCII 边界，默认设置的建立不依赖当前任务的取消状态。
    /// 参数说明:
    /// - standardOpening: 此类型内固定声明的合法 ASCII 开端。
    /// - standardClosing: 此类型内固定声明的合法 ASCII 闭合符。
    /// 返回：只供固定常量列表使用的定义，外部输入仍须走完整验证入口。
    private init(standardOpening: String, standardClosing: String) {
        opening = standardOpening
        closing = standardClosing
    }

    /// 业务作用：配对定义使用完整原始字形，不把半个组合字符或结束符作为自动输入边界。
    /// 参数说明:
    /// - opening: 一至六十四个 UTF-8 字节的单个完整字形。
    /// - closing: 一至六十四个 UTF-8 字节的单个完整字形。
    /// 返回：两端均为非空、无控制符及空白的固定完整字形时建立定义，否则拒绝。
    public init(opening: String, closing: String) throws {
        for text in [opening, closing] {
            guard !text.isEmpty, text.utf8.count <= 64,
                text.unicodeScalars.allSatisfy({
                    !$0.properties.isWhitespace && $0.value >= 32 && $0.value != 127
                        && $0.properties.generalCategory != .control
                })
            else {
                throw NateError.message("配对两端各须是 64 字节以内、不含空白或控制符的单个完整字形。")
            }
            let tree = PieceTree(text)
            var navigation = try GraphemeNavigation(text: tree)
            guard try navigation.boundary(from: 0, forward: true) == tree.byteCount else {
                throw NateError.message("配对两端各须是单个完整字形，组合序列不能拆开。")
            }
        }
        self.opening = opening
        self.closing = closing
    }

    /// 业务作用：配置和宏恢复同样验证配对边界，不让归档绕过单个完整字形约束。
    /// 参数说明:
    /// - decoder: 完整定义对象。
    /// 返回：两端字段完整且有效时恢复，缺少或非法字段时拒绝。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            opening: values.decode(String.self, forKey: .opening),
            closing: values.decode(String.self, forKey: .closing)
        )
    }

    /// 业务作用：定义身份采用两端原字节，规范等价的不同字符不能互相替代自动输入内容。
    /// 参数说明:
    /// - lhs: 左侧完整定义。
    /// - rhs: 右侧完整定义。
    /// 返回：两端 UTF-8 均完全相同时为真，不执行 Unicode 归一化。
    public static func == (lhs: AutomaticPair, rhs: AutomaticPair) -> Bool {
        lhs.opening.utf8.elementsEqual(rhs.opening.utf8) && lhs.closing.utf8.elementsEqual(rhs.closing.utf8)
    }
}

public struct PairInputCommand: Sendable, Equatable, Codable {
    public let pair: AutomaticPair
    public let input: String
    public let skipExisting: Bool

    /// 业务作用：一次配对输入固定实际字符和完整定义，宏不依赖播放时已经改变的偏好。
    /// 参数说明:
    /// - pair: 输入时明确采用的合法配对。
    /// - input: 本次真实输入，须与配对任一端的原字节完全一致。
    /// - skipExisting: 闭合输入遇到同字节闭合符时是否只推进普通空光标。
    /// 返回：有明确两端语义的独立输入动作，非法字符不被夹取成另一端。
    public init(pair: AutomaticPair, input: String, skipExisting: Bool) throws {
        guard input.utf8.elementsEqual(pair.opening.utf8) || input.utf8.elementsEqual(pair.closing.utf8)
        else {
            throw NateError.message("配对输入必须是当前定义的一端，原字符不能被替换或归一化。")
        }
        self.pair = pair
        self.input = input
        self.skipExisting = skipExisting
    }

    /// 业务作用：宏及配置读取完整动作时复验真实输入与定义的字节关系。
    /// 参数说明:
    /// - decoder: 当前动作的完整对象。
    /// 返回：全部字段合法时恢复，否则拒绝整项动作。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pair: values.decode(AutomaticPair.self, forKey: .pair),
            input: values.decode(String.self, forKey: .input),
            skipExisting: values.decode(Bool.self, forKey: .skipExisting)
        )
    }

    /// 业务作用：配对动作保留实际输入端的原字节身份，规范等价文字仍可能分别承担开端和闭合职责。
    /// 参数说明:
    /// - lhs: 左侧完整动作。
    /// - rhs: 右侧完整动作。
    /// 返回：定义、输入原字节和越过策略全部一致时为真。
    public static func == (lhs: PairInputCommand, rhs: PairInputCommand) -> Bool {
        lhs.pair == rhs.pair && lhs.input.utf8.elementsEqual(rhs.input.utf8)
            && lhs.skipExisting == rhs.skipExisting
    }
}
