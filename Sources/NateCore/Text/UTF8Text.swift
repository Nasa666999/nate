import Foundation

public enum UTF8Text {
    /// 业务作用：已确定为 UTF-8 的正文字段按原字节解释，开头的 U+FEFF 与中间字符具有同等正文身份。
    /// 参数说明:
    /// - data: 由所属入口限定容量的完整原文字节，文件编码标记须由文件入口单独处理。
    /// 返回：回编码与输入逐字节一致的完整文本；非法序列返回空值，不替换字符或删除前导标量。
    public static func decode(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        // 回编码证据同时覆盖替代字符、NUL 和前导 U+FEFF，不能把宽松解码结果作为原文发布。
        guard text.utf8.elementsEqual(data) else {
            return nil
        }
        return text
    }
}
