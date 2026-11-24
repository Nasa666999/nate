import AppKit
import NateCore

extension EditorView {
    static let maximumSystemSelections = 4_096

    /// 业务作用：VoiceOver 读取唯一已提交正文，长文档可通过原生范围接口按需读取。
    /// 参数说明: 无。
    /// 返回：容量允许时返回完整正文；超量时使用范围接口，避免复制整份大文件。
    public override func accessibilityValue() -> Any? {
        guard document.text.byteCount <= Self.maximumSystemTextBytes else {
            return nil
        }
        return document.text.text()
    }

    /// 业务作用：安置辅助功能读取的 UTF-16 文本坐标，不读取或排版整篇正文。
    /// 参数说明: 无。
    /// 返回：已提交正文的 UTF-16 单元数。
    public override func accessibilityNumberOfCharacters() -> Int {
        document.text.utf16Count
    }

    /// 业务作用：提供当前主选择的已提交坐标，输入法组合的展示文字不进入辅助范围。
    /// 参数说明: 无。
    /// 返回：严格 UTF-16 主选择范围，无有效修订时返回无效范围。
    public override func accessibilitySelectedTextRange() -> NSRange {
        guard selectionStateRevision == document.revision, let primarySelection else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityRange(forBytes: primarySelection.range)
    }

