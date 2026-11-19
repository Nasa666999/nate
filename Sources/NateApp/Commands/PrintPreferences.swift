import AppKit
import NateCore
import NatePlatform
import NateUI

private struct PrintPreferencesArchive: Codable {
    let format: Int
    let settings: PrintSettings
}

@MainActor
final class PrintRuntime {
    var defaults: UserDefaults?
    var loaded = false
    var settings: PrintSettings?
    var warning: String?
    var busy = false
    var generation = UUID()
    var sourceDomain: UserDefaults?
    var sourceObject: NSObject?

    /// 业务作用：打印配置独立于正文和系统纸张状态，损坏归档不参与编辑器启动门禁。
    /// 参数说明: 无。
    /// 返回：尚未读取实际偏好且没有打印作业的运行状态。
    init() {}
}

extension ApplicationController {
    /// 业务作用：打印配置按需完整读取，未知或损坏内容保留原字节并使用安全默认值。
    /// 参数说明: 无。
    /// 返回：当前完整合法配置；未能验证的归档不会被自动重写。
    func currentPrintSettings() throws -> PrintSettings {
        let runtime = printing
        let domain = runtime.defaults ?? .standard
        let object = domain.object(forKey: "printSettings") as? NSObject
        let same =
            runtime.loaded && runtime.sourceDomain === domain
            && (runtime.sourceObject.map({ $0.isEqual(object) }) ?? (object == nil))
        if !same {
            runtime.settings = try PrintSettings()
            runtime.loaded = true
            runtime.warning = nil
            runtime.sourceDomain = domain
            runtime.sourceObject = object
            runtime.generation = UUID()
            if let raw = object {
                do {
                    guard let data = raw as? Data, data.count <= 65_536 else {
                        throw NateError.message("打印配置不是受限完整归档。")
                    }
                    let archive = try JSONDecoder().decode(PrintPreferencesArchive.self, from: data)
                    guard archive.format == 1 else {
                        throw NateError.message("打印配置格式尚不受支持。")
                    }
                    runtime.settings = archive.settings
                }
                catch {
                    runtime.warning =
                        "打印设置未被读取，原归档保留。本次采用默认配置；明确应用设置后才重新保存。"
                        + error.localizedDescription
                }
            }
        }
        guard let settings = runtime.settings else {
            throw NateError.message("打印配置尚未完整建立。")
        }
        return settings
    }

    /// 业务作用：只有明确应用的完整配置替换偏好，取消表单不能覆盖损坏或未知的原归档。
    /// 参数说明:
    /// - settings: 已通过全部数值、模板及字体检查的完整配置。
    /// 返回：完整编码后一次写入偏好域，当前打印使用新配置；编码或容量失败保留原值。
    func savePrintSettings(_ settings: PrintSettings) throws {
        let data = try JSONEncoder().encode(
            PrintPreferencesArchive(
                format: 1,
                settings: settings
            )
        )
        guard data.count <= 65_536 else {
            throw NateError.message("打印配置归档超过 64 KiB。")
        }
        let domain = printing.defaults ?? .standard
        domain.set(data, forKey: "printSettings")
        printing.sourceDomain = domain
        printing.sourceObject = domain.object(forKey: "printSettings") as? NSObject
        printing.settings = settings
        printing.loaded = true
        printing.warning = nil
        printing.generation = UUID()
    }

    /// 业务作用：通过原生表单改变独立打印参数，不确认候选或修改正文格式。
    /// 参数说明: 无。
    /// 返回：完整确认后保存配置；候选、打印占用、取消或非法输入保持当前状态。
    func showPrintSettings() {
        guard !closing, !printing.busy, mainWindow?.hasMarkedEditorInput != true else {
            return
        }
        do {
            let initial = try currentPrintSettings()
            let generation = printing.generation
            let domain = printing.defaults ?? .standard
            let original = domain.object(forKey: "printSettings") as? NSObject
            guard let value = PrintSettingsDialog.choose(initial: initial, warning: printing.warning),
                !closing
            else {
                return
            }
            let current = domain.object(forKey: "printSettings") as? NSObject
            // 表单只属于打开时的配置代次，另一个设置入口或偏好域变化后不能覆盖后来值。
            guard printing.generation == generation, (printing.defaults ?? .standard) === domain,
                original.map({
                    $0.isEqual(current)
                }) ?? (current == nil)
            else {
                if printing.generation == generation {
                    printing.loaded = false
                }
                throw NateError.message("等待期间实际打印设置已改变，请重新打开表单。")
            }
            try savePrintSettings(value)
            mainWindow?.status.stringValue = "打印设置已应用，正文与系统纸张选择保持原状。"
        }
        catch {
            SystemIntegration.alert("打印设置未应用", error.localizedDescription)
        }
    }

    /// 业务作用：系统纸张与方向设置不取得候选或正文的修改权。
    /// 参数说明: 无。
    /// 返回：来源有效且没有打印占用时打开原生页面设置，其余保持当前输入。
    func showPageSetup() {
        guard !closing, !printing.busy, active != nil, mainWindow?.hasMarkedEditorInput == false else {
            return
        }
        NSPageLayout().runModal()
    }
}
