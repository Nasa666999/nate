import AppKit
import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax

extension ApplicationController {
    /// 业务作用：复制预装或用户定义时建立新名称，不覆盖原规则。
    /// 参数说明: 无。
    /// 返回：完整保留被复制语言的已知和未知 XML 字段。
    func duplicateUDL() {
        guard let active, let definition = userLanguages[active.language],
            let name = SystemIntegration.prompt("复制 UDL", "输入独立语言名称", initial: definition.name + " 副本"),
            !name.isEmpty
        else {
            return
        }
        Task {
            do {
                let document = try XMLDocument(
                    data: definition.originalXML,
                    options: [.nodeLoadExternalEntitiesNever]
                )
                guard let root = document.rootElement() else {
                    throw NateError.message("UDL 根元素缺失。")
                }
                var found = false
                for node in root.elements(forName: "UserLang") {
                    if node.attribute(forName: "name")?.stringValue == definition.name {
                        node.attribute(forName: "name")?.stringValue = name
                        found = true
                    }
                    else {
                        node.detach()
                    }
                }
                guard found else {
                    throw NateError.message("UDL 原始定义与语言名称不一致。")
                }
                try await persistUDL(document.xmlData(options: [.nodePrettyPrint]), replacing: nil)
                active.language = "udl:" + name
                active.languageExplicit = true
                refreshUI()
            }
            catch {
                SystemIntegration.alert("无法复制 UDL", error.localizedDescription)
            }
        }
    }

    /// 业务作用：删除精确自定义语言，预装定义不在应用包内被改写。
    /// 参数说明: 无。
    /// 返回：剩余源文件仍有效；最后一个定义移到废纸篓，文档正文保持不变。
    func deleteUDL() async {
        guard let active, let definition = userLanguages[active.language],
            let source = userLanguageSources[definition.id]
        else {
            SystemIntegration.alert("删除 UDL", "只能删除自定义语言。预装定义可先复制为独立自定义语言。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "删除语言 \(definition.name)？"
        alert.informativeText = "使用该语言的文档改为纯文本，正文不会删除。"
        alert.addButton(withTitle: "删除语言")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn, !publishingResources else {
            return
        }
        let affected = documents.filter {
            $0.language == definition.id
        }
        do {
            let xml = try XMLDocument(data: definition.originalXML, options: [.nodeLoadExternalEntitiesNever])
            guard let root = xml.rootElement() else {
                throw NateError.message("UDL 根元素缺失。")
            }
            for node in root.elements(forName: "UserLang")
            where node.attribute(forName: "name")?.stringValue == definition.name {
                node.detach()
            }
            if root.elements(forName: "UserLang").isEmpty {
                publishingResources = true
                defer {
                    publishingResources = false
                }
                let expected = userLanguageBaselines[source.path]
                try await fileIO.run {
                    guard try FileStorage.baseline(source) == expected else {
                        throw NateError.message("UDL 文件已被外部改变，请重新载入。")
                    }
                    try FileManager.default.trashItem(at: source, resultingItemURL: nil)
                }
                userLanguages.removeValue(forKey: definition.id)
                userLanguageSources.removeValue(forKey: definition.id)
                userLanguageBaselines.removeValue(forKey: source.path)
                registry = registry?.removing([definition.id])
            }
            else {
                try await persistUDL(xml.xmlData(options: [.nodePrettyPrint]), replacing: source)
            }
            for document in affected {
                document.language = "normal"
            }
            buildMenus()
            refreshUI()
            mainWindow?.editor.invalidateSyntax()
        }
        catch {
            SystemIntegration.alert("无法删除 UDL", error.localizedDescription)
        }
    }
}
