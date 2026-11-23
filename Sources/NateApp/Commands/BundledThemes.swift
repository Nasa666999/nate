import Foundation
import NateCore
import NateSyntax

private struct BundledThemeColors: Decodable {
    let name: String
    let background: String
    let foreground: String
    let comment: String
    let keyword: String
    let string: String
    let number: String
}

private struct BundledStyleNames: Decodable {
    let format: Int
    let languages: [String: [String: String]]
}

extension ApplicationController {
    /// 业务作用：内置主题沿运行资源目录完整读取，首次启动只提供候选，不写入用户默认选择。
    /// 参数说明:
    /// - directory: 当前应用明确注入的主题资源目录。
    /// 返回：内置明暗候选完整建立后恢复独立主题偏好；资源失败保留说明并允许系统呈现。
    func configureEditorThemes(directory: URL) async {
        let runtime = themePreferences
        let access = fileAccess
        runtime.bundledWarning = nil
        runtime.bundled = []
        do {
            runtime.styleNames = try await runtime.io.readCancellable {
                token in
                let bytes = try access.readData(
                    directory.appendingPathComponent("style-names.json"),
                    maximumBytes: 256 * 1024,
                    permit: {
                        !token.isCancelled
                    }
                )
                try UserConfigurationJSON.validate(
                    bytes.data,
                    permit: {
                        !token.isCancelled
                    }
                )
                let source = try JSONDecoder().decode(BundledStyleNames.self, from: bytes.data)
                guard source.format == 1, source.languages.count <= 512,
                    source.languages.allSatisfy({ language, styles in
                        language.utf8.count <= 256 && styles.count <= 256
                            && styles.allSatisfy({ key, name in
                                UInt8(key) != nil && name.utf8.count <= 256
                            })
                    })
                else {
                    throw NateError.message("主题样式名称资源超量或格式无法识别。")
                }
                return source.languages
            }
        }
        catch {
            runtime.styleNames = [:]
            runtime.bundledWarning = "主题样式名称资源未载入，将显示明确样式编号。" + error.localizedDescription
        }
        do {
            runtime.bundled = try await runtime.io.readCancellable {
                token in
                var entries: [EditorThemeEntry] = []
                for (file, rawIdentity) in [
                    ("light.json", "AD3D724A-702E-48AB-946F-E97F43469D6E"),
                    ("dark.json", "F7F65789-7D72-457A-9332-80279E181B7E"),
                ] {
                    guard let identity = UUID(uuidString: rawIdentity) else {
                        throw NateError.message("内置主题身份无法识别，原配置保留。")
                    }
                    let bytes = try access.readData(
                        directory.appendingPathComponent(file),
                        maximumBytes: 4096,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    try UserConfigurationJSON.validate(
                        bytes.data,
                        permit: {
                            !token.isCancelled
                        }
                    )
                    let palette = try JSONDecoder().decode(BundledThemeColors.self, from: bytes.data)
                    var kinds: [String: EditorThemeStyle] = [:]
                    for (kind, color) in [
                        ("comment", palette.comment), ("keyword", palette.keyword),
                        ("string", palette.string), ("number", palette.number),
                    ] {
                        kinds[kind] = try EditorThemeStyle(foreground: color)
                    }
                    let definition = try EditorThemeDefinition(
                        name: palette.name,
                        colors: ["background": palette.background, "foreground": palette.foreground],
                        kindStyles: kinds
                    )
                    entries.append(try EditorThemeEntry(id: identity, definition: definition))
                }
                return entries
            }
        }
        catch {
            runtime.bundledWarning = "内置主题候选未载入，系统与原资源样式仍可使用。" + error.localizedDescription
        }
        await loadThemeLibrary()
    }
}
