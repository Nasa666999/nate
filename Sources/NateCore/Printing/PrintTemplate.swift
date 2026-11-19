import Foundation

public struct PrintTemplate: Sendable {
    private enum Part: Sendable {
        case literal(String)
        case variable(String)
    }
    private let parts: [Part]
    public static let variables = [
        "FULL_CURRENT_PATH", "FILE_NAME", "CURRENT_DIRECTORY", "CURRENT_PRINTING_PAGE",
        "TOTAL_PRINTING_PAGES", "SHORT_DATE", "LONG_DATE", "TIME",
    ]

    /// 业务作用：页眉页脚模板只解析一次，元数据中的相同符号永远只是字面值。
    /// 参数说明:
    /// - source: 最多四 KiB 的完整模板；$$ 表示字面美元符号。
    /// 返回：已验证的固定片段序列；未知变量、残缺括号与容量超限失败。
    public init(_ source: String) throws {
        guard source.utf8.count <= 4096 else {
            throw NateError.message("打印模板超过 4 KiB。")
        }
        var parts: [Part] = []
        let bytes = Array(source.utf8)
        var literal: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let next = index + 1
            if bytes[index] == 36, next < bytes.count {
                if bytes[next] == 36 {
                    literal.append(36)
                    index = next + 1
                    continue
                }
                if bytes[next] == 40 {
                    guard let end = bytes[(next + 1)...].firstIndex(of: 41) else {
                        throw NateError.message("打印模板变量缺少右括号。")
                    }
                    let key = String(
                        decoding: bytes[(next + 1)..<end],
                        as: UTF8.self
                    )
                    guard Self.variables.contains(key) else {
                        throw NateError.message("打印模板包含未知变量：\(key)。")
                    }
                    if !literal.isEmpty {
                        parts.append(
                            .literal(
                                String(
                                    decoding: literal,
                                    as: UTF8.self
                                )
                            )
                        )
                        literal.removeAll(keepingCapacity: true)
                    }
                    parts.append(.variable(key))
                    index = end + 1
                    continue
                }
            }
            literal.append(bytes[index])
            index = next
        }
        if !literal.isEmpty {
            parts.append(
                .literal(
                    String(
                        decoding: literal,
                        as: UTF8.self
                    )
                )
            )
        }
        self.parts = parts
    }

    /// 业务作用：按当前页与固定元数据展开实际装饰文字，路径或文件名不取得二次模板解释权。
    /// 参数说明:
    /// - values: 当前作业开始时固定的文件名、路径和日期时间原文。
    /// - page: 实际从一开始的页码。
    /// - totalPages: 当前独立分页的完整页数。
    /// 返回：最多六十四 KiB 的完整文字；缺失变量、非法页码或展开超限失败。
    public func render(values: [String: String], page: Int, totalPages: Int) throws -> String {
        guard page > 0, totalPages >= page else {
            throw NateError.message("打印页码不在完整作业范围内。")
        }
        var output = "", size = 0
        for part in parts {
            let value: String
            switch part {
            case .literal(let literal): value = literal
            case .variable("CURRENT_PRINTING_PAGE"): value = String(page)
            case .variable("TOTAL_PRINTING_PAGES"): value = String(totalPages)
            case .variable(let key):
                guard let source = values[key] else {
                    throw NateError.message("打印作业缺少模板变量：\(key)。")
                }
                value = source
            }
            guard value.utf8.count <= 65_536 - size else {
                throw NateError.message("展开后的打印装饰文字超过 64 KiB。")
            }
            size += value.utf8.count
            output += value
        }
        return output
    }
}
