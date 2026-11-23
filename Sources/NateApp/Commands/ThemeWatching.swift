import Foundation
import NateCore
import NateStorage
import NateSyntax

extension ApplicationController {
    /// 业务作用：只有完整已知偏好中的明确本地来源才能启动热更新，旧窗口或旧域立即失去发布权。
    /// 参数说明: 无。
    /// 返回：独立后台监视建立；取消或没有授权来源时不读取外部文件。
    func restartThemeWatching() {
        let runtime = themePreferences
        runtime.watchGeneration = UUID()
        runtime.watchTask?.cancel()
        runtime.watchTask = nil
        let entries =
            runtime.sourceValid
            ? runtime.library?.entries.filter {
                $0.watchesSource && $0.sourcePath != nil
            } ?? [] : []
        let paths = Dictionary(
            uniqueKeysWithValues: entries.compactMap {
                entry in
                entry.sourcePath.map {
                    (entry.id, $0)
                }
            }
        )
        let retained = Set(
            paths.keys.filter {
                runtime.watchedPaths[$0] == paths[$0]
            }
        )
        runtime.observed = runtime.observed.filter {
            retained.contains($0.key)
        }
        runtime.verifiedAt = runtime.verifiedAt.filter {
            retained.contains($0.key)
        }
        runtime.sourceEvidence = runtime.sourceEvidence.filter {
            retained.contains($0.key)
        }
        runtime.sourceWarnings = runtime.sourceWarnings.filter {
            paths[$0.key] != nil
        }
        runtime.watchedPaths = paths
        guard !closing, !entries.isEmpty else {
            return
        }
        let generation = runtime.watchGeneration
        runtime.watchTask = Task {
            [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closing, runtime.watchGeneration == generation else {
                    return
                }
                let domain = runtime.defaults ?? .standard
                guard runtime.sourceDomain === domain,
                    runtime.source?.isEqual(self.themePreferenceSource(domain)) == true
                else {
                    runtime.loaded = false
                    Task {
                        [weak self] in await self?.loadThemeLibrary()
                    }
                    return
                }
                for entry in runtime.library?.entries ?? [] where entry.watchesSource {
                    guard !Task.isCancelled, runtime.watchGeneration == generation, !self.closing else {
                        return
                    }
                    await self.refreshThemeSource(entry, generation: generation)
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                }
                catch {
                    return
                }
            }
        }
    }

