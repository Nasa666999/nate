import Foundation
import NateCore

public enum FileWriteIntent: Sendable {
    case updating
    case replacing
    case deleting
}

public protocol FileCoordinating: Sendable {
    /// 业务作用：在平台读协调的同步访问范围内执行完整只读动作。
    /// 参数说明:
    /// - url: 原请求目标。
    /// - permit: 等待和访问前仍有效的请求权限。
    /// - operation: 只在授权访问范围内同步执行的动作。
    /// 返回：完整只读结果；协调、取消或访问失败均抛错。
    func read<Value: Sendable>(
        at url: URL,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value

    /// 业务作用：为内容更新、另存替换或删除建立对应平台写协调。
    /// 参数说明:
    /// - url: 原请求目标。
    /// - intent: 该动作对已有文档的实际意义。
    /// - permit: 发布前仍有效的请求权限。
    /// - operation: 协调范围内同步执行的完整动作。
    /// 返回：完整动作结果；平台访问权不替代正文和磁盘证据复验。
    func write<Value: Sendable>(
        at url: URL,
        intent: FileWriteIntent,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL) throws -> Value
    ) throws -> Value

    /// 业务作用：同时取得移动源和目标的协调访问，防止只锁住其中一个路径。
    /// 参数说明:
    /// - source: 原请求源路径。
    /// - destination: 用户确认的新路径。
    /// - permit: 动作前仍有效的请求权限。
    /// - operation: 同步执行移动及结果确认的动作。
    /// 返回：完整移动结果；任一目标失效时不执行动作。
    func move<Value: Sendable>(
        from source: URL,
        to destination: URL,
        permit: @escaping @Sendable () -> Bool,
        operation: (URL, URL) throws -> Value
    ) throws -> Value
}

public struct CoordinatedFileAccess: Sendable {
    let coordinator: any FileCoordinating

    /// 业务作用：由应用装配平台协调，实现存储模块对 macOS 机制的单向依赖。
    /// 参数说明:
    /// - coordinator: 线程安全的平台适配器。
    /// 返回：不可变文件访问入口，后台请求分别建立自己的协调上下文。
    public init(coordinator: any FileCoordinating) {
        self.coordinator = coordinator
    }

