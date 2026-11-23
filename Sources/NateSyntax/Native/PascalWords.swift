import Foundation
import NateCore

extension PascalScanner {
    /// 业务作用：Pascal 关键字结合属性、导出及汇编上下文分类，只有原词表存在的声明词才能改变后继资格。
    /// 参数说明: 无。
    /// 返回：完整名称取得原生类别并收束；原生截取限于九十九字节，名称和正文范围仍完整保留。
    mutating func classifyWord() throws {
        guard emitted >= 0, emitted <= min(cursor, bytes.count) else {
            throw NateError.invalidRange
        }
        let end = min(cursor, min(bytes.count, emitted + 99))
        let word = Data(bytes[emitted..<end].map(PascalCharacters.folded))
        if try rules.contains(word, budget: &budget) {
            if state.inAssembler {
                if word == Data("end".utf8), try byte(at: cursor - 4) != 64 {
                    state.inAssembler = false
                    state.mode = 9
                }
                else {
                    state.mode = 14
                }
            }
            else {
                var ignored = false
                if word == Data("asm".utf8) {
                    state.inAssembler = true
                }
                else if word == Data("property".utf8) {
                    state.inProperty = true
                }
                else if word == Data("exports".utf8) {
                    state.inExports = true
                }
                else if word == Data("index".utf8), !state.inProperty, !state.inExports {
                    ignored = true
                }
                else if word == Data("name".utf8), !state.inExports {
                    ignored = true
                }
                else if !state.inProperty,
                    [
                        "read", "write", "default", "nodefault", "stored", "implements", "readonly",
                        "writeonly", "add", "remove",
                    ].contains(
                        String(decoding: word, as: UTF8.self)
                    )
                {
                    ignored = true
                }
                if !ignored {
                    state.mode = 9
                }
            }
        }
        else if state.inAssembler {
            state.mode = 14
        }
        try setState(0)
    }
}
