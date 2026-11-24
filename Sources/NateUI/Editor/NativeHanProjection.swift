import AppKit
import NateCore

@MainActor
struct NativeHanProjection {
    private enum Source {
        case plain(PlainHanLine)
        case tabbed(HanTabColumns)
    }

    private struct Proof: Hashable {
        let font: NSFont
        let width: Int
    }

    private let source: Source
    let font: NativeHanLineFont
    private let ascii: CGFloat
    private static var verified: [Proof: Bool] = [:]

    /// 业务作用：一个已校验基础字体配合同一套全角字体，制表索引只能沿相同的真实步距使用。
    /// 参数说明:
    /// - plain: 已验证的无 Tab 原始正文。
    /// - tabbed: 已在实际原生字体及 Tab 设置上验证的混合正文。
    /// - base: 当前实际使用的基础字体。
    /// - ascii: 当前原生字体的已确认 ASCII 步距。
    /// 返回：可用的独立原生窗口来源；字体或字体栏位变化时拒绝旧索引。
    init?(plain: PlainHanLine?, tabbed: HanTabColumns?, base: NSFont, ascii: CGFloat) {
        guard let font = NativeHanLineFont.resolve(from: base) else {
            return nil
        }
        if let tabbed {
            guard plain == nil, tabbed.metrics.asciiAdvance == ascii,
                tabbed.metrics.hanAdvance == font.advance
            else {
                return nil
            }
            source = .tabbed(tabbed)
        }
        else if let plain {
            source = .plain(plain)
        }
        else {
            return nil
        }
        self.font = font
        self.ascii = ascii
    }

    /// 业务作用：当前可见段落之外的系统坐标使用实际原文 UTF-16 长度。
    /// 参数说明: 无。
    /// 返回：完整逻辑行的真实 UTF-16 单元数，包含制表符。
    var characterCount: Int {
        switch source {
        case .plain(let line): line.characterCount
        case .tabbed(let line): line.characterCount
        }
    }

    /// 业务作用：全行滚动宽度只读取实际末尾坐标或固定的后台测量结果。
    /// 参数说明: 无。
    /// 返回：当前完整逻辑行已证实的横向距离。
    var width: CGFloat {
        switch source {
        case .plain(let line):
            line.distance(through: line.characterCount, ascii: ascii, han: font.advance) ?? 0
        case .tabbed(let line): line.width
        }
    }

    /// 业务作用：只有真实 Tab 的汉字窗口需要恢复当前语言的制表间隔。
    /// 参数说明: 无。
    /// 返回：实际原生制表宽度；直接汉字窗口为空。
    var tabWidth: Int? {
        if case .tabbed(let line) = source {
            return line.metrics.tabWidth
        }
        return nil
    }

    /// 业务作用：把当前真实 UTF-16 端点映射回已确认原文，字节切片从不截断标量。
    /// 参数说明:
    /// - character: 位于完整逻辑行的相对字符端点。
    /// 返回：存在时为正文绝对原字节端点。
    func byte(at character: Int) -> Int? {
        switch source {
        case .plain(let line): line.byte(at: character)
        case .tabbed(let line): line.byte(at: character)
        }
    }

    /// 业务作用：当前位置的横向距离用于绘制，只有真实 Tab 需要额外保留原段落制表网格偏量。
    /// 参数说明:
    /// - character: 完整逻辑行内的相对 UTF-16 端点。
    /// 返回：同一完整行坐标中的横向距离及局部首行缩进，位置无效时为空。
    func geometry(at character: Int) -> (distance: CGFloat, phase: CGFloat)? {
        switch source {
        case .plain(let line):
            return line.distance(through: character, ascii: ascii, han: font.advance).map {
                ($0, 0)
            }
        case .tabbed(let line):
            return line.geometry(at: character).map {
                ($0.distance, $0.phase)
            }
        }
    }

    /// 业务作用：从真实单行的有序横向位置选择附近窗口，具体字符命中仍由局部原生插入点确认。
    /// 参数说明:
    /// - x: 已限制在完整逻辑行内的有限像素位置。
    /// 返回：使用真实可见前缀取得的相邻字符端点。
    func character(atOrBefore x: CGFloat) -> Int? {
        switch source {
        case .plain(let line): line.character(atOrBefore: x, ascii: ascii, han: font.advance)
        case .tabbed(let line): line.character(atOrBefore: x)
        }
    }

    /// 业务作用：先使用两种真实字体及有偏移的独立 TextKit 2 段落复验制表网格，后续后台索引沿同一真实字形公开。
    /// 参数说明:
    /// - base: 当前编辑器实际应用的基础字体。
    /// - ascii: 已确认的实际 ASCII 步距。
    /// - width: 当前语言真实 Tab 停靠列数。
    /// - appearance: 当前视图的原生外观。
    /// 返回：完整段落及裁剪后远处片段在真实制表位置一致时提供度量。
    static func tabGrid(
        base: NSFont,
        ascii: CGFloat,
        width: Int,
        appearance: NSAppearance
    ) -> HanTabColumns.Metrics? {
        guard let han = NativeHanLineFont.resolve(from: base),
            let metrics = HanTabColumns.Metrics(asciiAdvance: ascii, hanAdvance: han.advance, tabWidth: width)
        else {
            return nil
        }
        let key = Proof(font: base, width: width)
        if let result = verified[key] {
            return result ? metrics : nil
        }
        let value = "abc中X\t文！Z\t漢，字\t  終\tE"
        let text = PieceTree(value)
        let snapshot = DocumentSnapshot(id: UUID(), revision: 0, text: text)
        let range = ByteRange(0, text.byteCount)
        guard let index = try? HanTabColumns(text: text, range: range, metrics: metrics) else {
            return nil
        }
        let valid = [0, 3, 4, 7].allSatisfy { beginning in
            guard let byte = index.byte(at: beginning), let position = index.geometry(at: beginning) else {
                return false
            }
            let sample = LineLayout(
                snapshot: snapshot,
                range: ByteRange(byte, text.byteCount),
                font: base,
                width: index.width - position.distance + position.phase + 64,
                tokens: [],
                rtl: false,
                appearance: appearance,
                nativeASCII: true,
                nativeHanFont: han,
                tabWidth: width,
                nativeTabPhase: position.phase
            )
            guard sample.isSingleVisualLine else {
                return false
            }
            let origin = sample.caret(at: 0)
            return (beginning...index.characterCount).allSatisfy { character in
                guard let expected = index.geometry(at: character) else {
                    return false
                }
                let caret = sample.caret(at: character - beginning)
                let translated = caret.minX + position.distance - position.phase
                return abs(translated - expected.distance) < 0.02 && abs(caret.minY - origin.minY) < 0.01
            }
        }
        if verified.count >= 32 {
            verified.removeAll()
        }
        verified[key] = valid
        return valid ? metrics : nil
    }
}
