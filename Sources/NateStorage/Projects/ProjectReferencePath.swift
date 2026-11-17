import Foundation
import NateCore

public enum ProjectReferencePath {
    /// 业务作用：只用字符串规则解释原始文件引用，取得用户位置许可前不构造会探测目录的 URL。
    /// 参数说明:
    /// - reference: 项目定义中的完整原始路径。
    /// - definitionPath: 已保存工作区文件的绝对路径，相对引用需要此基准。
    /// 返回：保留点目录语义的完整绝对本机路径；URI、UNC、无基准相对路径或容量超限明确失败，不访问文件系统。
    public static func absolute(_ reference: String, relativeTo definitionPath: String?) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 16_384, !reference.utf8.contains(0) else {
            throw NateError.message("项目文件引用为空、包含 NUL 或超过 16 KiB。")
        }
        // 外来位置必须由用户重新选择实际本机文件，不能静默转成同名本机路径或主动连接。
        guard !reference.hasPrefix("//"), !reference.hasPrefix("\\\\"), !hasScheme(reference) else {
            throw NateError.message("此引用需要本机位置，请使用“修改文件引用路径”选择已连接位置中的文件。")
        }
        let path: String
        if reference.hasPrefix("/") {
            path = reference
        }
        else {
            guard let definitionPath, definitionPath.hasPrefix("/"), !definitionPath.hasPrefix("//"),
                definitionPath.utf8.count <= 16_384, !definitionPath.utf8.contains(0),
                let slash = definitionPath.lastIndex(of: "/")
            else {
                throw NateError.message("相对文件引用需要先保存工作区，或明确重新选择该文件路径。")
            }
            path = String(definitionPath[..<slash]) + "/" + reference
        }
        guard path.utf8.count <= 16_384 else {
            throw NateError.message("解释后的项目引用超过 16 KiB。")
        }
        // 点目录前可能存在符号链接，访问路径必须保持原文，由存储通道按真实文件系统解析。
        return path
    }

    /// 业务作用：仅以文字计算附加卷确认提示，不把此提示路径替代为真正的文件访问路径。
    /// 参数说明:
    /// - absolutePath: 已取得绝对基准的完整引用。
    /// 返回：文字上的点目录整理后指向 /Volumes 后代时为真；不检查挂载、符号链接或文件存在性。
    public static func referencesVolume(_ absolutePath: String) -> Bool {
        var components: [Substring] = []
        for component in absolutePath.split(separator: "/") {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
            }
            else {
                components.append(component)
            }
        }
        return components.count >= 2 && components.first == "Volumes"
    }

    /// 业务作用：识别首路径段中的 URI 或盘符前缀，未知协议不交给本机文件路径构造器解释。
    /// 参数说明:
    /// - path: 完整原始引用。
    /// 返回：开头符合 ASCII 协议名并带冒号时为真，其余为假；绝对 POSIX 路径中的冒号保持原名。
    private static func hasScheme(_ path: String) -> Bool {
        let first = Array(
            path.utf8.prefix(while: {
                $0 != 47 && $0 != 92
            })
        )
        guard let colon = first.firstIndex(of: 58), colon > 0 else {
            return false
        }
        let letter = (65...90).contains(first[0]) || (97...122).contains(first[0])
        return letter
            && first[..<colon].allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 43 || $0 == 45 || $0 == 46
            }
    }
}
