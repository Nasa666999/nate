import Darwin
import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var output: String
}

public struct ExternalProcessFailure: Error, LocalizedError, Sendable {
    let reason: String
    public var errorDescription: String? {
        reason
    }
}

public enum ProcessExecution {
    /// 业务作用：结构化启动独立进程组，合并两个输出流并在取消或超限时收束整个命令组。
    /// 参数说明:
    /// - executable: 用户确认的可执行绝对路径，不经过 shell 解释。
    /// - arguments: 保持原值的参数数组，拒绝含 NUL 的参数。
    /// - directory: 可选工作目录，只作用于子进程。
    /// - timeout: 本次命令的最长执行时间，默认 30 秒。
    /// - maximumOutputBytes: 合并标准输出与错误的总字节预算，默认 8 MB。
    /// - isCancelled: 后台命令的显式取消权限。
    /// 返回：正常退出码或 128 加终止信号，以及严格 UTF-8 输出；失败不发布部分输出。
    public static func run(
        executable: String,
        arguments: [String],
        directory: URL?,
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 8_388_608,
        isCancelled: @Sendable () -> Bool = {
            false
        }
    ) throws -> ProcessOutput {
        guard timeout > .zero, timeout <= .seconds(3600), maximumOutputBytes > 0,
            maximumOutputBytes <= 67_108_864
        else {
            throw ExternalProcessFailure(reason: "外部命令的时间或输出预算无效。")
        }
        if isCancelled() {
            throw CancellationError()
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let child = try spawn(executable: executable, arguments: arguments, directory: directory)
        var reaped = false
        defer {
            Darwin.close(child.output)
            if !reaped {
                // 领导进程尚未回收时其 PID 仍被保留，负 PID 只指向本次创建的进程组。
                _ = Darwin.kill(-child.pid, SIGKILL)
                reapLater(child.pid)
            }
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var eof = false
        var exit: siginfo_t?
        while true {
            // 取消和预算在每次非阻塞读取前复验，持续输出不能绕过时间限制。
            if isCancelled() {
                throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
                throw ExternalProcessFailure(reason: "外部命令超过执行时间预算，已请求终止进程组，输出未写入正文。")
            }
            if exit == nil {
                exit = try observeExit(child.pid)
            }
            if eof && exit != nil {
                break
            }
            var descriptor = pollfd(fd: eof ? -1 : child.output, events: Int16(POLLIN | POLLHUP), revents: 0)
            let available = Darwin.poll(&descriptor, 1, 50)
            if available < 0 {
                if errno == EINTR {
                    continue
                }
                throw failure("无法等待外部命令输出", errno)
            }
            if available > 0 {
                let read = Darwin.read(child.output, &buffer, buffer.count)
                if read == 0 {
                    eof = true
                }
                else if read > 0 {
                    guard read <= maximumOutputBytes - output.count else {
                        throw ExternalProcessFailure(reason: "外部命令超过输出字节预算，已请求终止进程组，输出未写入正文。")
                    }
                    output.append(contentsOf: buffer.prefix(read))
                }
                else if errno != EINTR && errno != EAGAIN {
                    throw failure("无法读取外部命令输出", errno)
                }
            }
        }
        // 输出已结束仍可能存在关闭了输出描述符的后代；命令边界结束时不留下未登记的同组进程。
        _ = Darwin.kill(-child.pid, SIGKILL)
        try reap(child.pid)
        reaped = true
        let text = String(decoding: output, as: UTF8.self)
        // 输出中的前导 U+FEFF 是子进程原文，只有完整回编码一致后才能交给调用者。
        guard let exit, text.utf8.elementsEqual(output) else {
            throw ExternalProcessFailure(reason: "外部命令输出不是有效 UTF-8，未以替代字符改写内容。")
        }
        let status = exit.si_code == CLD_EXITED ? exit.si_status : 128 + exit.si_status
        return ProcessOutput(status: status, output: text)
    }

    /// 业务作用：观察退出但暂不回收领导进程，直到输出与进程组收束都已经确定。
    /// 参数说明:
    /// - pid: 本次创建的领导进程。
    /// 返回：退出证据；仍在运行时为空，系统错误明确失败。
    static func observeExit(_ pid: pid_t) throws -> siginfo_t? {
        var information = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if result < 0 {
            if errno == EINTR {
                return nil
            }
            throw failure("无法观察外部命令退出", errno)
        }
        return information.si_pid == pid ? information : nil
    }

    /// 业务作用：回收已经确认退出的直接子进程，不遗留僵尸进程。
    /// 参数说明:
    /// - pid: 仍由本命令持有的直接子进程身份。
    /// 返回：系统完成回收；中断重试，其他错误失败。
    static func reap(_ pid: pid_t) throws {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR {
                throw failure("无法回收外部命令", errno)
            }
        }
    }

    /// 业务作用：终止请求后在独立队列等待系统回收，不用阻塞命令调用者或保存队列。
    /// 参数说明:
    /// - pid: 尚未回收且已请求 SIGKILL 的直接子进程。
    /// 返回：仅安排回收，不冒称系统已完成进程退出。
    static func reapLater(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            try? reap(pid)
        }
    }

    /// 业务作用：保留外部命令启动、管道与退出阶段的系统失败原因。
    /// 参数说明:
    /// - stage: 当前执行阶段。
    /// - code: 系统返回的错误码。
    /// 返回：不包含参数或环境内容的可展示错误。
    static func failure(_ stage: String, _ code: Int32) -> ExternalProcessFailure {
        ExternalProcessFailure(reason: stage + "：" + String(cString: strerror(code)))
    }
}
