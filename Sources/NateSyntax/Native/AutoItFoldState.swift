import Foundation
import NateCore

struct AutoItFoldState {
    var current = 1024
    var next = 1024

    /// 业务作用：AutoIt 的原始首词决定控制流折叠，分支和结束语句分别保留原生当前层级与后继层级的先后关系。
    /// 参数说明:
    /// - word: 最多十个 ASCII 小写字节的原生首词。
    /// - then: if 行的原生末尾 then 资格，不执行额外的语义重解释。
    /// 返回：本行和后继行层级已更新；范围发布前仍须统一确认层级容量。
    mutating func keyword(_ word: [UInt8], then: Bool) {
        let value = String(decoding: word, as: UTF8.self)
        if value == "if" && then {
            next += 1
        }
        if ["do", "for", "func", "while", "with", "#region"].contains(value) {
            next += 1
        }
        if value == "select" || value == "switch" {
            next += 2
        }
        if ["endfunc", "endif", "next", "until", "endwith", "wend"].contains(value) {
            next -= 1
            current -= 1
        }
        if value == "case" || value == "else" || value == "elseif" {
            current -= 1
        }
        if value == "endselect" || value == "endswitch" {
            next -= 2
            current -= 2
        }
        if value == "#endregion" {
            next -= 1
        }
    }

    /// 业务作用：相邻的预处理及同类注释按原生行类别组成完整块，块注释结束行与普通注释尾行分别收束。
    /// 参数说明:
    /// - before: 前一完整行的首个有效类别。
    /// - current: 当前完整行的首个有效类别。
    /// - after: 后一完整行的首个有效类别。
    /// 返回：预处理及注释折叠的当前和后继层级已更新。
    mutating func adjacent(before: UInt8, current: UInt8, after: UInt8) {
        if current == 11 {
            if before != 11 && after == 11 {
                next += 1
            }
            else if before == 11 && after != 11 {
                next -= 1
            }
        }
        if current == 1 || current == 2 {
            if before != current && [1, 2].contains(after) && after == current {
                next += 1
            }
            else if [1, 2].contains(before) && after != 1 && before == 1 && current == 1 {
                next -= 1
            }
            else if [1, 2].contains(before) && after != 2 && current == 2 {
                next -= 1
                self.current -= 1
            }
        }
    }
}
