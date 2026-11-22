import Foundation
import NateCore

extension BatchScanner {
    /// 业务作用：Batch 百分号按参数、路径扩展、环境变量及局部变量的原生优先顺序取得类别。
    /// 参数说明: 无。
    /// 返回：已确认变量范围采用自身样式，未闭合或转义形式保持普通文字。
    mutating func percentVariable() throws {
        try colour(until: wordStart - 1, style: 0)
        let length = wordEnd - wordStart
        var end = 1
        while end < length && word(end) != 37 {
            try budget.consume()
            end += 1
        }
        if (Self.digit(word(1)) || word(1) == 42), word(end) != 37 {
            if command == wordStart {
                command = wordStart + 2
            }
            try colour(until: wordStart + 1, style: 6)
            offset = wordStart + 2
        }
        else if length > 1 && word(1) == 126
            || length > 2 && word(1) == 37 && word(2) == 126
        {
            if command == wordStart {
                command = wordStart + end
            }
            if word(1) == 126 {
                var stop = 2, valid = false
                while stop < length {
                    try budget.consume()
                    if Self.digit(word(stop)) {
                        stop += 1
                        valid = true
                        end = stop
                        try colour(until: wordStart + end - 1, style: 6)
                        break
                    }
                    stop += 1
                }
                if !valid {
                    try colour(until: wordStart + end - 1, style: 0)
                }
            }
            else {
                end = 3
                while end < length && !Self.punctuation(word(end)) && word(end) != 37 {
                    try budget.consume()
                    end += 1
                }
                try colour(until: wordStart + end - 1, style: end > 3 ? 6 : 0)
            }
            offset = wordStart + end
        }
        else if word(1) != 37, word(end) == 37 {
            end += 1
            if command == wordStart {
                command = wordStart + end
            }
            try colour(until: wordStart + end - 1, style: 6)
            offset = wordStart + end
        }
        else if length > 2, word(1) == 37, word(2) != 37, !Self.punctuation(word(2)) {
            if command == wordStart {
                command = wordStart + 3
            }
            try colour(until: wordStart + 2, style: 6)
            offset = wordStart + 3
        }
        else if length > 1, word(1) == 37 {
            try colour(until: wordStart + 1, style: 0)
            offset = wordStart + 2
        }
    }

    /// 业务作用：Batch 延迟环境变量只在当前完整词内存在第二个感叹号时授予变量类别。
    /// 参数说明: 无。
    /// 返回：完整变量范围及后继命令位置推进，缺少闭合时保留普通文字。
    mutating func delayedVariable() throws {
        try colour(until: wordStart - 1, style: 0)
        var end = 1
        while wordStart + end < wordEnd && word(end) != 33 {
            try budget.consume()
            end += 1
        }
        if wordStart + end < wordEnd {
            if command == wordStart {
                command = wordStart + end + 1
            }
            try colour(until: wordStart + end, style: 6)
            offset = wordStart + end + 1
        }
    }
}
