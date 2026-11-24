import NateCore

struct PascalIndentationState {
    enum Keyword: String {
        case begin, end, `repeat`, until, `try`, except, finally, asm, record, `case`, of
        case `class`, object, interface, dispinterface
    }

    enum Event: Equatable {
        case keyword(Keyword)
        case grouping(UInt8)
        case terminator
        case period
        case directive
        case other
    }

    private struct Block {
        var opening: Keyword
        let prefix: String
        let depth: Int
        var hasBranch = false
    }

    private var blocks: [Block] = []
    private var groups: [UInt8] = []
    private var storedBytes = 0

    /// 业务作用：闭合或分支只能引用同一分组内最近的匹配块，当前行的前导空白不授予闭合资格。
    /// 参数说明:
    /// - event: 光标后或已消费的实际关键字。
    /// 返回：有效开端的完整原空白；未知、跨分组、未完整开始或已经分支时为空。
    func alignment(before event: Event) -> String? {
        guard let block = blocks.last, block.depth == groups.count else {
            return nil
        }
        switch event {
        case .keyword(.end) where block.opening != .repeat && block.opening != .case:
            return block.prefix
        case .keyword(.until) where block.opening == .repeat:
            return block.prefix
        case .keyword(.except), .keyword(.finally):
            return block.opening == .try && !block.hasBranch ? block.prefix : nil
        default:
            return nil
        }
    }

    /// 业务作用：按原字节顺序记录 Pascal 的独立块、分支及边界，光标只能使用自身前缀中已成立的开端。
    /// 参数说明:
    /// - event: 已完整位于当前扫描位置之前的真实符号。
    /// - prefix: 当前物理行完整的原始前导空白。
    /// 返回：本事件后应增加一级时返回开端空白；结构失效时只回收原资格，超限时拒绝整批准备。
    mutating func consume(_ event: Event, prefix: String) throws -> String? {
        switch event {
        case .keyword(.begin), .keyword(.repeat), .keyword(.try), .keyword(.asm), .keyword(.record):
            guard case .keyword(let word) = event else {
                return nil
            }
            try push(word, prefix: prefix)
            return prefix
        case .keyword(.case):
            // 变体记录的 case 与 record 共用 end，不另开一层会抢走记录的闭合资格。
            if blocks.last?.opening != .record {
                try push(.case, prefix: prefix)
            }
        case .keyword(.of):
            if let block = blocks.last, block.opening == .case, block.depth == groups.count {
                blocks[blocks.count - 1].opening = .of
                return block.prefix
            }
        case .keyword(.except), .keyword(.finally):
            if let prefix = alignment(before: event) {
                blocks[blocks.count - 1].hasBranch = true
                return prefix
            }
        case .keyword(.end), .keyword(.until):
            if alignment(before: event) != nil {
                pop()
            }
            else {
                // 未匹配的闭合可能来自不在本规则范围内的声明或未完成语句，旧的更外层开端不能接管。
                reset()
            }
        case .keyword(.class), .keyword(.object), .keyword(.interface), .keyword(.dispinterface), .directive:
            // 类型声明的前向形式和条件编译各分支没有共同结构证据，后续真实开端必须独立建立。
            reset()
        case .grouping(let byte):
            if byte == 40 || byte == 91 {
                guard groups.count < 4096 else {
                    throw NateError.message("Pascal 语言缩进的分组超过 4096 层。")
                }
                groups.append(byte)
            }
            else if groups.last == (byte == 41 ? 40 : 91) {
                groups.removeLast()
                while let block = blocks.last, block.depth > groups.count {
                    pop()
                }
            }
            else {
                reset()
            }
        case .terminator:
            if blocks.last?.opening == .case, blocks.last?.depth == groups.count {
                pop()
            }
        case .period, .other:
            break
        }
        return nil
    }

    /// 业务作用：活动块的层级与可复用前缀共用上限，密集开端不能保留无界对齐来源。
    /// 参数说明:
    /// - word: 实际建立本层的结构关键字。
    /// - prefix: 该位置所属物理行的原空白。
    /// 返回：完整结构入栈；层级或原空白容量超限时不建立该层。
    private mutating func push(_ word: Keyword, prefix: String) throws {
        guard blocks.count < 4096, prefix.utf8.count <= 1_048_576 - storedBytes else {
            throw NateError.message("Pascal 语言缩进超过 4096 层或活动前缀 1 MiB。")
        }
        blocks.append(Block(opening: word, prefix: prefix, depth: groups.count))
        storedBytes += prefix.utf8.count
    }

    /// 业务作用：已经闭合或离开分组的来源不再占用活动结构与原始空白容量。
    /// 参数说明: 无。
    /// 返回：退出最近的已确认块，空栈保持不变。
    private mutating func pop() {
        if let block = blocks.popLast() {
            storedBytes -= block.prefix.utf8.count
        }
    }

    /// 业务作用：旧作用域不再具备闭合资格时回收全部结构，仍允许下一个已知开端重新建立证据。
    /// 参数说明: 无。
    /// 返回：结构、分组及其持有的前缀额度同时清空。
    private mutating func reset() {
        blocks.removeAll(keepingCapacity: true)
        groups.removeAll(keepingCapacity: true)
        storedBytes = 0
    }
}
