import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：非 UTF-8 字节保留在独立分页窗口，不用替换字符或十六进制显示改写正文。
    /// 参数说明:
    /// - data: 完整解码结果。
    /// - name: 当前明确工具标识。
    /// 返回：替换先前字节结果窗口；完整原字节仅由当前结果与已明确发起的导出持有。
    func showTextToolBytes(_ data: Data, name: String) {
        textTools.bytesPanel?.close()
        let panel = ByteResultPanel(
            data: data,
            name: name
        )
        panel.onExport = {
            [weak self, weak panel] in
            guard let self, let panel else {
                return
            }
            self.exportTextToolBytes(panel)
        }
        panel.onClose = {
            [weak self, weak panel] in
            if self?.textTools.bytesPanel === panel {
                self?.textTools.bytesPanel = nil
            }
        }
        textTools.bytesPanel = panel
        panel.setExporting(textTools.exportTask != nil)
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    /// 业务作用：导出全部原字节使用统一文件发布通道，不能绕开活动文档或并行写入者覆盖原文件。
    /// 参数说明:
    /// - panel: 用户明确点击导出的固定结果窗口。
    /// 返回：目标基线和独占路径成立后原子保存；取消、活动文档冲突或基线变化不写文件。
    func exportTextToolBytes(_ panel: ByteResultPanel) {
        guard !closing, textTools.exportTask == nil,
            let url = SystemIntegration.chooseSave(name: "decoded-bytes.bin")
        else {
            return
        }
        saveTextToolBytes(panel, to: url)
    }

    /// 业务作用：为已明确选择的字节导出目标取得独占发布权，完整结果与分页显示无关。
    /// 参数说明:
    /// - panel: 持有完整原字节的结果窗口。
    /// - url: 用户已经明确确认的独立输出文件。
    /// 返回：统一通道原子保存全部字节；失效、活动文档或并行目标冲突失败。
    func saveTextToolBytes(_ panel: ByteResultPanel, to url: URL) {
        guard !closing, textTools.exportTask == nil else {
            return
        }
        let data = panel.data, runtime = textTools
        panel.setExporting(true)
        runtime.exportTask = Task {
            defer {
                runtime.exportTask = nil
                runtime.bytesPanel?.setExporting(false)
                panel.setExporting(false)
            }
            do {
                let target = try await fileIO.run {
                    try FileStorage.validateFileURL(url)
                    let baseline =
                        FileManager.default.fileExists(atPath: url.path)
                        ? try self.fileAccess.baseline(url) : nil
                    return (
                        baseline,
                        baseline?.resolvedPath ?? url.resolvingSymlinksInPath().standardizedFileURL.path
                    )
                }
                // 活动文档持有自动保存权，字节导出不能成为同一真实文件的第二个写入者。
                guard !closing,
                    !documents.contains(where: {
                        $0.url?.resolvingSymlinksInPath().standardizedFileURL.path == target.1
                            || $0.baseline.map {
                                baseline in
                                baseline.resolvedPath == target.1
                                    || target.0.map {
                                        $0.device == baseline.device && $0.inode == baseline.inode
                                    } == true
                            } == true
                    })
                else {
                    throw NateError.message("导出目标由当前工作区文档持有，请选择独立文件。")
                }
                let owner = UUID()
                guard reserveTarget(target.1, owner: owner) else {
                    throw NateError.message("导出目标仍有其它写入任务。")
                }
                defer {
                    releaseTarget(target.1, owner: owner)
                }
                try await fileIO.run {
                    _ = try self.fileOperations.save(
                        using: self.fileAccess,
                        data,
                        to: url,
                        expected: target.0,
                        replacing: true
                    )
                }
            }
            catch {
                SystemIntegration.alert("字节导出未完成", error.localizedDescription)
            }
        }
    }
}
