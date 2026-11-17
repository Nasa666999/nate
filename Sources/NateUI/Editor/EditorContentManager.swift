import AppKit
import NateCore

final class EditorContentManager: NSTextContentManager {
    let snapshot: DocumentSnapshot
    let projection: ByteRange
    let rendered: NSAttributedString
    private let paragraph: NSTextParagraph
    private let startUTF16: Int
    private let endUTF16: Int

    /// 业务作用：将内核的单个视口段落投影给 TextKit 2，不建立可写全文副本。
    /// 参数说明:
    /// - snapshot: 唯一正文的不可变快照。
    /// - projection: 当前段落的真实范围。
    /// - rendered: 仅用于排版的带属性段落。
    /// 返回：与该快照绑定的原生内容枚举器。
    init(snapshot: DocumentSnapshot, projection: ByteRange, rendered: NSAttributedString) {
        self.snapshot = snapshot
        self.projection = projection
        self.rendered = rendered
        startUTF16 = snapshot.text.utf16Offset(byte: projection.lower) ?? 0
        endUTF16 = snapshot.text.utf16Offset(byte: projection.upper) ?? startUTF16
        paragraph = NSTextParagraph(attributedString: rendered)
        super.init()
        // TextKit 仅弱持有内容元素，视口缓存必须保留同一段落，字形片段才能持续关联其正文。
        paragraph.textContentManager = self
        paragraph.elementRange = documentRange
    }

    /// 业务作用：禁止从归档恢复独立的排版正文，正文必须来自工作区。
    /// 参数说明:
    /// - coder: 系统归档读取器。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        return nil
    }

    override var documentRange: NSTextRange {
        NSTextRange(location: location(startUTF16), end: location(endUTF16))
            ?? NSTextRange(location: location(startUTF16))
    }

    /// 业务作用：按请求提供真实段落，原生布局只处理视口需要的内容。
    /// 参数说明:
    /// - textLocation: 当前枚举位置。
    /// - options: 枚举方向。
    /// - block: TextKit 的段落消费者。
    /// 返回：已枚举段落边界；快照不同或请求越过本投影时不枚举其它正文。
    override func enumerateTextElements(
        from textLocation: (any NSTextLocation)?,
        options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> (any NSTextLocation)? {
        if let textLocation {
            // 每个布局缓存只拥有一个原始段落，跨快照或投影的请求不能借用其它行的呈现。
            guard let location = textLocation as? EditorTextLocation,
                contains(location),
                options.contains(.reverse)
                    ? location.offset == endUTF16 : location.offset < endUTF16 || startUTF16 == endUTF16
            else {
                return nil
            }
        }
        _ = block(paragraph)
        return options.contains(.reverse) ? documentRange.location : documentRange.endLocation
    }

    /// 业务作用：排版层没有正文写入权限，所有修改由应用事务入口处理。
    /// 参数说明:
    /// - range: 原生请求范围。
    /// - textElements: 原生建议内容。
    /// 返回：正文保持不变。
    override func replaceContents(in range: NSTextRange, with textElements: [NSTextElement]?) {}

    /// 业务作用：将段落逻辑位移转换为绑定同一快照的新位置。
    /// 参数说明:
    /// - location: 起始位置。
    /// - offset: UTF-16 位移。
    /// 返回：仅限当前快照及段落投影边界的合法位置，其它请求为空。
    override func location(_ location: any NSTextLocation, offsetBy offset: Int) -> (any NSTextLocation)? {
        guard let current = location as? EditorTextLocation, contains(current),
            offset >= startUTF16 - current.offset, offset <= endUTF16 - current.offset
        else {
            return nil
        }
        return self.location(current.offset + offset)
    }

    /// 业务作用：计算同一快照中两个原生位置的系统文本距离。
    /// 参数说明:
    /// - from: 起始位置。
    /// - to: 结束位置。
    /// 返回：同一快照与投影内的 UTF-16 距离；任何位置不属于本投影时返回系统哨兵。
    override func offset(from: any NSTextLocation, to: any NSTextLocation) -> Int {
        guard let a = from as? EditorTextLocation, let b = to as? EditorTextLocation,
            contains(a), contains(b)
        else {
            return NSNotFound
        }
        return b.offset - a.offset
    }

    /// 业务作用：将原生位置限制在本布局缓存的正文、修订和段落内，防止跨行借用坐标。
    /// 参数说明:
    /// - location: 待验证的系统文本位置。
    /// 返回：该位置属于本缓存的完整投影边界时为真。
    private func contains(_ location: EditorTextLocation) -> Bool {
        location.documentID == snapshot.id && location.revision == snapshot.revision
            && location.offset >= startUTF16 && location.offset <= endUTF16
    }

    /// 业务作用：统一生成排版位置对象。
    /// 参数说明:
    /// - offset: UTF-16 单元位置。
    /// 返回：绑定当前快照的位置。
    private func location(_ offset: Int) -> EditorTextLocation {
        EditorTextLocation(documentID: snapshot.id, revision: snapshot.revision, offset: offset)
    }
}
