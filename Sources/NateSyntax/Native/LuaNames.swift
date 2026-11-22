import Foundation

extension LuaLexing {
    /// 业务作用：八组名称及用户子样式采用最长复合前缀，关键字不能拼入句点或冒号名称。
    /// 参数说明: 无。
    /// 返回：完整名称和匹配前缀已消费；未知尾部保持标识符身份，goto 后的名称单独取得标签身份。
    mutating func identifier() throws {
        let start = cursor
        var end = start
        var candidate: [UInt8] = []
        var bestEnd = start
        var bestStyle = 11
        var foundGoto = false
        while true {
            let old = end
            end += 1
            while Self.word(byte(end)) {
                try budget.consume()
                end += 1
            }
            let part = Data(bytes[old..<end])
            if old > start, rules.groups[0].contains(part) {
                end = old - 1
                candidate.removeLast()
                break
            }
            candidate.append(contentsOf: bytes[old..<end])
            // 复合名称每次重新匹配都计算完整前缀成本，密集句点不能产生无预算的平方级工作量。
            for _ in candidate {
                try budget.consume()
            }
            let name = Data(candidate)
            var matched = false
            for index in 0..<8 where rules.groups[index].contains(name) {
                bestStyle = index == 0 ? 5 : index + 12
                bestEnd = end
                matched = true
                break
            }
            if !matched {
                // 用户子样式按原顺序登记，后面的同名声明覆盖前面声明，普通八组词表仍具有优先权。
                for index in (8..<12).reversed() where rules.groups[index].contains(name) {
                    bestStyle = index + 120
                    bestEnd = end
                    break
                }
            }
            if bestStyle == 5 {
                foundGoto = candidate.elementsEqual("goto".utf8)
                break
            }
            let separator = byte(end)
            if (separator == 46 || separator == 58), Self.wordStart(byte(end + 1)) {
                candidate.append(separator)
                end += 1
            }
            else {
                break
            }
        }
        let initialWidth = width(start)
        try advance(initialWidth)
        state.mode = bestStyle
        if bestEnd > start {
            let committed = bestEnd - start - 1
            try advanceProjected(committed, style: bestStyle)
            try change(11)
            let remaining = end - start - initialWidth - committed
            if remaining > 0 {
                try advanceProjected(remaining, style: 11)
            }
        }
        else {
            try advanceProjected(end - start - initialWidth, style: 11)
        }
        try change(0)
        if foundGoto {
            while byte(cursor) == 32 || byte(cursor) == 9 {
                try advance(1)
            }
            guard Self.wordStart(byte(cursor)) else {
                return
            }
            try change(20)
            let label = cursor
            while Self.word(byte(cursor)) {
                try advance(1)
            }
            if rules.groups[0].contains(Data(bytes[label..<cursor])) {
                state.mode = 5
            }
            try change(0)
        }
    }

    /// 业务作用：双冒号只有完整、非关键字的同行名称与末端双冒号才能取得标签样式。
    /// 参数说明: 无。
    /// 返回：完整标签按首尾标记及名称分别着色；不完整候选只消费原操作符，不隐藏普通名称。
    mutating func label() throws {
        try advance(1)
        var first = cursor
        while byte(first) == 32 || byte(first) == 9 {
            try budget.consume()
            first += 1
        }
        guard Self.wordStart(byte(first)) else {
            return
        }
        var last = first + 1
        while Self.word(byte(last)) {
            try budget.consume()
            last += 1
        }
        guard !rules.groups[0].contains(Data(bytes[first..<last])) else {
            return
        }
        var closing = last
        while byte(closing) == 32 || byte(closing) == 9 {
            try budget.consume()
            closing += 1
        }
        guard byte(closing) == 58, byte(closing + 1) == 58 else {
            return
        }
        state.mode = 20
        try change(0)
        try advance(first - cursor)
        try change(20)
        try advance(last - cursor)
        try change(0)
        try advance(closing - cursor)
        try change(20)
        try advance(2)
    }
}
