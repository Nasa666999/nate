import Foundation
import NateStorage

struct WorkspaceFileReservation {
    let owner: UUID
    let baseline: DiskBaseline?
}

extension DiskBaseline {
    /// 业务作用：不同路径的硬链接与符号链接解析后可以指向同一物理文件。
    /// 参数说明:
    /// - other: 另一条实际文件读取证据。
    /// 返回：设备和 inode 同时一致时为真，内容哈希相同不合并不同文件。
    func sharesFileIdentity(with other: DiskBaseline) -> Bool {
        device == other.device && inode == other.inode
    }
}

extension ApplicationController {
    /// 业务作用：在打开、恢复及写入前读取同一路径或物理身份的在途动作。
    /// 参数说明:
    /// - path: 已解析的真实目标路径。
    /// - baseline: 已存在目标的设备及 inode 证据。
    /// - excluded: 本次动作自身，检查其它持有者时忽略。
    /// 返回：持有相同目标的动作身份，未登记目标时为空。
    func targetReservation(for path: String, baseline: DiskBaseline?, excluding excluded: UUID? = nil)
        -> UUID?
    {
        if let current = targetReservations[Data(path.utf8)], current.owner != excluded {
            return current.owner
        }
        guard let baseline else {
            return nil
        }
        return targetReservations.values.first {
            $0.owner != excluded && $0.baseline?.sharesFileIdentity(with: baseline) == true
        }?.owner
    }

    /// 业务作用：目标尚未绑定标签时先占有路径和已知物理身份，避免别名产生第二个写入者。
    /// 参数说明:
    /// - path: 已解析的真实目标路径。
    /// - baseline: 文件存在时的真实证据，新建目标使用空值。
    /// - owner: 本次文档或文件动作的唯一身份。
    /// 返回：路径及其物理别名均未被其它动作持有时授予临时写入权。
    func reserveTarget(_ path: String, baseline: DiskBaseline? = nil, owner: UUID) -> Bool {
        // 只在主执行域授予路径与文件身份权限，检查与登记之间不能挂起。
        guard targetReservation(for: path, baseline: baseline, excluding: owner) == nil else {
            return false
        }
        let key = Data(path.utf8)
        targetReservations[key] = WorkspaceFileReservation(
            owner: owner,
            baseline: baseline ?? targetReservations[key]?.baseline
        )
        return true
    }

    /// 业务作用：动作完成后只释放自己持有的路径，不解除后来动作的权限。
    /// 参数说明:
    /// - path: 本次占用的真实路径。
    /// - owner: 原动作身份。
    /// 返回：匹配的临时权限被回收。
    func releaseTarget(_ path: String, owner: UUID) {
        let key = Data(path.utf8)
        if targetReservations[key]?.owner == owner {
            targetReservations.removeValue(forKey: key)
        }
    }
}
