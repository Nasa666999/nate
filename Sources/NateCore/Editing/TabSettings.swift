import Foundation

public struct TabSettings: Sendable, Equatable, Codable {
    public let width: Int
    public let useSpaces: Bool

    /// 业务作用：未配置的语言沿用四列真实 Tab，不在启动时重写已有正文。
    /// 参数说明: 无。
    /// 返回：宽度为四且保留 Tab 字符的默认输入规则。
    public init() {
        width = 4
        useSpaces = false
    }

    /// 业务作用：固定合法的 Tab 停靠间距及新输入方式，显示宽度与原字节分别管理。
    /// 参数说明:
    /// - width: 每个停靠间距占用的空格列数，一至三十二。
    /// - useSpaces: 新的 Tab 按键是否生成到下一停靠位的空格。
    /// 返回：完整合法设置；越界时拒绝，不把非法值夹取成另一项配置。
    public init(width: Int, useSpaces: Bool) throws {
        guard (1...32).contains(width) else {
            throw NateError.message("Tab 宽度必须为 1 到 32 列。")
        }
        self.width = width
        self.useSpaces = useSpaces
    }

    /// 业务作用：归档恢复同样执行输入规则校验，不能把损坏列宽交给排版或正文计划。
    /// 参数说明:
    /// - decoder: 完整设置归档中的单项规则。
    /// 返回：字段完整且宽度合法时恢复，否则整项失败。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: values.decode(Int.self, forKey: .width),
            useSpaces: values.decode(Bool.self, forKey: .useSpaces)
        )
    }
}

public struct LanguageTabSettings: Sendable, Equatable, Codable {
    public let defaults: TabSettings
    public let languages: [String: TabSettings]

    /// 业务作用：为没有偏好的工作区建立统一默认，未命名或尚未识别的语言也有明确规则。
    /// 参数说明: 无。
    /// 返回：四列真实 Tab，尚无语言覆盖项。
    public init() {
        defaults = TabSettings()
        languages = [:]
    }

    /// 业务作用：整份固定默认与语言覆盖关系，语言名称不作为文件路径或可执行配置解释。
    /// 参数说明:
    /// - defaults: 没有覆盖项时采用的完整规则。
    /// - languages: 最多五百一十二项、以稳定语言身份索引的独立规则。
    /// 返回：全部语言身份为非空、至多 512 UTF-8 字节且无控制符时建立完整配置，否则拒绝整份。
    public init(defaults: TabSettings, languages: [String: TabSettings]) throws {
        guard languages.count <= 512,
            languages.keys.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 512
                    && !$0.unicodeScalars.allSatisfy {
                        $0.properties.isWhitespace
                    }
                    && $0.unicodeScalars.allSatisfy {
                        ![.control, .lineSeparator, .paragraphSeparator].contains(
                            $0.properties.generalCategory
                        )
                    }
            })
        else {
            throw NateError.message("Tab 配置最多包含 512 个有效语言身份，每项最多 512 UTF-8 字节且不能包含控制符。")
        }
        self.defaults = defaults
        self.languages = languages
    }

    /// 业务作用：当前语言只采用自身明确覆盖项，缺失时完整继承全局默认。
    /// 参数说明:
    /// - language: 内置或用户定义语言的稳定身份。
    /// 返回：不修改配置的实际生效规则，未知语言同样继承默认值。
    public func settings(for language: String) -> TabSettings {
        languages[language] ?? defaults
    }

    /// 业务作用：恢复配置时复验整份语言数量和身份，保留未知语言的合法规则供以后重新启用。
    /// 参数说明:
    /// - decoder: 完整语言 Tab 配置。
    /// 返回：默认与全部覆盖项均合法时恢复，任一项异常时整体失败。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            defaults: values.decode(TabSettings.self, forKey: .defaults),
            languages: values.decode([String: TabSettings].self, forKey: .languages)
        )
    }
}