    /// 业务作用：系统辅助功能读取此视图的完整多选范围，首项表示实际主项。
    /// 参数说明: 无。
    /// 返回：完整有序的 UTF-16 范围；超出交互容量或原选区过期时为空。
    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        guard selectionStateRevision == document.revision, let state = viewSelectionState,
            state.entries.count <= Self.maximumSystemSelections
        else {
            return nil
        }
        let entries = [state.primary] + state.entries.filter { $0.id != state.primaryID }
        var values: [NSValue] = []
        values.reserveCapacity(entries.count)
        for entry in entries {
            let range = accessibilityRange(forBytes: entry.selection.range)
            guard range.location != NSNotFound else {
                return nil
            }
            values.append(NSValue(range: range))
        }
        return values
    }

    /// 业务作用：读取主选择的已提交文本，不以多选角色推测额外正文。
    /// 参数说明: 无。
    /// 返回：辅助读取预算内的主选择文字；缺少有效范围或超量时为空。
    public override func accessibilitySelectedText() -> String? {
        accessibilityString(for: accessibilitySelectedTextRange())
    }

    /// 业务作用：系统可精确读取较大文档中的合法 UTF-16 范围。
    /// 参数说明:
    /// - range: 已提交正文坐标中的原生范围。
    /// 返回：完整原始文字；非法代理项边界、超范围或超量时为空。
    public override func accessibilityString(for range: NSRange) -> String? {
        guard let bytes = document.text.byteRange(range), bytes.count <= Self.maximumSystemTextBytes else {
            return nil
        }
        return document.text.text(in: bytes)
    }

    /// 业务作用：辅助功能按原逻辑行读取文本，保留 CRLF 及结尾空行。
    /// 参数说明:
    /// - line: 从零开始的原始逻辑行号。
    /// 返回：该行的完整 UTF-16 范围；不存在时返回无效范围。
    public override func accessibilityRange(forLine line: Int) -> NSRange {
        guard (0..<document.text.lineCount).contains(line) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityRange(forBytes: document.text.lineRange(line))
    }

    /// 业务作用：在完整 UTF-16 边界上回答原始不是视觉换行的逻辑行号。
    /// 参数说明:
    /// - index: 当前已提交正文的 UTF-16 位置。
    /// 返回：从零开始的行号；非法位置或代理项内坐标返回无效值。
    public override func accessibilityLine(for index: Int) -> Int {
        guard let byte = document.text.byteOffset(utf16: index) else {
            return NSNotFound
        }
        return document.text.lineNumber(at: byte)
    }

    /// 业务作用：报告此编辑视图实际可见逻辑行覆盖的正文范围。
    /// 参数说明: 无。
    /// 返回：可见范围的首尾物理行边界；无有效布局或候选未确认时返回无效范围。
    public override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let visible = visibleLogicalLineRange() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return accessibilityRange(
            forBytes: ByteRange(
                document.text.lineStart(visible.lowerBound),
                document.text.lineStart(visible.upperBound)
            )
        )
    }

    /// 业务作用：以当前已提交版本转换字节范围，辅助功能与文档索引共享真实边界。
    /// 参数说明:
    /// - range: 正文 UTF-8 字节区间。
    /// 返回：相同正文的 UTF-16 范围；非法边界返回无效值。
    func accessibilityRange(forBytes range: ByteRange) -> NSRange {
        guard let lower = document.text.utf16Offset(byte: range.lower),
            let upper = document.text.utf16Offset(byte: range.upper)
        else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    /// 业务作用：辅助功能明确选择单个原始范围，已有主项身份继续作为当前选择。
    /// 参数说明:
    /// - range: 系统提供的严格正文 UTF-16 范围。
    /// 返回：仅焦点、候选和保护均合法时更新选择，失败保留正文和原选区。
    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        applyAccessibilitySelection([range])
    }

    /// 业务作用：把系统明确提供的全部范围一次应用到正在编辑的视图。
    /// 参数说明:
    /// - values: UTF-16 多选范围，首项表示主选择。
    /// 返回：任何一项无效或没有当前选择权限时保持原选择。
    public override func setAccessibilitySelectedTextRanges(_ values: [NSValue]?) {
        guard let values, (1...Self.maximumSystemSelections).contains(values.count),
            ownsSystemTextTarget
        else {
            return
        }
        var ranges: [NSRange] = []
        ranges.reserveCapacity(values.count)
        let rangeType = String(cString: NSValue(range: NSRange()).objCType)
        for value in values {
            // 非范围 NSValue 不能直接取 rangeValue，否则系统对象可能抛出 Objective-C 异常。
            guard String(cString: value.objCType) == rangeType else {
                return
            }
            ranges.append(value.rangeValue)
        }
        applyAccessibilitySelection(ranges)
    }

    /// 业务作用：在辅助客户端查询可写性时使用真实选择和正文编辑权限。
    /// 参数说明:
    /// - selector: 系统欲调用的辅助功能访问器。
    /// 返回：系统读操作沿原有规则判断；写操作需要当前焦点和对应编辑条件。
    public override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "setAccessibilityValue:":
            return ownsSystemTextTarget && !document.isReadOnly
        case "setAccessibilitySelectedText:":
            return ownsSystemTextTarget && !document.isReadOnly && systemTextSelection != nil
        case "setAccessibilitySelectedTextRange:", "setAccessibilitySelectedTextRanges:":
            return ownsSystemTextTarget && selectionStateRevision == document.revision
                && viewSelectionState != nil
        default:
            return super.isAccessibilitySelectorAllowed(selector)
        }
    }

    /// 业务作用：把原生主项优先的坐标转换为一次完整选择发布，保留已有稳定身份。
    /// 参数说明:
    /// - ranges: 有界且有明确主项的原始 UTF-16 范围。
    /// 返回：仍持有当前发布权且全部范围合法时更新；同一范围列表保留原方向、虚拟列及矩形形态。
    private func applyAccessibilitySelection(_ ranges: [NSRange]) {
        // 焦点和预编辑拥有当前选择；不允许旧窗口用上一修订的辅助请求替换该状态。
        guard ownsSystemTextTarget, selectionStateRevision == document.revision,
            let previous = viewSelectionState
        else {
            return
        }
        let secondary = previous.entries.lazy.filter { $0.id != previous.primaryID }
        let sources = [previous.primary] + Array(secondary.prefix(ranges.count - 1))
        if ranges.count == previous.entries.count,
            zip(ranges, sources).allSatisfy({ $0 == accessibilityRange(forBytes: $1.selection.range) })
        {
            return
        }
        var entries: [SelectionEntry] = []
        entries.reserveCapacity(ranges.count)
        for (index, range) in ranges.enumerated() {
            guard let bytes = document.text.byteRange(range) else {
                return
            }
            let source = sources.indices.contains(index) ? sources[index] : nil
            entries.append(
                SelectionEntry(
                    id: source?.id ?? UUID(),
                    selection: TextSelection(anchor: bytes.lower, head: bytes.upper)
                )
            )
        }
        do {
            try setSelectionState(SelectionState(entries: entries))
            refresh(reveal: true)
            onSelection?()
        }
        catch {
            onStatus?(error.localizedDescription)
        }
    }

    /// 业务作用：辅助功能选择替换进入同一撤销事务，原输入权限先于系统载荷。
    /// 参数说明:
    /// - value: 系统提交的新选择文字，空值没有明确写入目标。
    /// 返回：仅单一实际选择可应用完整替换，拒绝保留原输入。
    public override func setAccessibilitySelectedText(_ value: String?) {
        guard let value, let range = systemTextSelection else {
            return
        }
        replaceSystemTextSelection(value, range: range, name: "辅助功能选择编辑")
    }

    /// 业务作用：显式辅助功能写入可以整份替换实际正文，原候选和编辑保护优先。
    /// 参数说明:
    /// - value: 系统提交的完整新正文，须为纯文本。
    /// 返回：成功修改共享一项撤销历史；未获得当前焦点、非法输入或失败时保持原正文。
    public override func setAccessibilityValue(_ value: Any?) {
        // 不能用系统的新文本覆盖仍待确认的候选，也不能沿上一窗口的焦点写入共享正文。
        guard ownsSystemTextTarget, !document.isReadOnly, let text = value as? String,
            text.utf8.prefix(Self.maximumSystemTextBytes + 1).count <= Self.maximumSystemTextBytes,
            synchronizeDocumentSelectionState()
        else {
            return
        }
        do {
            let range = ByteRange(0, document.text.byteCount)
            guard try document.commit([TextEdit(range, text)], name: "辅助功能编辑") else {
                return
            }
            refresh(reveal: true)
            onChange?()
        }
        catch {
            onStatus?(error.localizedDescription)
        }
    }
}
