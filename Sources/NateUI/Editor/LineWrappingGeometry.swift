import AppKit
import NateCore

extension LineLayout {
    /// 业务作用：每个原生视口都确认同一软换行步距和完整顺序，只有证明一致才可沿纵向平移。
    /// 参数说明:
    /// - advance: 当前字体已确认的单字形横向间距。
    /// - expected: 首个原生段落固定的列数、纵向步距及行底。
    /// - indexedRows: 已独立确认的实际断行，连续单词可采用已确认的列数。
    /// - tabWidth: 原生制表视觉行从自己的起点计算停靠的实际列宽。
    /// - narrowLetters: 同一原文及字体已确认的独立双字节窄字母可参与制表时为真。
    /// - mixedHan: 同一容器中原生验证的两类字形步距与视觉行高度。
    /// 返回：真实等宽软换行证据；存在未解释换行或坐标差异时为空。
    func uniformWrapping(
        advance: CGFloat,
        expected: WrappedASCIIGeometry? = nil,
        indexedRows: [ByteRange]? = nil,
        tabWidth: Int? = nil,
        narrowLetters: Bool = false,
        mixedHan: MixedHanWrapMetrics? = nil
    ) -> WrappedASCIIGeometry? {
        guard unavailableReason == nil, orderedPositions, orderedHeights, let first = nativeLines.first,
            mixedHan == nil || indexedRows != nil
        else {
            return nil
        }
        let columns = expected?.columns ?? first.upper
        let pitch = expected?.pitch ?? ((nativeLines.dropFirst().first?.bounds.minY ?? 0) - first.bounds.minY)
        let top = expected?.firstTop ?? first.bounds.minY
        let bottom = expected?.firstBottom ?? first.bounds.maxY
        guard columns > 0, pitch.isFinite, pitch > 0, bottom > top, characterCount > 0,
            nativeLines.count == (indexedRows?.count ?? (characterCount - 1) / columns + 1)
        else {
            return nil
        }
        let mixedGrid: HanTabColumns.Metrics?
        if let mixedHan, let tabWidth {
            guard
                let grid = HanTabColumns.Metrics(
                    asciiAdvance: mixedHan.asciiAdvance,
                    hanAdvance: mixedHan.hanAdvance,
                    tabWidth: tabWidth
                )
            else {
                return nil
            }
            mixedGrid = grid
        }
        else {
            mixedGrid = nil
        }
        var variableTop: CGFloat = 0
        for (index, row) in nativeLines.enumerated() {
            let indexed = indexedRows?[index]
            let lower: Int
            let count: Int
            if let indexed {
                guard let start = content.snapshot.text.utf16Offset(byte: indexed.lower),
                    let end = content.snapshot.text.utf16Offset(byte: indexed.upper)
                else {
                    return nil
                }
                lower = start - originUTF16
                count = end - start
            }
            else {
                lower = index * columns
                count = min(columns, characterCount - lower)
            }
            let cells: Int
            if let indexed, let tabWidth, mixedHan == nil {
                guard (1...32).contains(tabWidth) else {
                    return nil
                }
                if narrowLetters {
                    // 已证窄字形各占一个 UTF-16 单元，Tab 从每个实际视觉行首重新计列。
                    cells = content.snapshot.text.text(in: indexed).utf16.reduce(0) { current, unit in
                        unit == 9 ? current + tabWidth - current % tabWidth : current + 1
                    }
                }
                else {
                    guard
                        let measured = ASCIITabColumns.visualColumnCount(
                            in: content.snapshot.text.bytes(in: indexed),
                            tabWidth: tabWidth
                        )
                    else {
                        return nil
                    }
                    cells = measured
                }
            }
            else {
                cells = count
            }
            let originY: CGFloat
            let rowBottom: CGFloat
            let rowWidth: CGFloat
            if let mixedHan, let indexed {
                let hasHan: Bool
                originY = variableTop
                if let mixedGrid {
                    let units = content.snapshot.text.text(in: indexed).utf16
                    guard let distance = mixedGrid.visualWidth(of: units) else {
                        return nil
                    }
                    hasHan =
                        narrowLetters
                        ? units.contains(where: PlainHanLine.usesHanFont) : indexed.count != count
                    rowWidth = CGFloat(distance)
                }
                else {
                    let han = (indexed.count - count) / 2
                    hasHan = han != 0
                    rowWidth = CGFloat(count - han) * advance + CGFloat(han) * CGFloat(mixedHan.hanAdvance)
                }
                variableTop += CGFloat(hasHan ? mixedHan.hanHeight : mixedHan.asciiHeight)
                rowBottom = variableTop
            }
            else {
                originY = CGFloat(index) * pitch
                rowBottom = bottom + originY
                rowWidth = CGFloat(cells) * advance
            }
            guard row.lower == lower, row.upper == lower + count,
                abs(row.bounds.minY - (top + originY)) < 0.04,
                abs(row.bounds.maxY - rowBottom) < 0.04,
                abs(row.caret(at: lower).minX) < 0.02,
                abs(row.caret(at: row.upper).minX - rowWidth) < 0.04
            else {
                return nil
            }
        }
        return WrappedASCIIGeometry(columns: columns, pitch: pitch, firstTop: top, firstBottom: bottom)
    }
}
