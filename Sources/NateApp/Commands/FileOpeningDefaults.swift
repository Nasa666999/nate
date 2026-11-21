import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：最近文件读取和记录共用用户数量上限，停用时不消费或追加历史。
    /// 参数说明: 无。
    /// 返回：有界完整路径；原历史损坏时保留原归档并显示原因，明确清空仍可建立空历史。
    var recentFiles: [String] {
        get {
            let limit = currentFileOpeningSettings().recentFileLimit
            guard limit > 0 else {
                return []
            }
            do {
                let paths = try recentFileEntries()
                fileOpeningPreferences.recentWarning = nil
                return Array(paths.prefix(limit))
            }
            catch {
                fileOpeningPreferences.recentWarning = "最近文件历史未读取，原数据保留：" + error.localizedDescription
                return []
            }
        }
        set {
            let domain = fileOpeningPreferences.defaults ?? .standard
            if newValue.isEmpty {
                domain.set([String](), forKey: "recentFiles")
                fileOpeningPreferences.recentWarning = nil
                return
            }
            let limit = currentFileOpeningSettings().recentFileLimit
            guard limit > 0 else {
                return
            }
            do {
                // 新文件记录不能顺带抹掉无法完整读取的旧历史，明确清空才允许重建。
                _ = try recentFileEntries()
                var seen: Set<Data> = []
                var paths: [String] = []
                for path in newValue.prefix(200) {
                    guard Self.validRecentPath(path) else {
                        throw NateError.message("最近文件路径不是 8 KiB 以内的完整绝对路径。")
                    }
                    if seen.insert(Data(path.utf8)).inserted {
                        paths.append(path)
                    }
                    if paths.count == limit {
                        break
                    }
                }
                domain.set(paths, forKey: "recentFiles")
                fileOpeningPreferences.recentWarning = nil
            }
            catch {
                fileOpeningPreferences.recentWarning = "最近文件历史未保存，原数据保留：" + error.localizedDescription
            }
        }
    }

    /// 业务作用：在文件对话框实际打开时才解析目录来源，不探测路径或主动连接外部卷。
    /// 参数说明: 无。
    /// 返回：自定义、当前文件或上次选择的目录；缺少当前文件时退回上次目录，未记录则交由 macOS 决定。
    func fileDialogDirectory() -> URL? {
        let settings = currentFileOpeningSettings()
        if settings.directoryMode == .custom {
            return URL(fileURLWithPath: settings.customDirectory, isDirectory: true)
        }
        if settings.directoryMode == .currentDocument, let url = active?.url {
            return url.deletingLastPathComponent()
        }
        let domain = fileOpeningPreferences.defaults ?? .standard
        guard let path = domain.string(forKey: "lastFileDialogDirectory"), Self.validRecentPath(path) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 业务作用：只记录用户在打开或另存为对话框中明确选定的文件父目录，取消不生成记录。
    /// 参数说明:
    /// - url: 用户确认的本地文件目标。
    /// 返回：合法父目录写入独立偏好，不访问目录、不修改默认来源模式。
    func rememberSelectedFileDirectory(_ url: URL) {
        guard !closing, url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            return
        }
        let path = url.deletingLastPathComponent().path
        guard Self.validRecentPath(path) else {
            return
        }
        (fileOpeningPreferences.defaults ?? .standard).set(path, forKey: "lastFileDialogDirectory")
    }

    /// 业务作用：新建文档应用未来文档偏好，不在用户尚未选择路径时创建文件或改写既有格式。
    /// 参数说明: 无。
    /// 返回：UTF-8 无 BOM 的新文档进入工作区和恢复保护，缺席默认语言暂用纯文本并保留配置。
    @discardableResult
    func newDocument() -> WorkspaceDocument {
        let settings = currentFileOpeningSettings()
        let document = WorkspaceDocument(name: "新文档 \(documents.count + 1)", lineEnding: settings.lineEnding)
        if let language = registry?.languages.first(where: {
            $0.id.utf8.elementsEqual(settings.defaultLanguage.utf8)
        }), language.id != "searchResult" {
            document.language = language.id
        }
        else if settings.defaultLanguage != "normal" {
            document.state = "临时文档 · 默认语言未载入，暂用纯文本"
        }
        if closing {
            // 退出收束期间新标签同样不能重新开放正文输入。
            document.setEditingSuspension(.applicationTermination, active: true)
        }
        if !recoveryReady {
            document.recoveryError = "恢复索引尚未完成校验，现有记录保持原状。"
        }
        documents.append(document)
        activate(document.buffer.id)
        return document
    }

    /// 业务作用：历史必须完整读取才能继续更新，错误类型、过量条目或非法路径不能被部分历史替代。
    /// 参数说明: 无。
    /// 返回：完整路径列表，缺失为首次空历史；损坏时整体抛错且不写入。
    private func recentFileEntries() throws -> [String] {
        let domain = fileOpeningPreferences.defaults ?? .standard
        guard let object = domain.object(forKey: "recentFiles") else {
            return []
        }
        guard let array = object as? NSArray, array.count <= 200, let paths = array as? [String],
            paths.allSatisfy(Self.validRecentPath)
        else {
            throw NateError.message("历史须为至多 200 条完整本地绝对路径。")
        }
        return paths
    }

    /// 业务作用：文件入口偏好只持有有界绝对路径，NUL 不能让显示路径与系统访问目标分离。
    /// 参数说明:
    /// - path: 未进行文件系统探测的原路径。
    /// 返回：8 KiB 以内、不含 NUL 的绝对路径为真。
    private static func validRecentPath(_ path: String) -> Bool {
        path.utf8.first == 47 && path.utf8.count <= 8192 && !path.utf8.contains(0)
    }
}
