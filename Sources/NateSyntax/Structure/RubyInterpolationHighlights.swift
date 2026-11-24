import NateCore

struct RubyInterpolationHighlights {
    enum Event {
        case enter(ByteRange)
        case leave(ByteRange)
        case token(RubyIndentationLexer.Token)
        case styled(ByteRange, RubyHighlightStyle)
    }

    let initialDepth: Int
    private(set) var events: [Event] = []

    /// 业务作用：建立物理行着色的独立初始插值深度。
    /// 参数说明:
    /// - initialDepth: 来自同一正文前一行的原始插值层级。
    /// 返回：没有记录任何当前行范围。
    init(initialDepth: Int) {
        self.initialDepth = initialDepth
    }

    /// 业务作用：相邻同样式的原字节区间共用一条记录，长字面不逐字节分配事件。
    /// 参数说明:
    /// - style: 已确认的原生主题类别。
    /// - range: 当前物理行相对原字节范围。
    /// 返回：追加或延长已知范围；超量时整行拒绝。
    mutating func paint(_ style: RubyHighlightStyle, in range: ByteRange) throws {
        if case .styled(let previous, let old) = events.last, old == style, previous.upper == range.lower {
            events[events.count - 1] = .styled(ByteRange(previous.lower, range.upper), style)
        }
        else {
            try append(.styled(range, style))
        }
    }

    /// 业务作用：按源顺序保留插值边界及代码范围，超过行容量时禁止发布部分样式。
    /// 参数说明:
    /// - event: 已按当前物理行确认的事件。
    /// 返回：尚有容量时追加，超限时终止准备。
    mutating func append(_ event: Event) throws {
        guard events.count < 65_536 else {
            throw NateError.message("Ruby 插值单行超过 65536 个事件。")
        }
        events.append(event)
    }
}
