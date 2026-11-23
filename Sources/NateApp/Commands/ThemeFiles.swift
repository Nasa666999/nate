import AppKit
import NateCore
import NateStorage
import NateSyntax

extension ApplicationController {
    /// 业务作用：主题文件在独立读通道取得完整原字节与词法资源，不影响当前正文的原文件队列。
    /// 参数说明:
    /// - url: 用户明确选择的本地主题文件。
    /// 返回：完整可应用定义与兼容说明；取消或文件变化时拒绝部分配色。
    func readTheme(at url: URL) async throws -> EditorThemeImportResult {
        let access = fileAccess
        let languages = Set(registry?.languages.map(\.id) ?? [])
        let name = Self.themeFileName(url)
        return try await themePreferences.io.readCancellable {
            token in
            let bytes = try access.readData(
                url,
                maximumBytes: 8 * 1024 * 1024,
                permit: {
                    !token.isCancelled
                }
            )
            return try EditorThemeImport.parse(
                bytes.data,
                name: name,
                languages: languages,
                permit: {
                    !token.isCancelled
                }
            )
        }
    }

    /// 业务作用：导出主题沿同一完整目标基线和单次发布权写入，不能成为工作区文件的第二个保存者。
    /// 参数说明:
    /// - definition: 用户明确确认的完整主题草稿。
    /// - url: 系统保存面板明确确认的独立目标。
    /// 返回：原文件和目录同步后完成；取消、别名占用或磁盘证据变化时拒绝覆盖。
    func exportTheme(_ definition: EditorThemeDefinition, to url: URL) async throws {
        let runtime = themePreferences
        let access = fileAccess, operations = fileOperations
        let token = CancellationToken()
        try await withTaskCancellationHandler {
            let prepared = try await runtime.io.run {
                try token.check()
                try FileStorage.validateFileURL(url)
                let data = try EditorThemeCodec.encode(
                    definition,
                    permit: {
                        !token.isCancelled
                    }
                )
                let baseline =
                    FileManager.default.fileExists(atPath: url.path)
                    ? try access.baseline(
                        url,
                        permit: {
                            !token.isCancelled
                        }
                    ) : nil
                let path = baseline?.resolvedPath ?? url.resolvingSymlinksInPath().standardizedFileURL.path
                try token.check()
                return (data, baseline, path)
            }
            guard !closing, !Task.isCancelled, !token.isCancelled else {
                throw CancellationError()
            }
            // 命名正文、待连接原文件及其硬链接都已有自己的保存权，独立主题导出不能跨过该边界。
            guard
                !documents.contains(where: {
                    document in
                    [document.url?.standardizedFileURL.path, document.pendingOriginalPath].contains(
                        prepared.2
                    )
                        || [document.baseline, document.pendingOriginalBaseline].compactMap {
                            $0
                        }.contains {
                            baseline in
                            baseline.resolvedPath == prepared.2
                                || prepared.1.map {
                                    $0.device == baseline.device && $0.inode == baseline.inode
                                } == true
                        }
                })
            else {
                throw NateError.message("主题导出目标由当前工作区文档持有，请选择独立文件。")
            }
            let owner = UUID()
            guard reserveTarget(prepared.2, owner: owner) else {
                throw NateError.message("主题导出目标仍有其它文件动作。")
            }
            defer {
                releaseTarget(prepared.2, owner: owner)
            }
            _ = try await runtime.io.run {
                try token.check()
                return try operations.save(
                    using: access,
                    prepared.0,
                    to: url,
                    expected: prepared.1,
                    replacing: true,
                    permit: {
                        !token.isCancelled
                    },
                    authority: token
                )
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// 业务作用：XML 文件名只作为可编辑主题名称，非法显示控制内容不进入主题元数据。
    /// 参数说明:
    /// - url: 用户明确选择的原本地文件。
    /// 返回：至多 256 UTF-8 字节的可见名称，不改变原路径或文件字节。
    nonisolated static func themeFileName(_ url: URL) -> String {
        var output = ""
        for scalar in url.deletingPathExtension().lastPathComponent.unicodeScalars {
            let value =
                [.control, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
                ? "_" : String(scalar)
            if output.utf8.count + value.utf8.count > 256 {
                break
            }
            output += value
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "导入主题" : output
    }
}
