import Darwin
import Foundation

struct SpawnedCommand {
    let pid: pid_t
    let output: Int32
}

extension ProcessExecution {
    /// 业务作用：在 exec 之前建立独立进程组和描述符边界，避免程序在进程组建立前派生后代。
    /// 参数说明:
    /// - executable: 已确认的绝对程序路径。
    /// - arguments: 原始参数值。
    /// - directory: 仅对子程序生效的工作目录。
    /// 返回：本次进程组领导者与非阻塞输出描述符，失败时释放全部临时描述符。
    static func spawn(executable: String, arguments: [String], directory: URL?) throws -> SpawnedCommand {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
            arguments.count <= 4096,
            arguments.allSatisfy({
                !$0.utf8.contains(0)
            }),
            arguments.reduce(
                executable.utf8.count,
                {
                    $0 + $1.utf8.count
                }
            ) <= 1_048_576,
            directory?.isFileURL != false, directory?.path.utf8.contains(0) != true
        else {
            throw ExternalProcessFailure(reason: "程序路径、参数或工作目录无效，参数不得包含 NUL 或超过容量预算。")
        }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw failure("无法创建命令输出管道", errno)
        }
        var launched = false
        defer {
            Darwin.close(descriptors[1])
            if !launched {
                Darwin.close(descriptors[0])
            }
        }
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let duplicate = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
            guard duplicate >= 0 else {
                throw failure("无法隔离命令管道描述符", errno)
            }
            Darwin.close(descriptors[index])
            descriptors[index] = duplicate
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
            throw failure("无法设置命令管道", errno)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions), "无法准备命令描述符")
        defer {
            posix_spawn_file_actions_destroy(&actions)
        }
        try check(posix_spawnattr_init(&attributes), "无法准备命令属性")
        defer {
            posix_spawnattr_destroy(&attributes)
        }
        try check(
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            "无法设置命令输入"
        )
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO), "无法设置标准输出")
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO), "无法设置标准错误")
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[0]), "无法关闭子进程读取端")
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[1]), "无法关闭子进程重复输出端")
        if let directory {
            let result = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            try check(result, "无法设置命令工作目录")
        }
        var empty = sigset_t()
        sigemptyset(&empty)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] {
            sigaddset(&defaults, signal)
        }
        try check(posix_spawnattr_setsigmask(&attributes, &empty), "无法设置命令信号掩码")
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "无法设置命令信号规则")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "无法建立命令进程组")
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        try check(posix_spawnattr_setflags(&attributes, flags), "无法建立命令启动边界")
        var pid: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.sorted {
            $0.key < $1.key
        }.map {
            $0.key + "=" + $0.value
        }
        let result = try withStrings([executable] + arguments) {
            argv in
            try withStrings(environment) {
                env in
                posix_spawn(&pid, executable, &actions, &attributes, argv, env)
            }
        }
        try check(result, "无法启动外部命令")
        launched = true
        return SpawnedCommand(pid: pid, output: descriptors[0])
    }

    /// 业务作用：构建完整 NUL 终止的参数或环境数组，内存只在同步 spawn 调用期间存在。
    /// 参数说明:
    /// - values: 不含内嵌 NUL 的字符串。
    /// - body: 仅在缓冲有效期间调用系统入口。
    /// 返回：系统入口结果；任一分配失败则不启动命令。
    static func withStrings<T>(
        _ values: [String],
        body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        for value in values {
            guard let pointer = strdup(value) else {
                throw failure("无法分配命令参数", ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeBufferPointer {
            buffer in
            try body(buffer.baseAddress!)
        }
    }

    /// 业务作用：检查 posix_spawn 家族直接返回的错误码，不错误借用线程 errno。
    /// 参数说明:
    /// - code: 系统入口返回的错误码。
    /// - stage: 用户可理解的准备阶段。
    /// 返回：成功继续；失败保留实际系统原因。
    static func check(_ code: Int32, _ stage: String) throws {
        guard code == 0 else {
            throw failure(stage, code)
        }
    }
}
