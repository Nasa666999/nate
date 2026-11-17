import Foundation
import NatePlatform
import NateStorage

struct WorkspaceFileCoordinator: FileCoordinating {
    /// 业务作用：将存储读取协议适配到平台同步协调，平台模块不反向引用存储。
    /// 参数说明:
    /// - url: 原请求目标。
    /// - permit: 请求权限。
    /// - operation: 协调范围内同步读取动作。
    /// 返回：平台协调和完整读取的真实结果。
    func read<Value: Sendable>(
        at url: URL,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value {
        try PlatformFileCoordinator.read(at: url, permit: permit, operation: operation)
    }

    /// 业务作用：把实际文件动作语义转换为系统协调标记，普通保存仍是同一文档的内容更新。
    /// 参数说明:
    /// - url: 原请求目标。
    /// - intent: 更新、另存替换或删除。
    /// - permit: 请求权限。
    /// - operation: 同步完成的文件动作。
    /// 返回：完整动作结果，协调错误不转为成功。
    func write<Value: Sendable>(
        at url: URL,
        intent: FileWriteIntent,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value {
        let options: NSFileCoordinator.WritingOptions
        switch intent {
        case .updating: options = []
        case .replacing: options = .forReplacing
        case .deleting: options = .forDeleting
        }
        return try PlatformFileCoordinator.write(
            at: url,
            options: options,
            permit: permit,
            operation: operation
        )
    }

    /// 业务作用：移动源和目标由同一平台协调上下文授予访问权。
    /// 参数说明:
    /// - source: 源路径。
    /// - destination: 目标路径。
    /// - permit: 请求权限。
    /// - operation: 同步移动及证据确认动作。
    /// 返回：完整移动结果或实际失败。
    func move<Value: Sendable>(
        from source: URL,
        to destination: URL,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL, URL) throws -> Value
    ) throws -> Value {
        try PlatformFileCoordinator.move(from: source, to: destination, permit: permit, operation: operation)
    }
}
