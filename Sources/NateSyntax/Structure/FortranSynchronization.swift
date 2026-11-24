import NateCore

enum FortranSynchronization {
    private typealias Atom = FortranIndentationLine.Atom

    /// 业务作用：CRITICAL 的可选状态列表须有真实分隔符和完整参数，普通同名表达式不能开启块。
    /// 参数说明:
    /// - tail: CRITICAL 后保留下来的实际词元。
    /// - check: 全部换行目标共用的继续资格。
    /// 返回：没有参数或已有完整状态列表时为真，任何不完整或重复状态均无结构资格。
    static func opensCritical(_ tail: ArraySlice<FortranIndentationLine.Atom>, check: () throws -> Void)
        throws -> Bool
    {
        if tail.isEmpty {
            return true
        }
        guard let parsed = try arguments(tail, check: check), parsed.remainder.isEmpty else {
            return false
        }
        return try validStatuses(parsed.values, check: check)
    }

    /// 业务作用：只有具备完整队值、合法次序和原生界定符的 CHANGE TEAM 语句取得块资格。
    /// 参数说明:
    /// - tail: CHANGE TEAM 后保留的实际参数。
    /// - check: 所有光标使用的共同截止及继续资格。
    /// 返回：已确认参数边界、协同数组关联及状态说明时为真，普通表达式或未完成语句为假。
    static func opensTeam(_ tail: ArraySlice<FortranIndentationLine.Atom>, check: () throws -> Void) throws
        -> Bool
    {
        guard let parsed = try arguments(tail, check: check), parsed.remainder.isEmpty,
            let team = parsed.values.first, try isTeamValue(team, check: check)
        else {
            return false
        }
        var statuses: Set<String> = []
        for value in parsed.values.dropFirst() {
            try check()
            if let name = statusName(value) {
                guard statuses.insert(name).inserted else {
                    return false
                }
            }
            else {
                guard statuses.isEmpty, try isAssociation(value, check: check) else {
                    return false
                }
            }
        }
        return true
    }

    /// 业务作用：首项保留完整队值表达式的外层界定符，命名状态不能占用队值的位置。
    /// 参数说明:
    /// - value: 参数列表中与后继状态和协同数组分开的第一个实际参数。
    /// - check: 当前输入仍有资格继续准备的检查。
    /// 返回：边界完整且外层没有赋值符时为真。
    private static func isTeamValue(_ value: ArraySlice<Atom>, check: () throws -> Void) throws -> Bool {
        guard let first = value.first, let last = value.last, first.identifier || first.value == "(",
            last.identifier || [")", "]"].contains(last.value)
        else {
            return false
        }
        var depth = 0
        for atom in value {
            try check()
            switch atom.value {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth -= 1
            case "=" where depth == 0:
                return false
            default:
                break
            }
        }
        return true
    }

    /// 业务作用：END TEAM 的可选状态列表和名称放在完整原语句范围内确认，避免错误结束其它外层结构。
    /// 参数说明:
    /// - tail: END TEAM 后保留下来的原词元。
    /// - check: 多光标缩进共享的继续资格。
    /// 返回：可用于匹配现有块的关闭动作；尾部不完整或有多余词元时为中性。
    static func closesTeam(_ tail: ArraySlice<FortranIndentationLine.Atom>, check: () throws -> Void)
        throws -> FortranIndentationLine.Event
    {
        var name = tail
        if tail.first?.value == "(" {
            guard let parsed = try arguments(tail, check: check),
                try validStatuses(parsed.values, check: check)
            else {
                return .neutral
            }
            name = parsed.remainder
        }
        guard name.isEmpty || name.count == 1 && name.first?.identifier == true else {
            return .neutral
        }
        return .closing(.team, name: name.first?.value)
    }

