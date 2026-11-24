import NateCore

struct MarkupIndentationScope {
    struct Frame {
        let name: [UInt8]
        let prefix: ByteRange
        let anchor: Int
        let omissible: String?
    }

    private static let optionalEnds: Set<String> = [
        "li", "dt", "dd", "p", "rt", "rp", "option", "optgroup", "colgroup", "thead", "tbody", "tfoot",
        "tr", "td", "th",
    ]
    private static let paragraphEnds: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "dialog", "div", "dl", "dt", "dd",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "li", "main", "menu", "nav", "ol", "p", "pre", "search", "section",
        "table", "ul",
    ]
    private static let followingSibling: [String: Set<String>] = [
        "li": ["li"], "dt": ["dt", "dd"], "dd": ["dt", "dd"], "rt": ["rt", "rp"],
        "rp": ["rt", "rp"], "option": ["option", "optgroup"], "optgroup": ["optgroup"],
        "thead": ["tbody", "tfoot"], "tbody": ["tbody", "tfoot"],
        "tr": ["tr", "tbody", "tfoot"], "td": ["td", "th", "tr", "tbody", "tfoot"],
        "th": ["td", "th", "tr", "tbody", "tfoot"],
    ]
    private static let htmlIntegrationPoints: Set<String> = [
        "foreignobject", "desc", "title", "annotation-xml", "mi", "mo", "mn", "ms", "mtext",
    ]

    private var frames: [Frame] = []
    let dialect: MarkupDialect

    /// 业务作用：HTML 的 CDATA 折叠沿已确认的 SVG 或 MathML 作用域建立，集成接口终止本次确认。
    /// 参数说明: 无。
    /// 返回：当前标记属于已确认的外来内容区域时成立。
    var hasForeignContent: Bool {
        for frame in frames.reversed() where frame.name.count <= 14 {
            let name = String(decoding: frame.name, as: UTF8.self)
            if name == "svg" || name == "math" {
                return true
            }
            if Self.htmlIntegrationPoints.contains(name) {
                break
            }
        }
        return false
    }

    /// 业务作用：跟踪同一方言下的有效标签作用域，保持 XML 名称字节和 HTML 的有限可省略元素规则。
    /// 参数说明:
    /// - dialect: 当前原文明确选择的标签方言。
    /// 返回：等待首个开始标签的空作用域。
    init(dialect: MarkupDialect) {
        self.dialect = dialect
    }

    /// 业务作用：在真实非空开始标签处建立锚点，HTML 同级开端可收束已确认的可省略元素。
    /// 参数说明:
    /// - tag: 已验证的开始标签或空元素。
    /// - impliedEnd: 当前标签前已确认结束的 HTML 元素处理动作。
    /// - check: 全部目标的共同继续资格。
    /// 返回：可用时推进作用域，嵌套超量或取消时停止整批输入。
    mutating func open(
        _ tag: MarkupIndentationTag,
        impliedEnd: ((Frame) throws -> Void)? = nil,
        check: () throws -> Void
    ) throws {
        if dialect == .html {
            let next = tag.name.count <= 16 ? String(decoding: tag.name, as: UTF8.self) : ""
            while let name = frames.last?.omissible {
                guard
                    Self.followingSibling[name]?.contains(next) == true
                        || name == "p" && Self.paragraphEnds.contains(next)
                else {
                    break
                }
                try check()
                let previous = frames.removeLast()
                try impliedEnd?(previous)
            }
        }
        if tag.kind == .open {
            // 先确认完整活动容器容量，避免把保留的内层标签错误地对齐到缺失外层。
            guard frames.count < 4096 else {
                throw NateError.message("标记语言结构缩进的活动元素超过 4096 层。")
            }
            let short =
                dialect == .html && tag.name.count <= 8
                ? String(decoding: tag.name, as: UTF8.self) : ""
            frames.append(
                Frame(
                    name: tag.name,
                    prefix: tag.prefix,
                    anchor: tag.range.upper - 1,
                    omissible: Self.optionalEnds.contains(short) ? short : nil
                )
            )
        }
    }

    /// 业务作用：确认真实闭合标签所属的开端，HTML 只跨越可省略的内部元素，XML 只接受严格栈顶。
    /// 参数说明:
    /// - name: HTML ASCII 折叠后或 XML 未转换的原始名称字节。
    /// - check: 当前输入的继续资格。
    /// 返回：最接近的合法开端及定位；不同名、未知跨越或取消时没有可用的闭合证据。
    func matching(_ name: [UInt8], check: () throws -> Void) throws -> (index: Int, frame: Frame)? {
        for index in frames.indices.reversed() {
            try check()
            let frame = frames[index]
            if frame.name == name {
                return (index, frame)
            }
            guard frame.omissible != nil else {
                break
            }
        }
        return nil
    }

    /// 业务作用：只在整段配对证据成立时收束闭合标签，不因不同类型或大小写的 XML 标签丢弃旧作用域。
    /// 参数说明:
    /// - tag: 已确认的真实闭合标签。
    /// - impliedEnd: 此闭合之前已经确认可省略结束符的内部元素处理动作。
    /// - check: 当前输入的继续资格。
    /// 返回：开端的原始缩进及位置；无合法匹配时不改变活动作用域。
    mutating func close(
        _ tag: MarkupIndentationTag,
        impliedEnd: ((Frame) throws -> Void)? = nil,
        check: () throws -> Void
    ) throws -> Frame? {
        guard let matching = try matching(tag.name, check: check) else {
            return nil
        }
        // 只有名称和可省略范围均获确认后才移除内层，未知闭合不能破坏后续目标的真实锚点。
        if let impliedEnd {
            for frame in frames[(matching.index + 1)...].reversed() {
                try check()
                try impliedEnd(frame)
            }
        }
        frames.removeSubrange(matching.index...)
        return matching.frame
    }

    /// 业务作用：XML 标签错配会解除未闭合范围，后续范围必须从新的真实开端建立。
    /// 参数说明: 无。
    /// 返回：活动标签已清空，此前独立确认的完整范围仍由调用方持有。
    mutating func discardOpenElements() {
        frames.removeAll(keepingCapacity: true)
    }
}
