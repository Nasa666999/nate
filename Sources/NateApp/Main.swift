import AppKit

@main
struct NateMain {
    /// 业务作用：启动原生应用事件循环，日常使用无需终端。
    /// 参数说明: 无。
    /// 返回：由 macOS 管理应用退出。
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print(CLIArguments.help)
            return
        }
        let application = NSApplication.shared
        let controller = ApplicationController()
        application.delegate = controller
        application.setActivationPolicy(.regular)
        withExtendedLifetime(controller) {
            application.run()
        }
    }
}
