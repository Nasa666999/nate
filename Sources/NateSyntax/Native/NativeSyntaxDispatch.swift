import Foundation
import NateCore

extension SyntaxScanner {
    /// 业务作用：独立词法器按固定语言与同源状态分派，旧原生状态失去语言资格时拒绝继续解释。
    /// 参数说明:
    /// - text: 当前完整行或已确认的连续显示片段。
    /// - base: 当前片段在固定原文中的字节起点。
    /// - state: 本次调用流程独立持有的完整连续状态。
    /// 返回：适用词法器的完整结果，拒绝时返回空数组及诊断；其它语言返回空值交由通用入口处理。
    func nativeHighlight(_ text: String, base: Int, state: inout SyntaxState) -> [SyntaxToken]? {
        // AutoIt 的块注释、include 与续行字面只属于同一完整规则，语言切换必须重建原文资格。
        guard state.autoit.resource == nil || language.id == "autoit" else {
            state.diagnostic = "词法语言已改变，不能继续 AutoIt 的原状态。"
            return []
        }
        if language.id == "autoit" {
            return AutoItLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: autoitRules,
                deadline: deadline,
                state: &state
            )
        }
        // OID 与跨行字符串只属于同一 ASN.1 规则，语言切换必须重建连续原文资格。
        guard state.asn1.resource == nil || language.id == "asn1" else {
            state.diagnostic = "词法语言已改变，不能继续 ASN.1 的原状态。"
            return []
        }
        if language.id == "asn1" {
            return ASN1Lexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: asn1Rules,
                deadline: deadline,
                state: &state
            )
        }
        // Ada 属性撇号和原生字面绑定同一规则，切换语言不得继承旧原文状态。
        guard state.ada.resource == nil || language.id == "ada" else {
            state.diagnostic = "词法语言已改变，不能继续 Ada 的原状态。"
            return []
        }
        if language.id == "ada" {
            return AdaLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: adaRules,
                deadline: deadline,
                state: &state
            )
        }
        // 固定列、续行及字面资格绑定格式和来源，另一语言不能继续使用此前的原文状态。
        guard state.fortran.resource == nil || ["fortran", "fortran77"].contains(language.id) else {
            state.diagnostic = "词法语言已改变，不能继续 Fortran 的原状态。"
            return []
        }
        if ["fortran", "fortran77"].contains(language.id) {
            return FortranLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: fortranRules,
                deadline: deadline,
                state: &state
            )
        }
        // 汇编指令、引号及续行资格属于同一完整规则，语言切换必须撤销旧状态。
        guard state.asm.resource == nil || language.id == "asm" else {
            state.diagnostic = "词法语言已改变，不能继续汇编的原状态。"
            return []
        }
        if language.id == "asm" {
            return ASMLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: asmRules,
                deadline: deadline,
                state: &state
            )
        }
        // nnCron 环境变量及字面资格属于同一完整规则，语言切换不能延续此前的原文状态。
        guard state.nncrontab.resource == nil || language.id == "nncrontab" else {
            state.diagnostic = "词法语言已改变，不能继续 nnCron 的原状态。"
            return []
        }
        if language.id == "nncrontab" {
            return NncronLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: nncrontabRules,
                deadline: deadline,
                state: &state
            )
        }
        // Pascal 声明、汇编及多行字面属于同一完整规则，语言变化必须撤销旧状态资格。
        guard state.pascal.resource == nil || language.id == "pascal" else {
            state.diagnostic = "词法语言已改变，不能继续 Pascal 的原状态。"
            return []
        }
        if language.id == "pascal" {
            return PascalLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: pascalRules,
                deadline: deadline,
                state: &state
            )
        }
        // CMake 引号及变量资格属于同一完整规则，语言变化必须重建连续证据。
        guard state.cmake.resource == nil || language.id == "cmake" else {
            state.diagnostic = "词法语言已改变，不能继续 CMake 的原状态。"
            return []
        }
        if language.id == "cmake" {
            return CMakeLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: cmakeRules,
                deadline: deadline,
                state: &state
            )
        }
        // TOML 后继键名与行元数据属于同一规则，语言变化必须重建连续证据。
        guard state.toml.resource == nil || language.id == "toml" else {
            state.diagnostic = "词法语言已改变，不能继续 TOML 的原状态。"
            return []
        }
        if language.id == "toml" {
            return TOMLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: tomlRules,
                deadline: deadline,
                state: &state
            )
        }
        // Batch 文本命令资格属于完整物理行，语言变化必须重建连续证据。
        guard state.batch.resource == nil || language.id == "batch" else {
            state.diagnostic = "词法语言已改变，不能继续 Batch 的原状态。"
            return []
        }
        if language.id == "batch" {
            return BatchLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: batchRules,
                deadline: deadline,
                state: &state
            )
        }
        // CSS 未决段可以影响此前物理行，语言切换必须重建该语言自己的连续证据。
        guard state.css.resource == nil || language.id == "css" else {
            state.diagnostic = "词法语言已改变，不能继续 CSS 的原状态。"
            return []
        }
        if language.id == "css" {
            return CSSLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: cssRules,
                deadline: deadline,
                state: &state
            )
        }
        // SQL 的引号和物理分类缓存属于自己的规则，切换语言必须显式重建连续状态。
        guard state.sql.resource == nil || language.id == "sql" else {
            state.diagnostic = "词法语言已改变，不能继续 SQL 的原状态。"
            return []
        }
        if language.id == "sql" {
            return SQLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: sqlRules,
                deadline: deadline,
                state: &state
            )
        }
        // T-SQL 前向证据属于自己的语言规则，切换语言必须从中性状态开始，不能继续旧缓存。
        guard state.mssql.resource == nil || language.id == "mssql" else {
            state.diagnostic = "词法语言已改变，不能继续 T-SQL 的原状态。"
            return []
        }
        if language.id == "mssql" {
            return MSSQLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: mssqlRules,
                deadline: deadline,
                state: &state
            )
        }
        if ["javascript.js", "typescript"].contains(language.id) {
            return ScriptLexing.highlight(
                text,
                base: base,
                language: language.id,
                snapshot: snapshot,
                rules: scriptRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "lua" {
            return LuaLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: luaRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "r" {
            return RLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: rRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "objc" {
            return ObjCLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: objcRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "powershell" {
            return PowerShellLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: powershellRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "yaml" {
            return YAMLLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                rules: yamlRules,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "rust" {
            return RustLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                language: language,
                resource: rustResource,
                deadline: deadline,
                state: &state
            )
        }
        if ["lisp", "scheme"].contains(language.id) {
            return LispLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                language: language.id,
                styles: language.lexicalStyles,
                keywords: keywords,
                secondary: secondaryKeywords,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "latex" {
            return LatexLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.lexicalStyles,
                deadline: deadline,
                state: &state
            )
        }
        if language.id == "registry" {
            return RegistryLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.lexicalStyles,
                deadline: deadline,
                state: &state
            )
        }
        if ["ini", "props", "diff", "makefile", "ihex", "srec", "tehex", "tex"].contains(language.id) {
            let mode: LineLexicalMode =
                language.id == "makefile"
                ? .makefile : (LineLexicalMode(rawValue: language.id) ?? .properties)
            return PropertyLexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.lexicalStyles,
                mode: mode,
                directives: language.id == "makefile" ? language.keywords : [],
                deadline: deadline,
                state: &state
            )
        }
        if ["escseq", "errorlist"].contains(language.id) {
            return ANSILexing.highlight(
                text,
                base: base,
                snapshot: snapshot,
                styles: language.terminalStyles,
                errorList: language.id == "errorlist",
                deadline: deadline,
                state: &state
            )
        }
        return nil
    }
}
