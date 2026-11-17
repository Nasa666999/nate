import Foundation
import NateCore

extension FileStorage {
    /// 业务作用：在路径规范化或平台访问之前确认本地文件 URL 的真实解码路径，防止无效字符被当作另一文件名。
    /// 参数说明:
    /// - url: 尚未解析符号链接或改写路径的原请求目标。
    /// 返回：主机为空或 localhost、无凭据和端口、路径可无损解码且不含 NUL 的 file URL 通过；其它目标在文件动作前拒绝。
    public static func validateFileURL(_ url: URL) throws {
        let absolute = url.absoluteURL
        // 非 file URL 的 path 也可能看似本机路径，不能借另一个协议的字段取得本地文件访问权。
        guard absolute.isFileURL else {
            throw NateError.message("文件访问只接受 file URL。")
        }
        let host = absolute.host(percentEncoded: true) ?? ""
        // 远程主机和凭据不属于本机路径授权，网络盘只能沿已挂载的本地目录访问。
        guard let decodedHost = host.removingPercentEncoding,
            decodedHost.isEmpty || decodedHost.caseInsensitiveCompare("localhost") == .orderedSame,
            absolute.user == nil, absolute.password == nil, absolute.port == nil
        else {
            throw NateError.message("文件 URL 不能指定远程主机、凭据或端口；请使用已挂载目录中的路径。")
        }
        // 解码失败不能降级为字面的转义文件名，否则原请求会被改写为另一个目标。
        guard let path = absolute.path(percentEncoded: true).removingPercentEncoding, !path.isEmpty else {
            throw NateError.message("文件 URL 缺少可无损解码的有效路径。")
        }
        // URL.path 可能保留转义文字，必须检查完整百分号解码值，不能把 NUL 改成字面 %00 后继续写入。
        guard !path.utf8.contains(0) else {
            throw NateError.message("文件路径不能包含 NUL。")
        }
    }
}
