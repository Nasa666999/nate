import Foundation

extension CSSScanner {
    /// 业务作用：CSS 当前完整词法段按固定优先顺序重新定类，历史片段只有完成当前段后才可发布。
    /// 参数说明: 无。
    /// 返回：当前未封闭段取得完整原生类别；取消或比较预算不足时抛错。
    mutating func classify() throws {
        let word = CSSRules.candidate(state.prefix)
        if [6, 15, 17, 19, 7].contains(state.mode) {
            for (group, mode) in [(0, 6), (2, 15), (3, 17), (5, 19)] {
                if try rules.contains(word, group: group, budget: &budget) {
                    state.mode = UInt8(mode)
                    return
                }
            }
            state.mode = 7
        }
        else if [3, 18, 20, 21, 4].contains(state.mode) {
            if state.op == 58, state.opPrevious != 58,
                try rules.contains(word, group: 1, budget: &budget)
            {
                state.mode = 3
            }
            else if state.opPrevious == 58,
                try rules.contains(word, group: 4, budget: &budget)
            {
                state.mode = 18
            }
            else if (state.op == 58 || state.op == 40 && state.beforeOperator == 20),
                state.opPrevious != 58,
                try rules.contains(word, group: 6, budget: &budget)
            {
                state.mode = 20
            }
            else if state.opPrevious == 58,
                try rules.contains(word, group: 7, budget: &budget)
            {
                state.mode = 21
            }
            else {
                state.mode = 4
            }
        }
        else if state.mode == 11 {
            if word != Data("important".utf8) {
                state.mode = 8
            }
        }
        else if state.mode == 12, state.op == 64,
            ["media", "supports", "document", "-moz-document"].contains(String(decoding: word, as: UTF8.self))
        {
            state.mode = 22
        }
    }

    /// 业务作用：CSS 名称保留原生非 ASCII 标量、连字符和下划线，不按区域设置拆分选择器。
    /// 参数说明:
    /// - scalar: 当前完整 Unicode 标量。
    /// 返回：名称可继续接纳该标量时为真。
    static func word(_ scalar: UInt32) -> Bool {
        scalar >= 128 || scalar >= 48 && scalar <= 57 || scalar >= 65 && scalar <= 90
            || scalar >= 97 && scalar <= 122 || scalar == 45 || scalar == 95
    }

    /// 业务作用：CSS 只有明确的标点集合参与原生操作符分派，不把数值或文字当作结构。
    /// 参数说明:
    /// - scalar: 当前完整 Unicode 标量。
    /// 返回：该标量属于原生 CSS 操作符集合时为真。
    static func op(_ scalar: UInt32) -> Bool {
        scalar < 128 && "{}:,;.# !@*>+=~|[]()".utf8.contains(UInt8(scalar)) && scalar != 32
    }

    /// 业务作用：需要候选终止或后继 SetState 才能定类的段不能提前发布其跨行颜色。
    /// 参数说明:
    /// - mode: 当前原生词法类别。
    /// 返回：后继文字仍可重新定类当前整个段时为真。
    static func pending(_ mode: UInt8) -> Bool {
        [6, 15, 17, 19, 7, 3, 18, 20, 21, 4, 11, 12].contains(mode)
    }
}