    /// 业务作用：在同一协调和文件证据范围内读取原始资源字节，解析后可沿用其真实基线。
    /// 参数说明:
    /// - url: 原请求目标。
    /// - maximumBytes: 文件读取的字节预算。
    /// - permit: 请求权限。
    /// 返回：完整字节和精确保存基线；超限时不分配完整正文。
    public func readData(
        _ url: URL,
        maximumBytes: Int = Int.max,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> FileByteSnapshot {
        try coordinator.read(at: url, permit: permit) {
            coordinated in
            try validate(coordinated, requested: url, permit: permit)
            return try FileStorage.readData(url, maximumBytes: maximumBytes, permit: permit)
        }
    }

    /// 业务作用：为只读样本或元数据访问提供协调范围，结果不授予原文件写入权。
    /// 参数说明:
    /// - url: 原请求目标。
    /// - permit: 请求权限。
    /// - operation: 在授权范围内同步执行的只读动作。
    /// 返回：完整只读结果，目标改向或取消时不执行。
    public func withRead<Value: Sendable>(
        at url: URL,
        permit: @escaping @Sendable () -> Bool = {
            true
        },
        operation: (URL) throws -> Value
    ) throws -> Value {
        try coordinator.read(at: url, permit: permit) {
            coordinated in
            try validate(coordinated, requested: url, permit: permit)
            return try operation(coordinated)
        }
    }

    /// 业务作用：在完整读协调内载入字节和基线，避免协调结束后才开始读取。
    /// 参数说明:
    /// - url: 用户请求打开的文件。
    /// - encoding: 明确指定的解释方式。
    /// - catalog: 严格传统代码页映射。
    /// - maximumBytes: 同一描述符读取的原字节上限。
    /// - permit: 请求等待与读取的取消权限。
    /// 返回：与原目标一致的完整载入；协调期间移动目标时要求重新打开。
    public func load(
        _ url: URL,
        encoding: TextEncoding? = nil,
        catalog: LegacyCodecCatalog? = nil,
        maximumBytes: Int = Int.max,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> LoadedFile {
        try coordinator.read(at: url, permit: permit) {
            coordinated in
            try validate(coordinated, requested: url, permit: permit)
            return try FileStorage.load(
                url,
                encoding: encoding,
                catalog: catalog,
                maximumBytes: maximumBytes,
                permit: permit
            )
        }
    }

    /// 业务作用：在协调范围内取得完整文件证据，证据读取仍受请求取消约束。
    /// 参数说明:
    /// - url: 待观察文件。
    /// - permit: 请求权限。
    /// 返回：当前完整基线；目标移动、读取变化或取消时失败。
    public func baseline(
        _ url: URL,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        try coordinator.read(at: url, permit: permit) {
            coordinated in
            try validate(coordinated, requested: url, permit: permit)
            return try FileStorage.baseline(url, permit: permit)
        }
    }

    /// 业务作用：把严格文件发布放在写协调内，内容更新与另存替换使用不同的系统意图。
    /// 参数说明:
    /// - data: 已编码字节。
    /// - url: 用户确认的目标。
    /// - expected: 必须仍匹配的磁盘证据。
    /// - replacing: 是否以另一个文档替换目标，而非更新同一文档内容。
    /// - backup: 覆盖前必须完成的原字节备份，为空时不额外保存历史。
    /// - permit: 发布前必须有效的动作权限。
    /// - authority: 单次发布权。
    /// - observe: 协调与持久化阶段的实际观察入口。
    /// 返回：文件和目录同步后确认的真实保存点。
    public func save(
        _ data: Data,
        to url: URL,
        expected: DiskBaseline?,
        replacing: Bool = false,
        backup: SaveBackupRequest? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        },
        authority: (any FilePublicationAuthority)? = nil,
        observe: FileSaveObservation = {
            _ in
        }
    ) throws -> DiskBaseline {
        observe(.waitingForAccess)
        return try coordinator.write(at: url, intent: replacing ? .replacing : .updating, permit: permit) {
            coordinated in
            try validate(coordinated, requested: url, permit: permit)
            if let backup, let expected {
                observe(.preservingBackup)
                do {
                    try backup.store.preserve(
                        url,
                        expected: expected,
                        policy: backup.policy,
                        authority: backup.authority,
                        permit: permit
                    )
                }
                catch is CancellationError {
                    throw CancellationError()
                }
                catch {
                    throw NateError.message("保存前备份未完成，原文件未覆盖：" + error.localizedDescription)
                }
            }
            return try FileStorage.save(
                data,
                to: url,
                expected: expected,
                permit: permit,
                authority: authority,
                observe: observe
            )
        }
    }

    /// 业务作用：为需要单次写协调的元数据或删除动作提供明确访问范围。
    /// 参数说明:
    /// - url: 用户确认的原目标。
    /// - intent: 更新、替换或删除语义。
    /// - permit: 动作权限。
    /// - operation: 同步完成的动作，不能把文件访问派发到协调范围外。
    /// 返回：实际动作结果，协调期间目标改变时不执行。
    public func withWrite<Value: Sendable>(
        at url: URL,
        intent: FileWriteIntent,
        permit: @escaping @Sendable () -> Bool = {
            true
        },
        operation: (URL) throws -> Value
    ) throws -> Value {
        try coordinator.write(at: url, intent: intent, permit: permit) {
            coordinated in
            try validate(coordinated, requested: url, permit: permit)
            return try operation(coordinated)
        }
    }

    /// 业务作用：源和目标共同取得协调后同步完成移动与证据确认。
    /// 参数说明:
    /// - source: 原路径。
    /// - destination: 新路径。
    /// - permit: 动作权限。
    /// - operation: 同步完成的移动动作。
    /// 返回：完整移动结果，任一路径被改向时不执行。
    public func withMove<Value: Sendable>(
        from source: URL,
        to destination: URL,
        permit: @escaping @Sendable () -> Bool = {
            true
        },
        operation: (URL, URL) throws -> Value
    ) throws -> Value {
        try coordinator.move(from: source, to: destination, permit: permit) {
            currentSource,
            currentDestination in
            try validate(currentSource, requested: source, permit: permit)
            try validate(currentDestination, requested: destination, permit: permit)
            return try operation(currentSource, currentDestination)
        }
    }

    /// 业务作用：系统访问权不授予新路径写入权，目标被移动时不能沿更新 URL 默默改绑。
    /// 参数说明:
    /// - coordinated: 平台授予访问的实际目标。
    /// - requested: 已有文档绑定或用户确认的目标。
    /// - permit: 当前请求权限。
    /// 返回：目标身份路径仍一致时继续，取消或改向均在副作用前拒绝。
    func validate(_ coordinated: URL, requested: URL, permit: @Sendable () -> Bool) throws {
        // 等待期间可能已经失去请求权限，系统回调本身不能授权迟到的文件动作。
        guard permit() else {
            throw CancellationError()
        }
        guard
            coordinated.resolvingSymlinksInPath().standardizedFileURL
                == requested.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw NateError.message("文件在协调等待期间被移动或改向，请重新打开并确认目标。")
        }
    }
}
