import Darwin
import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var output: String
}

public enum ProcessExecution {
    /// 业务作用：同步执行结构化进程，两个输出流合并读取，避免管道互相阻塞。
    /// 参数说明:
    /// - executable: 用户确认的可执行绝对路径。
    /// - arguments: 按原值传递的数据参数。
    /// - directory: 可选工作目录。
    /// 返回：真实退出状态与有界输出；超限终止当前进程。
    public static func run(executable: String, arguments: [String], directory: URL?) throws -> ProcessOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        var output = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var terminated = false
        while true {
            if ContinuousClock.now >= deadline {
                process.terminate()
                terminated = true
                break
            }
            var pollfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = Darwin.poll(&pollfd, 1, 100)
            if result < 0 && errno == EINTR {
                continue
            }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count == 0 {
                    break
                }
                if count > 0 {
                    output.append(contentsOf: bytes.prefix(count))
                }
                if output.count > 8_388_608 {
                    process.terminate()
                    terminated = true
                    break
                }
            }
            else if !process.isRunning {
                break
            }
        }
        if terminated {
            let pid = process.processIdentifier
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
        process.waitUntilExit()
        if terminated {
            throw NSError(
                domain: "Nate.Process",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "外部命令超过 30 秒或 8 MB 输出预算，已终止。输出未写入正文。"]
            )
        }
        return ProcessOutput(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }
}
