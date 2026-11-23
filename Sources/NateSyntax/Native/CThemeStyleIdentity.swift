import Foundation

enum CThemeStyleIdentity {
    /// 业务作用：共享 C 语义范围同时保留原生主题类别，行注释与块注释可以采用各自样式。
    /// 参数说明:
    /// - style: 当前完整语义词法身份。
    /// - state: 当前范围的注释及引号上下文。
    /// 返回：已经具备对应范围的原生数字类别；未知身份不猜测编号。
    static func nativeID(_ style: String, state: CLexicalState) -> UInt8? {
        switch style {
        case "text", "continuation":
            return 0
        case "comment":
            return state.lineComment ? 2 : 1
        case "documentation":
            return state.lineComment ? 15 : 3
        case "number":
            return 4
        case "keyword":
            return 5
        case "string":
            return 6
        case "character":
            return 7
        case "preprocessor", "header":
            return 9
        case "punctuation":
            return 10
        case "identifier":
            return 11
        case "invalid":
            return 12
        case "verbatim":
            return 13
        case "regex":
            return 14
        case "type":
            return 16
        case "documentationKeyword":
            return 17
        case "documentationInvalid":
            return 18
        case "globalClass":
            return 19
        case "raw":
            return 20
        case "userLiteral":
            return 25
        case "escape":
            return 27
        default:
            return nil
        }
    }
}
