import Foundation
import NateCore

public enum SidebarRecoveryArchive {
    public static let maximumBytes = 64 * 1024 * 1024

    /// 业务作用：只解码有界的完整侧栏快照，归档内的原目录及项目引用保持为未访问数据。
    /// 参数说明:
    /// - data: 已通过安全读取取得的完整原字节。
    /// 返回：已知格式且全部定义与路径有效的状态；超限、未知或损坏归档失败，不返回默认空状态。
    public static func decode(_ data: Data) throws -> SidebarRecoveryState {
        guard data.count <= maximumBytes else {
            throw NateError.message("侧栏恢复归档超过 64 MiB，原数据保留。")
        }
        let state = try PropertyListDecoder().decode(SidebarRecoveryState.self, from: data)
        try state.validate()
        return state
    }

    /// 业务作用：完整验证后编码侧栏恢复数据，未保存项目定义和保存点同时保留，不截断树或路径。
    /// 参数说明:
    /// - state: 本次需要保护的完整侧栏状态。
    /// 返回：可交给安全发布通道的至多 64 MiB 二进制 plist；编码或容量失败不产生部分归档。
    public static func encode(_ state: SidebarRecoveryState) throws -> Data {
        try state.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(state)
        guard data.count <= maximumBytes else {
            throw NateError.message("侧栏恢复归档超过 64 MiB，未开始发布。")
        }
        return data
    }
}
