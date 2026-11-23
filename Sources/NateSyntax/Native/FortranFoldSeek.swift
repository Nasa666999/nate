import Foundation
import NateCore

extension FortranFoldScanner {
    /// 业务作用：forall 与 where 只在原生括号及后继上下文授予块资格时增加折叠，同行正文不被隐藏成块。
    /// 参数说明:
    /// - end: 当前明确关键字的包含式末端。
    /// - row: 关键字所在的真实物理行。
    /// - actualRows: 同源完整原文的真实行数。
    /// 返回：原生语句或块分类的层级变化；续行缺少真实后继或共同预算不足时拒绝。
    mutating func conditionalDelta(after end: Int, row: Int, actualRows: Int) throws -> Int {
        var position = end + 1
        while try byte(at: position) != 40, position < bytes.count {
            position += 1
        }
        let openingStyle = try style(at: position)
        var depth = 1
        while position < bytes.count {
            position += 1
            let value = try byte(at: position)
            if try style(at: position) == openingStyle {
                if value == 40 {
                    depth += 1
                }
                if value == 41 {
                    depth -= 1
                }
                if depth == 0 {
                    break
                }
            }
        }
        var currentRow = row
        while position < bytes.count {
            position += 1
            let value = try byte(at: position)
            let identity = try style(at: position)
            let ending = value == 13 || value == 10
            if !ending, identity == 1 || FortranCharacters.blank(UInt32(value)) {
                continue
            }
            if fixedForm {
                if !ending {
                    break
                }
                if currentRow < actualRows - 1 {
                    currentRow += 1
                    position = starts[currentRow]
                    let continuation = try byte(at: position + 5)
                    if try style(at: position + 5) == 14,
                        !FortranCharacters.blank(UInt32(continuation)), continuation != 48
                    {
                        position += 5
                        continue
                    }
                    return 1
                }
            }
            else {
                if value == 38, identity == 14 {
                    position = try continuedPosition(from: position + 1)
                    continue
                }
                if ending {
                    return 1
                }
                break
            }
        }
        return 0
    }
}
