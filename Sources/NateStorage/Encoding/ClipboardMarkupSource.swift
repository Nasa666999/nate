import Foundation
import NateCore

public enum ClipboardMarkupSource {
    /// 业务作用：HTML 与 RTF 的专用剪贴板表示只解码为源码文本，不渲染样式、载入资源或访问网络。
    /// 参数说明:
    /// - data: 用户主动选择的完整专用表示，最多 64 MiB。
    /// - format: 明确选择的 HTML 或 RTF 源码类型。
    /// - catalog: 当前应用随包的严格代码页映射。
    /// - deadline: 整个粘贴动作的共同截止，省略时采用五秒；不能延长本次解码预算。
    /// - permit: 本次解码仍有效的资格。
    /// 返回：完整源码 Unicode 原文；未知声明、非法编码、超量或取消失败，不提供截断文本。
    public static func decode(
        _ data: Data,
        format: ClipboardMarkupFormat,
        catalog: LegacyCodecCatalog? = nil,
        deadline: ContinuousClock.Instant? = nil,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> String {
        let deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        try check(deadline: deadline, permit: permit)
        guard data.count <= ClipboardLimits.contentBytes else {
            throw NateError.message("源码剪贴板表示超过 64 MiB，原正文保持不变。")
        }
        let value: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF])
        {
            // BOM 明确标识传输编码，不把其字节误作正文标记或按历史 ANSI 代码页解释。
            value = try TextEncoding.detect(data, catalog: catalog).0
        }
        else if format == .rtf {
            let page = try rtfCodePage(data)
            value = try TextEncoding(
                codePage: page,
                name: "RTF 源码代码页 \(page)"
            ).decode(data, catalog: catalog)
        }
        else {
            // 原生 HTML 文本表示使用严格 UTF-8；网页源码中的 charset 不授予重新猜测传输字节的资格。
            value = try TextEncoding.utf8.decode(data, catalog: catalog)
        }
        guard value.utf8.count <= ClipboardLimits.contentBytes else {
            throw NateError.message("解码后的完整源码超过 64 MiB，未返回部分文本。")
        }
        try check(deadline: deadline, permit: permit)
        return value
    }

    /// 业务作用：RTF 的传输代码页只从有界根头部读取，正文、嵌套组和二进制块中的相同字节不能改变编码。
    /// 参数说明:
    /// - data: 没有 BOM 的原始 RTF 表示。
    /// 返回：明确 ansicpg、ANSI、Mac 或 OEM 代码页；合法 RTF 头部缺省为 Windows-1252，无头部内容只按严格 UTF-8 读取。
    private static func rtfCodePage(_ data: Data) throws -> UInt32 {
        let prefix = Array(data.prefix(8192))
        guard prefix.starts(with: Array("{\\rtf".utf8)) else {
            return 65001
        }
        var index = 1
        var explicit: UInt32?
        var family: UInt32?
        while index < prefix.count {
            if [9, 10, 13, 32].contains(prefix[index]) {
                index += 1
                continue
            }
            // 首个正文字符或嵌套组已经离开根头部，后续控制字不再拥有全局代码页的解释权。
            guard prefix[index] == 92 else {
                break
            }
            index += 1
            guard index < prefix.count else {
                break
            }
            let start = index
            while index < prefix.count,
                (65...90).contains(prefix[index]) || (97...122).contains(prefix[index])
            {
                index += 1
            }
            let word = String(
                decoding: prefix[start..<index],
                as: UTF8.self
            )
            guard !word.isEmpty else {
                break
            }
            let parameterStart = index
            if index < prefix.count, prefix[index] == 45 {
                index += 1
            }
            while index < prefix.count, (48...57).contains(prefix[index]) {
                index += 1
            }
            // 截断的声明不能被当成较短而恰好有效的代码页，超过头部预算须完整拒绝。
            guard index < prefix.count || data.count == prefix.count else {
                throw NateError.message("RTF 根头部超过 8 KiB，未猜测截断的编码声明。")
            }
            if ["bin", "pard", "plain", "par", "line", "tab"].contains(word) {
                break
            }
            if word == "ansicpg" {
                let value = String(
                    decoding: prefix[parameterStart..<index],
                    as: UTF8.self
                )
                guard let page = UInt32(value), page > 0, explicit == nil || explicit == page else {
                    throw NateError.message("RTF 编码声明缺失、冲突或不能解释，原内容保留。")
                }
                explicit = page
            }
            let mode: UInt32?
            switch word {
            case "ansi": mode = 1252
            case "mac": mode = 10000
            case "pc": mode = 437
            case "pca": mode = 850
            default: mode = nil
            }
            if let mode {
                guard family == nil || family == mode else {
                    throw NateError.message("RTF 包含冲突的字符集声明，原内容保留。")
                }
                family = mode
            }
        }
        guard index < prefix.count || data.count == prefix.count else {
            throw NateError.message("RTF 根头部超过 8 KiB，未猜测截断的编码声明。")
        }
        return explicit ?? family ?? 1252
    }

    /// 业务作用：解码前后共用实际截止和执行资格，后台取消不能产生可继续粘贴的旧源码。
    /// 参数说明:
    /// - deadline: 本次完整解码的共同截止。
    /// - permit: 当前发布来源仍有效的资格。
    /// 返回：仍有资格时继续；取消或超时整份拒绝。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("源码剪贴板解码超过五秒，原正文保持不变。")
        }
    }
}
