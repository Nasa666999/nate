import Foundation
import NateCore

public enum ProjectWorkspaceArchive {
    /// 业务作用：对项目定义执行有界解码，清单中的文件引用只作为数据，不参与载入时的磁盘或网络访问。
    /// 参数说明:
    /// - data: 已读取的完整归档字节。
    /// 返回：最多 8 MiB 且结构有效的工作区，解析失败不返回空默认集合。
    public static func decode(_ data: Data) throws -> ProjectWorkspace {
        guard data.count <= 8 * 1024 * 1024 else {
            throw NateError.message("项目工作区归档超过 8 MiB，原定义应保持不变。")
        }
        return try JSONDecoder().decode(ProjectWorkspace.self, from: data)
    }

    /// 业务作用：把完整有效虚拟集合编码为项目归档，超限失败而不丢弃节点或截断路径。
    /// 参数说明:
    /// - workspace: 需要保存的完整工作区定义。
    /// 返回：可交给安全文件写入通道的最多 8 MiB JSON；本函数不写文件或取得覆盖权限。
    public static func encode(_ workspace: ProjectWorkspace) throws -> Data {
        try workspace.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(workspace)
        guard data.count <= 8 * 1024 * 1024 else {
            throw NateError.message("项目工作区归档超过 8 MiB，请减少引用后重新保存。")
        }
        return data
    }
}
