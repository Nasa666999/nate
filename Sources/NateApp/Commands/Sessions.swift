import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController {
    /// 业务作用：命名会话记录已命名文件及位置，临时文档继续由独立恢复存储保护。
    /// 参数说明: 无。
    /// 返回：安全写入可迁移的文件清单，不把临时正文藏入普通路径列表。
    func saveSession() async {
        guard mainWindow?.finishCompositions() != false, await flushRecovery(),
            let url = SystemIntegration.chooseSave(name: "Workspace.natesession")
        else {
            return
        }
        let entries = documents.compactMap {
            document -> SessionDocument? in
            guard let path = document.url?.path else {
                return nil
            }
            return SessionDocument(
                path: path,
                language: document.language,
                selections: document.buffer.selections,
                readOnly: document.buffer.isReadOnly,
                bookmarks: document.buffer.bookmarks,
                selectionState: document.buffer.selectionState
            )
        }
        do {
            try await fileIO.run {
                guard
                    entries.allSatisfy({
                        $0.selectionState != nil
                    })
                else {
                    throw NateError.message("当前文档缺少完整选择身份，请重新选择正文后再保存会话。")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(SessionFile(documents: entries))
                guard data.count <= 8_388_608 else {
                    throw NateError.message("会话元数据超过 8 MiB，原文件保留。")
                }
                let expected =
                    FileManager.default.fileExists(atPath: url.path) ? try self.fileAccess.baseline(url) : nil
                _ = try self.fileOperations.save(
                    using: self.fileAccess,
                    data,
                    to: url,
                    expected: expected,
                    replacing: true
                )
            }
            SystemIntegration.alert(
                "会话已保存",
                "\(entries.count) 个已命名文件。\(documents.count - entries.count) 个临时文档保留在 Nate 恢复目录，不包含在此会话清单中。"
            )
        }
        catch {
            SystemIntegration.alert("会话保存失败", error.localizedDescription)
        }
    }

    /// 业务作用：导入会话先校验格式与路径，远程位置未经选择不主动连接。
    /// 参数说明:
    /// - url: 用户选择的会话文件。
    /// 返回：逐项打开有效文件，部分失败按实际清单显示。
    func loadSession(_ url: URL) async {
        // 候选仍持有原输入目标，必须成功确认后才能由会话改变选择与编辑权限。
        guard mainWindow?.finishCompositions() != false else {
            return
        }
        do {
            let session = try await readIO.readCancellable {
                token in
                let data = try self.fileAccess.readData(
                    url,
                    maximumBytes: 8_388_608,
                    permit: {
                        !token.isCancelled
                    }
                ).data
                let session = try JSONDecoder().decode(SessionFile.self, from: data)
                guard (session.format == 1 || session.format == 2), session.documents.count <= 10_000 else {
                    throw NateError.message("会话格式或文档数量不受支持。")
                }
                return session
            }
            // 会话读取期间退出可能已经接管工作区，旧载入不得再改变已冻结的视图与权限。
            guard !closing else {
                return
            }
            var skipped: [String] = []
            var selectionFailures: [String] = []
            for entry in session.documents {
                guard entry.path.hasPrefix("/"), !entry.path.hasPrefix("//"), !entry.path.contains("://"),
                    FileManager.default.fileExists(atPath: entry.path)
                else {
                    skipped.append(entry.path)
                    continue
                }
                await openFile(URL(fileURLWithPath: entry.path))
                // 文件等待返回后重新检查退出权威，不能把迟到会话设置发布到已经冻结的工作区。
                guard !closing else {
                    return
                }
                guard
                    let document = documents.first(where: {
                        $0.url?.path == entry.path
                    })
                else {
                    skipped.append(entry.path)
                    continue
                }
                guard mainWindow?.finishCompositions() != false else {
                    return
                }
                document.language = entry.language
                document.languageExplicit = true
                if let state = entry.selectionState {
                    do {
                        try document.buffer.setSelectionState(state)
                    }
                    catch {
                        // 路径正文可能在会话保存后改变，保留已打开内容和当前合法光标，不丢弃部分稳定身份。
                        selectionFailures.append(entry.path + "：" + error.localizedDescription)
                    }
                }
                else {
                    try document.restoreSelections(nil, legacySelections: entry.selections)
                }
                document.buffer.isReadOnly = entry.readOnly
                document.buffer.bookmarks = entry.bookmarks
            }
            if !skipped.isEmpty || !selectionFailures.isEmpty {
                let paths = skipped.isEmpty ? "" : "以下路径未打开：\n" + skipped.joined(separator: "\n")
                let selections =
                    selectionFailures.isEmpty
                    ? "" : "以下完整选择与当前正文不符，保留当前光标：\n" + selectionFailures.joined(separator: "\n")
                mainWindow?.showResults(
                    "会话部分载入\n"
                        + [paths, selections].filter {
                            !$0.isEmpty
                        }.joined(separator: "\n")
                )
            }
            mainWindow?.editor.refresh(reveal: true)
            refreshUI()
        }
        catch {
            SystemIntegration.alert("会话载入失败", error.localizedDescription)
        }
    }

    /// 业务作用：用户主动选择真实目录工作区，不假定任意当前目录。
    /// 参数说明: 无。
    /// 返回：目录内容通过独立列表展示。
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await showFolder(url)
            }
        }
    }

    /// 业务作用：真实目录进入独立树侧栏，按需展开并观察变化，不覆盖搜索结果或改动虚拟项目。
    /// 参数说明:
    /// - url: 用户明确选择的根目录。
    /// 返回：新根取得目录树展示权，非法 URL 保留原树；文件仅在用户激活时进入统一打开流程。
    func showFolder(_ url: URL) async {
        do {
            // 退出已固定工作区，不能再建立会打开文件或改变焦点的新目录入口。
            guard !closing, let mainWindow else {
                return
            }
            if directoryWorkspace?.window !== mainWindow {
                directoryWorkspace?.stop()
                directoryWorkspace = DirectoryWorkspaceController(application: self, window: mainWindow)
            }
            try directoryWorkspace?.start(url)
        }
        catch {
            SystemIntegration.alert("目录工作区", error.localizedDescription)
        }
    }
}
