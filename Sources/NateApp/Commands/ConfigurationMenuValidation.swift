import AppKit

extension ApplicationController {
    /// 业务作用：配置、比较和导出入口依据真实任务及输入状态开放，取消入口只操作当前实际动作。
    /// 参数说明:
    /// - id: 原生菜单的稳定命令身份。
    /// 返回：已管理入口的实际可用性，其它命令交还已有菜单规则。
    func validateConfigurationAndComparisonMenu(_ id: String) -> Bool? {
        switch id {
        case "exportHTML", "exportRTF":
            return canPrepareDocumentExport
        case "importUserConfiguration":
            return canApplyUserConfiguration() && userConfiguration.task == nil
                && userConfiguration.preview == nil
        case "exportUserConfiguration":
            return !closing && userConfiguration.task == nil && userConfiguration.preview == nil
        case "cancelUserConfiguration":
            return userConfiguration.task != nil || userConfiguration.preview != nil
        case "compare":
            return !closing && active != nil && documentComparison.task == nil
                && mainWindow?.hasMarkedEditorInput == false
        case "cancelDocumentComparison":
            return documentComparison.task != nil
        default:
            return nil
        }
    }
}
