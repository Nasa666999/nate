import Darwin
import Foundation
import NateCore

public struct DirectoryEntry: Sendable, Equatable {
    public let url: URL
    public let isDirectory: Bool
}

public struct DirectoryStamp: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
}

public struct DirectoryContents: Sendable {
    public let entries: [DirectoryEntry]
    public let stamp: DirectoryStamp

    /// 业务作用：按需读取目录树的一层，不展开子目录、符号链接、隐藏项或应用包。
    /// 参数说明:
    /// - root: 用户明确选择的工作区根目录。
    /// - directory: 根目录自身或从根逐层展开的子目录。
    /// - limit: 这一层允许展示的完整条目上限。
    /// - permit: 原请求是否仍拥有读取资格。
    /// 返回：稳定目录状态下的完整一层；权限失败、目录变化、取消或超限不返回部分清单。
    public static func read(
        root: URL,
        directory: URL,
        limit: Int = 2000,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DirectoryContents {
        guard limit > 0, limit <= 20_000 else {
            throw NateError.message("目录条目上限必须介于 1 与 20000。")
        }
        try check(permit)
        let descriptor = try openDirectory(root: root, directory: directory, permit: permit)
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw failure("无法枚举目录")
        }
        defer {
            closedir(stream)
        }
        let initial = try stamp(descriptor)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var entries: [DirectoryEntry] = []
        while true {
            try checkpoint(permit, deadline: deadline)
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw failure("目录枚举未完成")
                }
                break
            }
            var rawName = entry.pointee.d_name
            let name = withUnsafePointer(to: &rawName) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw NateError.message("目录包含无法无损显示为 UTF-8 的文件名，未发布部分清单。")
            }
            if name.hasPrefix(".") {
                continue
            }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw failure("无法读取目录项 \(name)")
            }
            let kind = metadata.st_mode & S_IFMT
            if kind != S_IFREG && kind != S_IFDIR || metadata.st_flags & UInt32(UF_HIDDEN) != 0 {
                continue
            }
            let isDirectory = kind == S_IFDIR
            let url = directory.standardizedFileURL.appendingPathComponent(name, isDirectory: isDirectory)
            if isDirectory, try url.resourceValues(forKeys: [.isPackageKey]).isPackage == true {
                continue
            }
            entries.append(
                DirectoryEntry(
                    url: url,
                    isDirectory: isDirectory
                )
            )
            guard entries.count <= limit else {
                throw NateError.message("目录单层超过 \(limit) 项，未发布部分清单。")
            }
        }
        try check(permit)
        // 枚举期间的增删或替换会使完整性证据失效，不能把竞争形成的混合清单显示为完整目录。
        guard initial == (try stamp(descriptor)),
            initial == (try observe(root: root, directory: directory, permit: permit))
        else {
            throw NateError.message("目录在读取期间发生变化，请刷新。")
        }
        let sorted = try entries.sorted {
            try checkpoint(permit, deadline: deadline)
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
        try checkpoint(permit, deadline: deadline)
        // 自然排序也跨越了计算时间，发布前再次核对路径身份，不能显示排序期间被替换的旧目录。
        guard initial == (try observe(root: root, directory: directory, permit: permit)) else {
            throw NateError.message("目录在读取期间发生变化，请刷新。")
        }
        return DirectoryContents(
            entries: sorted,
            stamp: initial
        )
    }

    /// 业务作用：只观察目录身份与纳秒状态时间，轮询不重复分配已展示的文件清单。
    /// 参数说明:
    /// - root: 当前明确选择的根目录。
    /// - directory: 已经展开过的目录。
    /// - permit: 当前观察资格。
    /// 返回：目录轻量标记；路径越界、被替换为链接或不可读取时失败。
    public static func observe(
        root: URL,
        directory: URL,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DirectoryStamp {
        try check(permit)
        let descriptor = try openDirectory(root: root, directory: directory)
        defer {
            close(descriptor)
        }
        let value = try stamp(descriptor)
        try check(permit)
        return value
    }

    /// 业务作用：逐段沿已打开目录取得后代读取权，路径中的链接不能把展开动作引向根目录之外。
    /// 参数说明:
    /// - root: 原始根 URL，先校验再标准化。
    /// - directory: 原始目标 URL。
    /// - permit: 逐段访问期间仍有效的资格。
    /// 返回：调用者负责关闭的目录描述符；越界、链接和权限变化均拒绝。
    static func openDirectory(
        root: URL,
        directory: URL,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> Int32 {
        try check(permit)
        try FileStorage.validateFileURL(root)
        try FileStorage.validateFileURL(directory)
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let sameDirectory = directory.path.utf8.elementsEqual(root.path.utf8)
        let pathBytes = Array(directory.path.utf8)
        let prefixBytes = Array(prefix.utf8)
        // 共同字符串前缀不足以授权后代路径，必须满足完整目录边界。
        guard sameDirectory || pathBytes.starts(with: prefixBytes) else {
            throw NateError.message("目录不属于当前工作区根路径。")
        }
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw failure("无法打开工作区根目录")
        }
        do {
            if !sameDirectory {
                let relative = String(decoding: pathBytes.dropFirst(prefixBytes.count), as: UTF8.self)
                for component in relative.split(separator: "/") {
                    try check(permit)
                    // O_NOFOLLOW 逐层禁止链接，根之外的新目标不能因路径替换取得读取资格。
                    let next = openat(
                        descriptor,
                        String(component),
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    guard next >= 0 else {
                        throw failure("子目录已改变或无法读取")
                    }
                    close(descriptor)
                    descriptor = next
                }
            }
            try check(permit)
            return descriptor
        }
        catch {
            close(descriptor)
            throw error
        }
    }

    /// 业务作用：从同一已授权目录描述符读取身份，避免重新解析字符串路径取得另一对象的标记。
    /// 参数说明:
    /// - descriptor: 已打开的目录描述符。
    /// 返回：当前目录状态；描述符失效或对象类型不同则失败。
    private static func stamp(_ descriptor: Int32) throws -> DirectoryStamp {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw failure("无法观察目录")
        }
        return DirectoryStamp(
            device: value.st_dev,
            inode: value.st_ino,
            modifiedSeconds: value.st_mtimespec.tv_sec,
            modifiedNanos: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec,
            changedNanos: value.st_ctimespec.tv_nsec
        )
    }

    /// 业务作用：实际文件读取前复验显式取消资格，队列任务不依赖继承的 Swift Task 上下文。
    /// 参数说明:
    /// - permit: 当前请求许可。
    /// 返回：有效时继续，失权时立即以取消结束。
    private static func check(_ permit: @Sendable () -> Bool) throws {
        guard permit() else {
            throw CancellationError()
        }
    }

    /// 业务作用：枚举与自然排序共用实际计算截止，排序也不能在取消后持续占用目录工作线程。
    /// 参数说明:
    /// - permit: 当前请求许可。
    /// - deadline: 本层计算的共同截止时刻。
    /// 返回：仍获准且未超时则继续，否则明确取消或失败，不发布部分条目。
    private static func checkpoint(_ permit: @Sendable () -> Bool, deadline: ContinuousClock.Instant) throws {
        try check(permit)
        guard ContinuousClock.now < deadline else {
            throw NateError.message("目录单层枚举与排序超过 5 秒，请缩小目录范围。")
        }
    }

    /// 业务作用：把目录系统调用的当前失败原因交给界面，读取失败不能显示为成功的空目录。
    /// 参数说明:
    /// - operation: 当前失败的目录业务步骤。
    /// 返回：保留系统失败原因的可读错误。
    private static func failure(_ operation: String) -> NateError {
        NateError.message(operation + "：" + String(cString: strerror(errno)))
    }
}
