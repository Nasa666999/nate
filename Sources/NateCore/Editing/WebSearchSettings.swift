import Foundation

public enum WebSearchEngine: String, Sendable, Codable, CaseIterable {
    case google
    case duckDuckGo
    case bing
    case yahoo
    case stackOverflow
    case custom
}

public struct WebSearchSettings: Sendable, Codable, Equatable {
    public let engine: WebSearchEngine
    public let customTemplate: String
    public static let placeholder = "$(CURRENT_WORD)"

    private enum CodingKeys: String, CodingKey {
        case engine
        case customTemplate
    }

    /// 业务作用：网络搜索默认选择 Google，读取设置本身不构造查询或访问网络。
    /// 参数说明: 无。
    /// 返回：Google 及空的独立自定义模板草稿。
    public init() {
        engine = .google
        customTemplate = ""
    }

    /// 业务作用：搜索模板只允许明确网页目标和当前查询变量，不能把正文变成协议、主机或其它运行参数。
    /// 参数说明:
    /// - engine: 用户明确选择的搜索引擎。
    /// - customTemplate: 最多 4 KiB 的原模板，停用时保留草稿。
    /// 返回：模板容量与字符合法时建立设置；自定义模式还须具有完整 HTTP(S) 目标及有界查询变量。
    public init(engine: WebSearchEngine, customTemplate: String) throws {
        guard customTemplate.utf8.count <= 4096,
            !customTemplate.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || $0.properties.isWhitespace
            })
        else {
            throw NateError.message("搜索模板最多 4 KiB，空白与控制字符须使用 URL 百分号编码。")
        }
        if engine == .custom {
            try Self.validateTemplate(customTemplate)
        }
        self.engine = engine
        self.customTemplate = customTemplate
    }

    /// 业务作用：恢复归档仍执行完整模板约束，未知引擎或非法目标不能取得网络打开权限。
    /// 参数说明:
    /// - decoder: 完整搜索引擎设置归档。
    /// 返回：所有必填字段有效时恢复，否则整体拒绝。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            engine: values.decode(WebSearchEngine.self, forKey: .engine),
            customTemplate: values.decode(String.self, forKey: .customTemplate)
        )
    }

    /// 业务作用：按所选引擎固定网页模板，兼容 Bing 选择与 DuckDuckGo 使用同一实际目标。
    /// 参数说明: 无。
    /// 返回：只含当前查询变量的完整模板，不读取正文、时钟或系统环境。
    public var template: String {
        switch engine {
        case .google: return "https://www.google.com/search?q=$(CURRENT_WORD)"
        case .duckDuckGo, .bing: return "https://duckduckgo.com/?q=$(CURRENT_WORD)"
        case .yahoo: return "https://search.yahoo.com/search?q=$(CURRENT_WORD)"
        case .stackOverflow: return "https://stackoverflow.com/search?q=$(CURRENT_WORD)"
        case .custom: return customTemplate
        }
    }

    /// 业务作用：完整查询按原始 UTF-8 字节编码后一次展开，正文中的分隔符、变量或 NUL 都不能改变网页目标。
    /// 参数说明:
    /// - query: 单一选区或完整当前词的原文，不裁剪、不归一化。
    /// 返回：至多 64 KiB 的 HTTP(S) URL；空查询、16 KiB 以上查询或展开超量时整体失败，不打开部分结果。
    public func url(for query: String) throws -> URL {
        guard !query.isEmpty, query.utf8.count <= 16_384 else {
            throw NateError.message("网络搜索需要非空的完整选区或当前词，原文最多 16 KiB。")
        }
        let digits = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(query.utf8.count * 3)
        for byte in query.utf8 {
            if byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57
                || [45, 46, 95, 126].contains(byte)
            {
                encoded.append(byte)
            }
            else {
                encoded.append(37)
                encoded.append(digits[Int(byte >> 4)])
                encoded.append(digits[Int(byte & 15)])
            }
        }
        let parts = template.components(separatedBy: Self.placeholder)
        let count = parts.count - 1
        let fixedSize = parts.reduce(0) {
            $0 + $1.utf8.count
        }
        guard count > 0, count <= 16, fixedSize <= 65_536,
            encoded.count <= (65_536 - fixedSize) / count
        else {
            throw NateError.message("网络搜索网址展开超过 64 KiB，未打开部分查询。")
        }
        let result = parts.joined(separator: String(decoding: encoded, as: UTF8.self))
        // 查询只替换路径或参数位置的已编码字节，发布前仍须确认完整网页目标。
        guard let url = URL(string: result), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else {
            throw NateError.message("网络搜索未取得完整 HTTP(S) 目标。")
        }
        return url
    }

    /// 业务作用：模板变量只能位于固定网页目标之后，不能把用户查询解释成主机、凭据或其它命令变量。
    /// 参数说明:
    /// - value: 已完成容量和原字符检查的自定义模板。
    /// 返回：一至十六个当前查询变量及固定 HTTP(S) 权限部分合法时通过，否则拒绝整个模板。
    private static func validateTemplate(_ value: String) throws {
        let parts = value.components(separatedBy: placeholder)
        guard (2...17).contains(parts.count), !parts.joined().contains("$("),
            let separator = value.range(of: "://"), let first = value.range(of: placeholder)
        else {
            throw NateError.message("自定义搜索模板须含 1–16 个 $(CURRENT_WORD)，且不能含其它运行变量。")
        }
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            // 非法百分号不能交给 URL 构造器自动改写成另一份原模板。
            guard index + 2 < bytes.count,
                bytes[(index + 1)...(index + 2)].allSatisfy({
                    $0 >= 48 && $0 <= 57 || $0 >= 65 && $0 <= 70 || $0 >= 97 && $0 <= 102
                })
            else {
                throw NateError.message("自定义模板中的百分号必须跟随两个十六进制数字。")
            }
        }
        // URI 分隔符按 ASCII 字节解释，路径起点后的组合标记不能改变权限部分边界。
        let authorityEnd =
            value.utf8[separator.upperBound...].firstIndex {
                [47, 63, 35].contains($0)
            } ?? value.utf8.endIndex
        let probe = parts.joined(separator: "nate-query")
        guard first.lowerBound >= authorityEnd, let url = URL(string: probe),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else {
            throw NateError.message("模板须固定不含凭据的 HTTP(S) 主机，查询变量只能放在路径、参数或片段中。")
        }
    }

    /// 业务作用：模板来源以原始编码判断，外观相同的不同字符序列不能沿用旧草稿权限。
    /// 参数说明:
    /// - lhs: 已固定的完整设置。
    /// - rhs: 需要复验的当前设置。
    /// 返回：引擎和模板原始 UTF-8 编码均一致时为真。
    public static func == (lhs: WebSearchSettings, rhs: WebSearchSettings) -> Bool {
        lhs.engine == rhs.engine && lhs.customTemplate.utf8.elementsEqual(rhs.customTemplate.utf8)
    }
}
