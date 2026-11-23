import Foundation

enum FortranFoldWords {
    /// 业务作用：只有词法器已授予主要关键字身份的名称才影响折叠，资源中未启用的语言名称不被擅自补入。
    /// 参数说明:
    /// - word: 当前已确认的至多三十一个 ASCII 小写原字节名称。
    /// - previous: 当前物理行内此前主要关键字的原生截取名称。
    /// - following: 当前名称之后首个非行内空白原字节。
    /// 返回：原生开闭结构的层级变化；无法识别的名称不改变层级。
    static func delta(_ word: String, previous: String, following: UInt8) -> Int {
        if previous == "module", ["subroutine", "function"].contains(word) {
            return 0
        }
        if [
            "associate", "block", "blockdata", "select", "selecttype", "selectcase", "do", "enum",
            "function", "interface", "module", "program", "subroutine", "then", "enumeration", "critical",
            "submodule",
        ].contains(word) || word == "type" && following != 40 && previous != "enumeration" {
            return previous == "end" ? 0 : 1
        }
        if word == "end" && following != 61 && following != 40
            || [
                "endassociate", "endblock", "endblockdata", "endselect", "enddo", "endenum", "endif",
                "endforall",
                "endfunction", "endinterface", "endmodule", "endprogram", "endsubroutine", "endtype",
                "endwhere",
                "endcritical", "endsubmodule", "endteam",
            ].contains(word) || previous == "module" && word == "procedure"
        {
            return -1
        }
        if previous == "end", word == "if" {
            return 0
        }
        if previous == "type", word == "is" {
            return -1
        }
        if previous == "end" && word == "procedure" || word == "endprocedure" {
            return 1
        }
        if previous == "change", word == "team" {
            return 1
        }
        return 0
    }
}
