import Foundation
import NateCore

struct UDLFontSettings {
    let name: String?
    let size: Int?

    /// 业务作用：用户语言字体与字号独立继承，合法显式值不能在解析时被丢弃。
    /// 参数说明:
    /// - values: 当前 WordsStyle 的完整属性。
    /// 返回：保留原名称与整数点数；空值、0 和 -1 表示继承，非法字段拒绝整份定义。
    init(_ values: [String: String]) throws {
        let font = values["fontName"] ?? ""
        name = font.isEmpty ? nil : font
        let raw = values["fontSize"] ?? ""
        if raw.isEmpty {
            size = nil
        }
        else {
            guard let value = Int(raw) else {
                throw NateError.message("UDL fontSize 必须为整数点数，空值、0 或 -1 表示继承。")
            }
            size = value == 0 || value == -1 ? nil : value
        }
        try Self.validate(name: name, size: size)
    }

    /// 业务作用：导入与运行时字体字段共用容量及数值边界，任意可变定义不能扩大原生排版负担。
    /// 参数说明:
    /// - name: 原始字体名称，为空时继承。
    /// - size: 显式整数点数，为空时继承。
    /// 返回：名称最多 256 UTF-8 字节且无控制符、字号在 1–512 时成功；否则拒绝全部样式。
    static func validate(name: String?, size: Int?) throws {
        if let name {
            guard !name.isEmpty, name.utf8.count <= 256,
                name.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                })
            else {
                throw NateError.message("UDL fontName 必须为不含控制符、最多 256 UTF-8 字节的非空名称。")
            }
        }
        if let size, !(1...512).contains(size) {
            throw NateError.message("UDL fontSize 必须为 1 至 512 点，0 或 -1 表示继承。")
        }
    }
}
