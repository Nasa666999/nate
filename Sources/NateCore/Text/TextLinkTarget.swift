import Foundation

enum TextLinkTarget {
    /// 业务作用：只有完整且可表示的 URI 候选才能成为点击目标，识别过程不查询处理程序或访问目标。
    /// 参数说明:
    /// - value: 已按原文字面边界裁剪的完整候选。
    /// - prefixLength: 当前已验证协议前缀的 ASCII 字节数。
    /// 返回：完整 URI 可表示时返回固定系统 URL；非法、缺少目标或含控制字符时为空，超量时整份失败。
    static func url(for value: String, prefixLength: Int) throws -> URL? {
        guard value.utf8.count <= 16_384 else {
            throw NateError.message("单个链接目标超过 16 KiB，未截断或打开部分目标。")
        }
        let bytes = Array(value.utf8)
        guard prefixLength > 0, bytes.count > prefixLength,
            !value.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            })
        else {
            return nil
        }
        for index in bytes.indices where bytes[index] == 37 {
            // 非法百分号不能交给 URL 构造器改写成另一份字面目标。
            guard bytes.count - index >= 3, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else {
                return nil
            }
        }
        guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty,
            let colon = bytes.firstIndex(of: 58)
        else {
            return nil
        }
        let actualScheme = scheme.lowercased()
        let hasAuthority = bytes.count - colon >= 3 && bytes[colon + 1] == 47 && bytes[colon + 2] == 47
        if actualScheme != "file", hasAuthority || ["http", "https", "ftp"].contains(actualScheme) {
            guard let host = url.host, !host.isEmpty else {
                return nil
            }
        }
        if actualScheme == "file", !url.path.hasPrefix("/") {
            return nil
        }
        if let port = url.port, !(0...65_535).contains(port) {
            return nil
        }
        return url
    }

    /// 业务作用：百分号转义只接受两个完整 ASCII 十六进制位，不按区域或 Unicode 外观猜测字节。
    /// 参数说明:
    /// - byte: 原候选中的一个转义字节。
    /// 返回：字节为 0–9、A–F 或 a–f 时为真。
    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
