import Foundation
import NateCore

extension FortranFoldScanner {
    /// 业务作用：连续注释折叠采用原生原字节列，显示宽度、Unicode 空白及文字中的标记不取得注释行资格。
    /// 参数说明:
    /// - row: 当前固定原文的物理行。
    /// 返回：首个注释标记的原字节列；普通行为空，预算不足时拒绝。
    mutating func commentColumn(row: Int) throws -> Int? {
        guard starts.indices.contains(row) else {
            throw NateError.invalidRange
        }
        var position = starts[row]
        var column = 0
        while position < bytes.count {
            let value = try byte(at: position)
            if value == 33 || fixedForm && column == 0 && [67, 99, 42].contains(value) {
                return column
            }
            if !FortranCharacters.blank(UInt32(value)) {
                break
            }
            position += 1
            column += 1
        }
        return nil
    }

    /// 业务作用：至少四条同列连续注释才形成原生折叠开闭，文件末尾空行不伪装成注释后继。
    /// 参数说明:
    /// - row: 正在提交层级的真实物理行。
    /// - columns: 同源完整原文中每行的明确注释列。
    /// - actualRows: 排除 EOF 虚拟空行后的真实行数。
    /// 返回：本注释行对应的原生层级变化；不满足同列连续条件时为零。
    mutating func commentDelta(row: Int, columns: [Int?], actualRows: Int) throws -> Int {
        try budget.consume()
        guard row >= 0, row < actualRows, let column = columns[row] else {
            return 0
        }
        let previous = row > 0 ? columns[row - 1] : nil
        let following = row + 1 < actualRows ? columns[row + 1] : nil
        if following != column {
            for distance in 1...3 {
                try budget.consume()
                if row - distance < 0 || columns[row - distance] != column {
                    return 0
                }
            }
            return -1
        }
        if previous != column {
            for distance in 1...3 {
                try budget.consume()
                if row + distance >= actualRows || columns[row + distance] != column {
                    return 0
                }
            }
            return 1
        }
        return 0
    }
}
