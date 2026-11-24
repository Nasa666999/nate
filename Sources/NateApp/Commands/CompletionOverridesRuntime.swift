import Foundation
import NateSyntax

typealias CompletionOverridesRuntime = LanguageXMLOverrides<CompletionDefinition>

extension ApplicationController {
    /// 业务作用：启动时把每份补全词表作为独立的用户语言资源载入。
    /// 参数说明: 无。
    /// 返回：已确认定义参与后续候选，失败沿用随包资源。
    func loadCompletionOverrides() async {
        await loadLanguageXMLOverrides(completionOverrides)
    }

    /// 业务作用：显式重读一种语言的补全文件，旧候选在新规则生效时失去确认资格。
    /// 参数说明:
    /// - language: 操作固定的语言标识。
    /// 返回：完整重新载入后刷新候选权限，失败保留当前词表。
    func reloadCompletionOverride(language: String) async throws {
        _ = try await applyLanguageXMLOverride(completionOverrides, language: language, change: .reload)
        cancelCompletion()
    }

    /// 业务作用：明确保存合格的词表或恢复随包规则，磁盘基线和旧表单同时受复验。
    /// 参数说明:
    /// - xml: 用户选择的完整原文，空值表示恢复随包。
    /// - language: 表单固定的语言标识。
    /// - generation: 打开表单时确认的用户规则代次。
    /// 返回：成功持久化后撤销旧候选；读写、校验或来源失败时抛错。
    func saveCompletionOverride(_ xml: Data?, language: String, generation: UUID?) async throws {
        _ = try await applyLanguageXMLOverride(
            completionOverrides,
            language: language,
            change: .save(xml, expecting: generation)
        )
        cancelCompletion()
    }
}
