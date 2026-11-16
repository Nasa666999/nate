import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage

struct SessionFile: Codable, Sendable {
    var format = 1
    var documents: [SessionDocument]
}

struct SessionDocument: Codable, Sendable {
    var path: String
    var language: String
    var selections: [TextSelection]
    var readOnly: Bool
    var bookmarks: Set<Int>
}

extension ApplicationController {
    /// 业务作用：命名会话记录已命名文件及位置，临时文档继续由独立恢复存储保护。
    /// 参数说明: 无。
    /// 返回：安全写入可迁移的文件清单，不把临时正文藏入普通路径列表。
    func saveSession() async {
        guard await flushRecovery(), let url = SystemIntegration.chooseSave(name: "Workspace.natesession")
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
                bookmarks: document.buffer.bookmarks
            )
        }
        do {
            try await fileIO.run {
                let data = try JSONEncoder().encode(SessionFile(documents: entries))
                let expected =
                    FileManager.default.fileExists(atPath: url.path) ? try FileStorage.baseline(url) : nil
                _ = try FileStorage.save(data, to: url, expected: expected)
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
        do {
            let session = try await fileIO.run {
                let data = try Data(contentsOf: url)
                guard data.count <= 8_388_608 else {
                    throw NateError.message("会话清单超过 8 MB。")
                }
                let session = try JSONDecoder().decode(SessionFile.self, from: data)
                guard session.format == 1, session.documents.count <= 10_000 else {
                    throw NateError.message("会话格式或文档数量不受支持。")
                }
                return session
            }
            var skipped: [String] = []
            for entry in session.documents {
                guard entry.path.hasPrefix("/"), !entry.path.hasPrefix("//"), !entry.path.contains("://"),
                    FileManager.default.fileExists(atPath: entry.path)
                else {
                    skipped.append(entry.path)
                    continue
                }
                await openFile(URL(fileURLWithPath: entry.path))
                guard
                    let document = documents.first(where: {
                        $0.url?.path == entry.path
                    })
                else {
                    skipped.append(entry.path)
                    continue
                }
                document.language = entry.language
                document.languageExplicit = true
                document.buffer.selections = entry.selections.filter {
                    document.buffer.text.isBoundary($0.anchor) && document.buffer.text.isBoundary($0.head)
                }
                if document.buffer.selections.isEmpty {
                    document.buffer.selections = [TextSelection(anchor: 0, head: 0)]
                }
                document.buffer.isReadOnly = entry.readOnly
                document.buffer.bookmarks = entry.bookmarks
            }
            if !skipped.isEmpty {
                mainWindow?.showResults("会话部分载入，以下路径未打开：\n" + skipped.joined(separator: "\n"))
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

    /// 业务作用：读取有界真实目录清单，包、隐藏目录和符号链接不递归展开。
    /// 参数说明:
    /// - url: 用户明确选择的根目录。
    /// 返回：可导航的文件列表，不改变项目虚拟分组或文档正文。
    func showFolder(_ url: URL) async {
        do {
            let files = try await fileIO.run {
                try DirectoryTraversal.files(under: url, limit: 20_000)
            }
            resultNavigation = files.map {
                ResultNavigation(documentID: nil, revision: nil, url: $0, range: ByteRange(0, 0))
            }
            mainWindow?.showResults(files.map(\.path).joined(separator: "\n"), navigable: true)
        }
        catch {
            SystemIntegration.alert("目录工作区", error.localizedDescription)
        }
    }
}
