import Foundation

public enum DocumentTabLayout: String, CaseIterable, Codable, Sendable {
    case horizontal
    case vertical
    case multiline
}

public struct DocumentTabCell: Sendable, Equatable {
    public let documentID: UUID
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct DocumentTabLayoutPlan: Sendable, Equatable {
    public let mode: DocumentTabLayout
    public let cells: [DocumentTabCell]
    public let width: Double
    public let height: Double

    /// 业务作用：按稳定文档顺序建立有限标签几何，长名称不能无限扩大单个标签或产生非法坐标。
    /// 参数说明:
    /// - mode: 用户选择的水平、垂直或多行布局。
    /// - documentIDs: 最多一千零二十四个唯一文档身份。
    /// - naturalWidths: 与身份一一对应的原生标题容器测量宽度。
    /// - viewportWidth: 实际标签视口宽度，必须为有限正数。
    /// 返回：完整的有序几何及内容范围；非法、超量或不完整输入整体拒绝。
    public init(
        mode: DocumentTabLayout,
        documentIDs: [UUID],
        naturalWidths: [Double],
        viewportWidth: Double
    ) throws {
        guard documentIDs.count <= 1024, Set(documentIDs).count == documentIDs.count,
            naturalWidths.count == documentIDs.count, viewportWidth.isFinite,
            viewportWidth > 0, viewportWidth <= 1_048_576,
            naturalWidths.allSatisfy({
                $0.isFinite && $0 >= 0 && $0 <= 1_048_576
            })
        else {
            throw NateError.message("标签布局需要有限宽度和最多 1024 个唯一身份的完整测量。")
        }
        self.mode = mode
        let padding = mode == .horizontal ? 4 : min(4, max(0, (viewportWidth - 1) / 2))
        let available = viewportWidth - padding * 2
        var x = padding
        var y: Double = 0
        var frames: [DocumentTabCell] = []
        for (id, naturalWidth) in zip(documentIDs, naturalWidths) {
            let bounded = min(320, max(72, naturalWidth))
            let cellWidth: Double
            switch mode {
            case .horizontal:
                cellWidth = bounded
            case .vertical:
                cellWidth = available
            case .multiline:
                cellWidth = min(available, bounded)
                if x > padding, x + cellWidth > viewportWidth - padding {
                    x = padding
                    y += 33
                }
            }
            frames.append(
                DocumentTabCell(
                    documentID: id,
                    x: x,
                    y: y,
                    width: cellWidth,
                    height: 32
                )
            )
            if mode == .vertical {
                y += 33
            }
            else {
                x += cellWidth + 1
            }
        }
        cells = frames
        width =
            mode == .horizontal ? max(viewportWidth, x - (frames.isEmpty ? 0 : 1) + padding) : viewportWidth
        height = mode == .vertical ? max(33, y) : max(33, y + 33)
    }

    /// 业务作用：真实二维位置按当前行列确定唯一插入顺序，滚动后的坐标仍以原文档身份排列。
    /// 参数说明:
    /// - x: 标签内容坐标中的横向位置。
    /// - y: 标签内容坐标中的纵向位置。
    /// 返回：零至标签数量之间的完整插入序号；非有限坐标拒绝。
    public func insertionIndex(x: Double, y: Double) throws -> Int {
        guard x.isFinite, y.isFinite else {
            throw NateError.invalidRange
        }
        for (index, cell) in cells.enumerated() {
            switch mode {
            case .horizontal:
                if x < cell.x + cell.width / 2 {
                    return index
                }
            case .vertical:
                if y < cell.y + cell.height / 2 {
                    return index
                }
            case .multiline:
                if y < cell.y {
                    return index
                }
                if y < cell.y + 33 {
                    if x < cell.x + cell.width / 2 {
                        return index
                    }
                    if index + 1 == cells.count || cells[index + 1].y > cell.y {
                        return index + 1
                    }
                }
            }
        }
        return cells.count
    }
}
