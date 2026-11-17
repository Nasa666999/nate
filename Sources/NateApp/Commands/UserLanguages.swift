import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax
import NateUI

extension ApplicationController {
    /// 业务作用：分别载入预装和用户 UDL，单份损坏不阻止编辑器启动。
    /// 参数说明: 无。
    /// 返回：只发布完整有效定义，重复名称保留先前规则并反馈。
    func loadUserLanguages() async {
        let bundled = SystemIntegration.resourceDirectory().appendingPathComponent("udl")
        let custom = recovery?.directory.deletingLastPathComponent().appendingPathComponent("UDL")
        do {
            let loaded = try await readIO.readCancellable {
                token in
                var output: [(UDLDefinition, URL?, DiskBaseline?)] = []
                var errors: [String] = []
                for directory in [bundled, custom].compactMap({
                    $0
                }) {
                    guard FileManager.default.fileExists(atPath: directory.path) else {
                        continue
                    }
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    )
                    for url in urls.sorted(by: {
                        $0.path < $1.path
                    }) where url.pathExtension == "xml" {
                        try token.check()
                        do {
                            let owned = directory == custom
                            let bytes =
                                owned
                                ? try self.fileAccess.readData(
                                    url,
                                    maximumBytes: 8_388_608,
                                    permit: {
                                        !token.isCancelled
                                    }
                                )
                                : try FileStorage.readData(
                                    url,
                                    maximumBytes: 8_388_608,
                                    permit: {
                                        !token.isCancelled
                                    }
                                )
                            let definitions = try UDLImporter.parse(bytes.data)
                            let baseline = owned ? bytes.baseline : nil
                            for definition in definitions {
                                output.append((definition, owned ? url : nil, baseline))
                            }
                        }
                        catch is CancellationError {
                            throw CancellationError()
                        }
                        catch {
                            errors.append(url.lastPathComponent + "：" + error.localizedDescription)
                        }
                    }
                }
                return (output, errors)
            }
            var errors = loaded.1
            for (definition, url, baseline) in loaded.0 {
                guard userLanguages[definition.id] == nil else {
                    errors.append("UDL 重名：" + definition.name)
                    continue
                }
                userLanguages[definition.id] = definition
                if let url {
                    userLanguageSources[definition.id] = url
                    userLanguageBaselines[url.path] = baseline
                }
            }
            registry = registry?.adding(
                Array(userLanguages.values).sorted {
                    $0.name < $1.name
                }
            )
            if !errors.isEmpty {
                SystemIntegration.alert("部分语言资源未载入", errors.joined(separator: "\n"))
            }
        }
        catch {
            SystemIntegration.alert("语言资源", error.localizedDescription)
        }
    }

    /// 业务作用：导入、编辑和新建使用相同的原子资源发布通道。
    /// 参数说明:
    /// - data: 完整 XML 定义。
    /// - replacing: 已有用户资源，预装资源不能原地修改。
    /// 返回：文件可靠保存后才发布规则及关联；失败保留旧配置。
    func persistUDL(_ data: Data, replacing: URL?) async throws {
        guard !publishingResources else {
            throw NateError.message("另一份语言资源正在发布，请稍后重试。")
        }
        publishingResources = true
        defer {
            publishingResources = false
        }
        let definitions = try await fileIO.run {
            try UDLImporter.parse(data)
        }
        let replacedIDs = Set(
            userLanguageSources.filter {
                $0.value == replacing
            }.map(\.key)
        )
        guard
            definitions.allSatisfy({
                userLanguages[$0.id] == nil || replacedIDs.contains($0.id)
            })
        else {
            throw NateError.message("存在同名语言，请修改 XML 中的 name 后再保存；现有定义未覆盖。")
        }
        guard let root = recovery?.directory.deletingLastPathComponent().appendingPathComponent("UDL") else {
            throw NateError.message("用户资源目录不可用。")
        }
        let destination = replacing ?? root.appendingPathComponent(UUID().uuidString + ".xml")
        let expected = userLanguageBaselines[destination.path]
        let baseline = try await fileIO.run {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return try self.fileOperations.save(
                using: self.fileAccess,
                data,
                to: destination,
                expected: expected
            )
        }
        // 持久化成功后才一次发布完整注册表，旧后台语法任务由资源变化失效。
        for id in replacedIDs {
            userLanguages.removeValue(forKey: id)
            userLanguageSources.removeValue(forKey: id)
        }
        for definition in definitions {
            userLanguages[definition.id] = definition
            userLanguageSources[definition.id] = destination
        }
        userLanguageBaselines[destination.path] = baseline
        registry = registry?.removing(replacedIDs).adding(definitions)
        let newIDs = Set(definitions.map(\.id))
        for document in documents
        where replacedIDs.contains(document.language) && !newIDs.contains(document.language) {
            document.language = definitions.count == 1 ? definitions[0].id : "normal"
        }
        buildMenus()
        refreshUI()
        mainWindow?.editor.invalidateSyntax()
    }

    /// 业务作用：通过界面导入完整 UDL，未知字段保留在原始 XML 中。
    /// 参数说明: 无。
    /// 返回：验证和安全写入后加入语言列表。
    func importUDL() {
        guard let url = SystemIntegration.chooseFiles().first else {
            return
        }
        Task {
            do {
                let data = try await readIO.readCancellable {
                    token in
                    try self.fileAccess.readData(
                        url,
                        maximumBytes: 8_388_608,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    .data
                }
                try await persistUDL(data, replacing: nil)
                let messages = try UDLImporter.parse(data).flatMap(\.diagnostics)
                SystemIntegration.alert(
                    "UDL 已导入",
                    messages.isEmpty ? "规则已加入语言菜单。原 XML 可完整导出。" : messages.joined(separator: "\n")
                )
            }
            catch {
                SystemIntegration.alert("UDL 导入失败", error.localizedDescription)
            }
        }
    }

    /// 业务作用：导出保留未知字段的完整原定义，不把高亮近似结果写成 XML。
    /// 参数说明: 无。
    /// 返回：单独保存定义，不修改用户正文或应用内规则。
    func exportUDL() {
        guard let active, let definition = userLanguages[active.language],
            let url = SystemIntegration.chooseSave(name: definition.name + ".xml")
        else {
            return
        }
        let data = definition.originalXML
        Task {
            do {
                try await fileIO.run {
                    let expected =
                        FileManager.default.fileExists(atPath: url.path)
                        ? try self.fileAccess.baseline(url) : nil
                    _ = try self.fileOperations.save(
                        using: self.fileAccess,
                        data,
                        to: url,
                        expected: expected,
                        replacing: true
                    )
                }
            }
            catch {
                SystemIntegration.alert("UDL 导出失败", error.localizedDescription)
            }
        }
    }

    /// 业务作用：新建、复制、重命名和字段编辑都可在完整 XML 界面完成。
    /// 参数说明:
    /// - creating: 是否从空语言模板开始。
    /// 返回：只有“校验并保存”成功才改变当前有效规则。
    func editUDL(creating: Bool) {
        let definition = active.flatMap {
            userLanguages[$0.language]
        }
        let source: String
        if !creating, let definition {
            source = String(decoding: definition.originalXML, as: UTF8.self)
        }
        else {
            source = """
                <?xml version="1.0" encoding="UTF-8"?>
                <NotepadPlus><UserLang name="自定义语言" ext="example" udlVersion="2.1">
                <Settings><Global caseIgnored="no"/><Prefix Keywords1="no"/></Settings>
                <KeywordLists><Keywords name="Comments">00// 03/* 04*/</Keywords>
                <Keywords name="Keywords1">if else return</Keywords><Keywords name="Operators1">+ - =</Keywords>
                <Keywords name="Delimiters">00&quot; 01\\ 02&quot;</Keywords></KeywordLists>
                <Styles><WordsStyle name="KEYWORDS1" fgColor="8250DF" colorStyle="1" fontStyle="1" nesting="0"/>
                <WordsStyle name="COMMENTS" fgColor="718096" colorStyle="1" fontStyle="0" nesting="0"/>
                <WordsStyle name="DELIMITERS1" fgColor="138A55" colorStyle="1" fontStyle="0" nesting="0"/></Styles>
                </UserLang></NotepadPlus>
                """
        }
        let destination =
            creating
            ? nil
            : definition.flatMap {
                userLanguageSources[$0.id]
            }
        let editor = ResourceEditor(title: "UDL 完整定义 · 修改 name 可重命名；预装定义另存为新名称", source: source)
        editor.onSave = {
            [weak self, weak editor] source in
            Task {
                do {
                    try await self?.persistUDL(Data(source.utf8), replacing: destination)
                    editor?.message.stringValue = "定义已可靠保存并发布。"
                }
                catch {
                    editor?.message.stringValue = error.localizedDescription
                }
            }
        }
        retainedWindows.append(editor)
        editor.showWindow(nil)
    }
}
