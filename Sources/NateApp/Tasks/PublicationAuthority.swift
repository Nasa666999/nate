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

extension CancellationToken: FilePublicationScope {
    /// 业务作用：保存备份和原文件分别使用子权限，父请求取消时仍可观察已经进入的备份发布。
    /// 参数说明:
    /// - operation: 在独立子权限范围内完成的持久化动作。
    /// 返回：实际动作结果，子动作返回后才解除父请求中的在途登记。
    func withAuthority<Value>(_ operation: (any FilePublicationAuthority) throws -> Value) throws -> Value {
        try withChild {
            try operation($0)
        }
    }
}
