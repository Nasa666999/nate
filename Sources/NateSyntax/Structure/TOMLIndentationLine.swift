import NateCore

struct TOMLIndentationLine {
    struct Container {
        let close: UInt8
        let prefix: String
    }

    private enum Tail {
        case start
        case content
        case open(UInt8)
        case leadingClose(String)
    }

    private let bytes: [UInt8]
    private let base: Int
    private let tokens: [SyntaxToken]
    private var cursor = 0
    private var token = 0
    private var indentation: Int?
    private var prefix: String?
    private var tail: Tail = .start

    /// 业务作用：把原物理行和同源的完整 TOML 词元固定到同一个局部扫描器。
    /// 参数说明:
    /// - bytes: 不含物理行结束符的原字节。
    /// - base: 当前原行在完整正文中的起点。
    /// - tokens: TOML 词法器按原字节顺序给出的该行词元。
    /// 返回：准备好顺序处理换行目标的扫描器。
    init(bytes: [UInt8], base: Int, tokens: [SyntaxToken]) {
        self.bytes = bytes
        self.base = base
        self.tokens = tokens
    }

    /// 业务作用：仅依据获得操作符身份的原字节推进数组与内联表，引用键、表头和三引号保持字面身份。
    /// 参数说明:
    /// - offset: 本行需要读取到的真实目标位置。
    /// - containers: 已确认的跨行配对栈。
    /// - remainingPrefixes: 本次操作允许读取的剩余原缩进容量。
    /// - check: 全部目标的共同继续资格。
    /// 返回：推进到目标或其所属注释结束，容器不完整或超量时不给出部分结果。
    mutating func scan(
        through offset: Int,
        containers: inout [Container],
        remainingPrefixes: inout Int,
        check: () throws -> Void
    ) throws {
        var nextCheck = cursor
        while cursor < offset {
            if cursor >= nextCheck {
                try check()
                nextCheck = cursor + 256
            }
            let byte = bytes[cursor]
            if Self.isSpace(byte) {
                cursor += 1
                continue
            }
            let style = Self.style(at: base + cursor, tokens: tokens, index: &token)
            if style == "toml:1" {
                cursor = bytes.count
                continue
            }
            if indentation == nil {
                indentation = cursor
            }
            if style == "toml:8", let closing = Self.closing(for: byte) {
                // 先确保外层容器与整条原始缩进都能保留，避免只对内层或部分光标执行换行。
                guard containers.count < 4096 else {
                    throw NateError.message("TOML 容器嵌套超过 4096 层。")
                }
                let origin: String
                if let prefix {
                    origin = prefix
                }
                else {
                    let count = indentation ?? 0
                    guard count <= remainingPrefixes else {
                        throw NateError.message("TOML 容器的完整原始缩进超过 1 MiB。")
                    }
                    remainingPrefixes -= count
                    origin = String(decoding: bytes.prefix(count), as: UTF8.self)
                    prefix = origin
                }
                containers.append(Container(close: closing, prefix: origin))
                tail = .open(closing)
            }
            else if style == "toml:8", let actual = containers.last, actual.close == byte {
                containers.removeLast()
                switch tail {
                case .start, .leadingClose:
                    tail = .leadingClose(actual.prefix)
                default:
                    tail = .content
                }
            }
            else {
                tail = .content
            }
            cursor += 1
        }
    }

    /// 业务作用：批量查找选区之后仍保留在同行的已分类闭合符，共享空白和词元扫描。
    /// 参数说明:
    /// - targets: 由本物理行开始的完整替换范围。
    /// - check: 本次编辑共同拥有的继续资格。
    /// 返回：替换后紧接真实闭合符的目标及符号，其余目标没有后继结构资格。
    func closingSuffixes(targets: [ByteRange], check: () throws -> Void) throws -> [ByteRange: UInt8] {
        var cursor = 0
        var token = 0
        var output: [ByteRange: UInt8] = [:]
        for target in targets.sorted(by: { $0.upper < $1.upper }) {
            try check()
            guard target.upper < base + bytes.count else {
                break
            }
            cursor = max(cursor, target.upper - base)
            while cursor < bytes.count, Self.isSpace(bytes[cursor]) {
                if cursor & 255 == 0 {
                    try check()
                }
                cursor += 1
            }
            if cursor < bytes.count, bytes[cursor] == 93 || bytes[cursor] == 125,
                Self.style(at: base + cursor, tokens: tokens, index: &token) == "toml:8"
            {
                output[target] = bytes[cursor]
            }
        }
        return output
    }

    /// 业务作用：在真实容器两端之间展开内外行，行首闭合沿所属容器的混合原始前缀对齐。
    /// 参数说明:
    /// - offset: 当前换行位置。
    /// - next: 同一行已经确认的后继闭合符。
    /// - containers: 截止该插入位置的已确认容器栈。
    /// 返回：已确认的单一结构动作；缺少真实区间或光标仍在注释内部时继承。
    func action(at offset: Int, next: UInt8?, containers: [Container]) -> NewlineIndentationAction {
        guard cursor <= offset else {
            return .inherit
        }
        switch tail {
        case .start:
            if let matching = containers.last, next == matching.close {
                return .align(prefix: matching.prefix, levels: 0)
            }
            return .inherit
        case .open(let close):
            return next == close ? .expandPair : .increase
        case .leadingClose(let prefix):
            if let matching = containers.last, next == matching.close {
                return .align(prefix: matching.prefix, levels: 0)
            }
            return .align(prefix: prefix, levels: 0)
        case .content:
            return .inherit
        }
    }

    /// 业务作用：复用顺序词元游标确认每个原标点当前的真实类别。
    /// 参数说明:
    /// - offset: 正文中的真实字节位置。
    /// - tokens: 当前物理行的有序词元。
    /// - index: 下一次仍可能覆盖附近位置的词元索引。
    /// 返回：覆盖该字节的确切词法类别；未着色或范围结束时为空。
    private static func style(at offset: Int, tokens: [SyntaxToken], index: inout Int) -> String? {
        while index < tokens.count, tokens[index].range.upper <= offset {
            index += 1
        }
        guard index < tokens.count, tokens[index].range.lower <= offset else {
            return nil
        }
        return tokens[index].lexicalStyle
    }

    /// 业务作用：识别在光标两侧可透过的 TOML 原缩进字节。
    /// 参数说明:
    /// - byte: 当前物理行中的单个原字节。
    /// 返回：ASCII 空格或 Tab 时成立。
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9
    }

    /// 业务作用：确定真实容器开端必须使用的闭合类型。
    /// 参数说明:
    /// - byte: 已由 TOML 词法确认的操作符字节。
    /// 返回：数组和内联表的配对闭合符，其余操作符没有容器资格。
    private static func closing(for byte: UInt8) -> UInt8? {
        switch byte {
        case 91:
            return 93
        case 123:
            return 125
        default:
            return nil
        }
    }
}