    /// 业务作用：逐个核对同一同步声明的状态参数，重复状态不加入外层缩进证据。
    /// 参数说明:
    /// - values: 同一对原括号里已完整分隔的参数。
    /// - check: 本次换行的继续资格。
    /// 返回：全部参数是不同的 STAT 或 ERRMSG 时为真。
    private static func validStatuses(_ values: [ArraySlice<Atom>], check: () throws -> Void) throws -> Bool {
        var seen: Set<String> = []
        for value in values {
            try check()
            guard let name = statusName(value), seen.insert(name).inserted else {
                return false
            }
        }
        return true
    }

    /// 业务作用：区分实际命名状态参数与字符串、普通名称或比较表达式。
    /// 参数说明:
    /// - value: 一个已经确认连续边界的完整参数。
    /// 返回：具备赋值界定符和完整变量起点的状态名，其它内容为空。
    private static func statusName(_ value: ArraySlice<Atom>) -> String? {
        guard value.count >= 3, let name = value.first?.value, ["stat", "errmsg"].contains(name),
            value[value.startIndex + 1].value == "=", value[value.startIndex + 2].identifier,
            let last = value.last, last.identifier || [")", "]"].contains(last.value)
        else {
            return nil
        }
        return name
    }

    /// 业务作用：协同数组关联只接受实际别名、原协同维度和原箭头，普通赋值不能伪装成 CHANGE TEAM 参数。
    /// 参数说明:
    /// - value: 已完整分隔的一个参数。
    /// - check: 当前输入可以继续的资格。
    /// 返回：左端有完整协同维度且右端保留一个原命名选择器时为真。
    private static func isAssociation(_ value: ArraySlice<Atom>, check: () throws -> Void) throws -> Bool {
        guard value.count >= 7, value.first?.identifier == true,
            value[value.startIndex + 1].value == "["
        else {
            return false
        }
        var brackets = 1
        for index in (value.startIndex + 2)..<value.endIndex {
            try check()
            let token = value[index].value
            if token == "[" {
                brackets += 1
            }
            else if token == "]" {
                brackets -= 1
                if brackets == 0 {
                    guard index > value.startIndex + 2, index + 4 == value.endIndex else {
                        return false
                    }
                    let equal = value[index + 1]
                    let greater = value[index + 2]
                    return equal.value == "=" && greater.value == ">"
                        && equal.range.upper == greater.range.lower
                        && value[index + 3].identifier
                }
            }
        }
        return false
    }

    /// 业务作用：状态、协同维度和普通表达式共用原生参数边界，内层列表和字面不能切断外层声明。
    /// 参数说明:
    /// - input: 紧随结构关键词的真实括号范围及保留后缀。
    /// - check: 语句和全部光标共享的继续资格。
    /// 返回：已确认的各参数及闭合之后的尚未解释词元；不匹配为空，超限整批拒绝。
    private static func arguments(_ input: ArraySlice<Atom>, check: () throws -> Void) throws
        -> (values: [ArraySlice<Atom>], remainder: ArraySlice<Atom>)?
    {
        guard input.first?.value == "(" else {
            return nil
        }
        var closing = [")"]
        var values: [ArraySlice<Atom>] = []
        var start = input.startIndex + 1
        for index in start..<input.endIndex {
            try check()
            let token = input[index].value
            switch token {
            case "(", "[":
                // 固定深度门禁保护待完成列表，未确认的长前缀不能产生部分结构结果。
                guard closing.count < 4096 else {
                    throw NateError.message("Fortran 同步结构参数超过 4096 层。")
                }
                closing.append(token == "(" ? ")" : "]")
            case ")", "]":
                guard closing.popLast() == token else {
                    return nil
                }
                if closing.isEmpty {
                    if start < index {
                        values.append(input[start..<index])
                    }
                    else if !values.isEmpty {
                        return nil
                    }
                    return (values, input[(index + 1)...])
                }
            case "," where closing.count == 1:
                guard start < index else {
                    return nil
                }
                values.append(input[start..<index])
                start = index + 1
            default:
                break
            }
        }
        return nil
    }
}
