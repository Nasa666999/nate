enum FortranDerivedType {
    private static let intrinsicNames: Set<String> = [
        "character", "complex", "doubleprecision", "integer", "logical", "real",
    ]

    /// 业务作用：由完整派生类型声明取得可绑定的名称，正在编辑的组件声明和选择分支不能打开类型块。
    /// 参数说明:
    /// - atoms: TYPE 之后的真实词元，已排除字面标点和语句分隔符。
    /// - check: 本次多个换行位置共用的继续资格。
    /// 返回：合法属性、保留分隔符、名称及可选参数均确认时交回类型名，其它类型语句为空。
    static func name(in atoms: ArraySlice<FortranIndentationLine.Atom>, check: () throws -> Void) throws
        -> String?
    {
        var remainder = atoms
        var attributes: Set<String> = []
        while remainder.first?.value == "," {
            try check()
            remainder = remainder.dropFirst()
            guard let attribute = remainder.first?.value else {
                return nil
            }
            remainder = remainder.dropFirst()
            switch attribute {
            case "abstract":
                guard attributes.insert(attribute).inserted else {
                    return nil
                }
            case "public", "private":
                guard attributes.insert("access").inserted else {
                    return nil
                }
            case "extends", "bind":
                guard attributes.insert(attribute).inserted, remainder.count >= 3,
                    remainder.first?.value == "(",
                    validName(remainder[remainder.startIndex + 1]),
                    attribute != "bind" || remainder[remainder.startIndex + 1].value == "c",
                    remainder[remainder.startIndex + 2].value == ")"
                else {
                    return nil
                }
                remainder = remainder.dropFirst(3)
            default:
                return nil
            }
        }
        let separator =
            remainder.count >= 2 && remainder.first?.value == ":"
            && remainder[remainder.startIndex + 1].value == ":"
            && remainder[remainder.startIndex].range.upper == remainder[remainder.startIndex + 1].range.lower
        guard attributes.isEmpty || separator else {
            return nil
        }
        if separator {
            remainder = remainder.dropFirst(2)
        }
        guard let name = remainder.first, validName(name), !intrinsicNames.contains(name.value),
            separator || name.value != "is"
        else {
            return nil
        }
        let parameters = remainder.dropFirst()
        guard !parameters.isEmpty else {
            return name.value
        }
        guard parameters.count >= 3, parameters.first?.value == "(", parameters.last?.value == ")" else {
            return nil
        }
        var expectsName = true
        var names: Set<String> = []
        for token in parameters.dropFirst().dropLast() {
            try check()
            if expectsName {
                guard validName(token), names.insert(token.value).inserted else {
                    return nil
                }
            }
            else if token.value != "," {
                return nil
            }
            expectsName.toggle()
        }
        return expectsName ? nil : name.value
    }

    /// 业务作用：Fortran 声明名从原词元确认，属性标点和数字不能取得结构名资格。
    /// 参数说明:
    /// - token: 当前确认的完整原始词元。
    /// 返回：以字母开头的 ASCII 名称时为真。
    private static func validName(_ token: FortranIndentationLine.Atom) -> Bool {
        token.identifier
            && token.value.utf8.first.map {
                (97...122).contains($0)
            } == true
    }
}
