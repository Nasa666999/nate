import NateStorage

extension CancellationToken: FilePublicationAuthority {
    /// 业务作用：把应用的取消与单次动作令牌适配到存储发布边界，存储不依赖应用任务实现。
    /// 参数说明:
    /// - operation: 取得权威后执行的原子文件动作。
    /// 返回：动作真实结果；旧令牌不授予新的发布权。
    func publish(_ operation: () throws -> Void) throws {
        try withPublication(operation)
    }
}
