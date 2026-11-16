import Foundation

extension ApplicationController {
    /// 业务作用：目标尚未绑定标签时先占有路径，避免另存为与跨文件替换产生第二个写入者。
    /// 参数说明:
    /// - path: 已解析的真实目标路径。
    /// - owner: 本次文档或文件动作的唯一身份。
    /// 返回：没有其他动作持有目标时授予本次临时写入权。
    func reserveTarget(_ path: String, owner: UUID) -> Bool {
        // 只在主执行域授予路径权限，检查与登记之间不能挂起。
        guard targetReservations[path] == nil || targetReservations[path] == owner else {
            return false
        }
        targetReservations[path] = owner
        return true
    }

    /// 业务作用：动作完成后只释放自己持有的路径，不解除后来动作的权限。
    /// 参数说明:
    /// - path: 本次占用的真实路径。
    /// - owner: 原动作身份。
    /// 返回：匹配的临时权限被回收。
    func releaseTarget(_ path: String, owner: UUID) {
        if targetReservations[path] == owner {
            targetReservations.removeValue(forKey: path)
        }
    }
}
