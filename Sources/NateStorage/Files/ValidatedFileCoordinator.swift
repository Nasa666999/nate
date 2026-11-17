import Foundation

struct ValidatedFileCoordinator: FileCoordinating {
    let base: any FileCoordinating

    /// 业务作用：在平台开始协调之前验证原请求，平台回调也不能带入无效文件 URL。
    /// 参数说明:
    /// - url: 原始文件目标。
    /// - permit: 协调等待和回调期间仍有效的调用权。
    /// - operation: 仅在合法协调范围内执行的只读动作。
    /// 返回：完整读取结果；无效路径和失权都不进入内容动作。
    func read<Value: Sendable>(
        at url: URL,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value {
        try check(url, permit: permit)
        return try base.read(at: url, permit: permit) {
            coordinated in
            try check(coordinated, permit: permit)
            return try operation(coordinated)
        }
    }

    /// 业务作用：无效写入目标在取得平台访问范围之前失败，回调不能重新授予错误路径内容发布权。
    /// 参数说明:
    /// - url: 原始写入目标。
    /// - intent: 更新、替换或删除语义。
    /// - permit: 发布前仍有效的调用权。
    /// - operation: 协调范围内的完整动作。
    /// 返回：实际动作结果；无效路径不进入写入回调。
    func write<Value: Sendable>(
        at url: URL,
        intent: FileWriteIntent,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value {
        try check(url, permit: permit)
        return try base.write(at: url, intent: intent, permit: permit) {
            coordinated in
            try check(coordinated, permit: permit)
            return try operation(coordinated)
        }
    }

    /// 业务作用：移动源、目标及平台返回路径全部合法后才允许执行双目标动作。
    /// 参数说明:
    /// - source: 原始源路径。
    /// - destination: 用户确认的目标路径。
    /// - permit: 整个动作的调用权。
    /// - operation: 同一协调范围内执行的移动。
    /// 返回：完整移动结果；任一路径无效时不执行动作。
    func move<Value: Sendable>(
        from source: URL,
        to destination: URL,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL, URL) throws -> Value
    ) throws -> Value {
        try check(source, permit: permit)
        try check(destination, permit: permit)
        return try base.move(from: source, to: destination, permit: permit) {
            currentSource,
            currentDestination in
            try check(currentSource, permit: permit)
            try check(currentDestination, permit: permit)
            return try operation(currentSource, currentDestination)
        }
    }

    /// 业务作用：先复验调用权，再检查原始 URL，已撤销请求不借路径处理重新开始访问。
    /// 参数说明:
    /// - url: 当前阶段仍未规范化的文件目标。
    /// - permit: 原动作的显式权限。
    /// 返回：权限和文件 URL 都有效时继续，否则在平台动作或内容回调前失败。
    private func check(_ url: URL, permit: @Sendable () -> Bool) throws {
        // 平台协调和内容动作是不同阶段，两处都必须持有原请求的有效权限。
        guard permit() else {
            throw CancellationError()
        }
        try FileStorage.validateFileURL(url)
    }
}