    /// 业务作用：来源变化先完成完整读取、样式校验与旧偏好复验，再以同一稳定主题身份发布。
    /// 参数说明:
    /// - entry: 当前完整库明确授权的主题来源项。
    /// - generation: 当前监视资格，显式配置变化后旧资格不可复用。
    /// 返回：合法完整新配色同步到对应主题；错误、同字节、改向或迟到结果保持原显示。
    func refreshThemeSource(_ entry: EditorThemeEntry, generation: UUID) async {
        let runtime = themePreferences
        guard let path = entry.sourcePath, entry.watchesSource,
            runtime.watchGeneration == generation, !closing
        else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let access = fileAccess
        let languages = Set(registry?.languages.map(\.id) ?? [])
        var attemptedStamp: ThemeSourceStamp?
        do {
            let stamp = try await runtime.io.readCancellable {
                token in
                try ThemeSourceStamp.read(
                    url,
                    permit: {
                        !token.isCancelled
                    }
                )
            }
            guard !Task.isCancelled, runtime.watchGeneration == generation, !closing else {
                return
            }
            if runtime.observed[entry.id] == stamp, let verified = runtime.verifiedAt[entry.id],
                ContinuousClock.now - verified < .seconds(30)
            {
                return
            }
            // 低成本元数据不授予配色发布权；周期完整摘要也识别保留时间戳的同大小改写。
            attemptedStamp = stamp
            let prepared = try await runtime.io.readCancellable {
                token in
                let first = try ThemeSourceStamp.read(
                    url,
                    permit: {
                        !token.isCancelled
                    }
                )
                let bytes = try access.readData(
                    url,
                    maximumBytes: 8 * 1024 * 1024,
                    permit: {
                        !token.isCancelled
                    }
                )
                let parsed = try EditorThemeImport.parse(
                    bytes.data,
                    name: entry.definition.name,
                    languages: languages,
                    permit: {
                        !token.isCancelled
                    }
                )
                let last = try ThemeSourceStamp.read(
                    url,
                    permit: {
                        !token.isCancelled
                    }
                )
                guard first == last, bytes.baseline.device == last.device,
                    bytes.baseline.inode == last.inode, bytes.baseline.resolvedPath == last.resolvedPath
                else {
                    throw NateError.message("主题来源在读取或解析期间发生变化，当前主题保留。")
                }
                return (parsed, bytes.baseline, last)
            }
            // 文件读取完成不等于仍然拥有该主题，路径、来源和监视资格在发布前再次确认。
            guard !Task.isCancelled, runtime.watchGeneration == generation, !closing,
                let current = runtime.library,
                let index = current.entries.firstIndex(where: {
                    $0.id == entry.id && $0.sourcePath == path && $0.watchesSource
                })
            else {
                return
            }
            runtime.observed[entry.id] = prepared.2
            runtime.verifiedAt[entry.id] = .now
            if let evidence = runtime.sourceEvidence[entry.id] {
                guard evidence.resolvedPath == prepared.1.resolvedPath else {
                    throw NateError.message("主题来源路径已改向，请重新导入并确认本地来源。")
                }
                if evidence.digest == prepared.1.digest {
                    updateThemeSourceWarning(entry, imported: prepared.0)
                    return
                }
            }
            let imported = prepared.0.definition
            let definition = try EditorThemeDefinition(
                name: current.entries[index].definition.name,
                colors: imported.colors,
                kindStyles: imported.kindStyles,
                languageStyles: imported.languageStyles
            )
            if definition != current.entries[index].definition {
                var entries = current.entries
                entries[index] = try EditorThemeEntry(
                    id: entry.id,
                    definition: definition,
                    sourcePath: path,
                    watchesSource: true
                )
                let candidate = try EditorThemeLibrary(entries: entries, selectedID: current.selectedID)
                let domain = runtime.defaults ?? .standard
                guard let source = runtime.source, runtime.sourceDomain === domain,
                    source.isEqual(themePreferenceSource(domain))
                else {
                    throw NateError.message("主题偏好已在外部变化，来源新配色未覆盖当前配置。")
                }
                try await publishThemeLibrary(
                    candidate,
                    generation: runtime.generation,
                    source: source,
                    restartWatching: false
                )
            }
            runtime.sourceEvidence[entry.id] = prepared.1
            updateThemeSourceWarning(entry, imported: prepared.0)
        }
        catch is CancellationError {
            return
        }
        catch {
            guard !Task.isCancelled, runtime.watchGeneration == generation, !closing else {
                return
            }
            if let attemptedStamp {
                runtime.observed[entry.id] = attemptedStamp
                runtime.verifiedAt[entry.id] = .now
            }
            let warning = "主题来源未采用，当前配色保留：" + entry.definition.name + " · " + error.localizedDescription
            if runtime.sourceWarnings[entry.id] != warning {
                runtime.sourceWarnings[entry.id] = warning
                mainWindow?.status.stringValue = warning
            }
        }
        updateThemeWatchWarnings()
    }

    /// 业务作用：来源恢复后撤去旧失败说明，仍有未映射字段时保留兼容边界。
    /// 参数说明:
    /// - entry: 当前明确来源主题。
    /// - imported: 当前完整已验证的转换及兼容说明。
    /// 返回：当前来源说明与最新完整读取一致，不触及主题定义或正文。
    func updateThemeSourceWarning(_ entry: EditorThemeEntry, imported: EditorThemeImportResult) {
        let runtime = themePreferences
        runtime.sourceWarnings.removeValue(forKey: entry.id)
        if !imported.reports.isEmpty || imported.omittedReportCount > 0 {
            runtime.sourceWarnings[entry.id] = "主题来源含未映射字段，可重新导入查看逐项说明：" + entry.definition.name
        }
        updateThemeWatchWarnings()
    }

    /// 业务作用：主题库说明由当前仍有效的来源汇总，已恢复来源不留下过期失败提示。
    /// 参数说明: 无。
    /// 返回：有限完整说明或真正的空状态，不制造空字符串告警。
    func updateThemeWatchWarnings() {
        let runtime = themePreferences
        let messages =
            [runtime.bundledWarning].compactMap {
                $0
            } + runtime.sourceWarnings.values.sorted()
        runtime.warning = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}
