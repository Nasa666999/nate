import Foundation
import NateCore

extension RecoveryStore {
    /// 业务作用：从同一恢复目录读取独立窗口布局，损坏布局不能遮蔽正文索引。
    /// 参数说明:
    /// - permit: 当前读取仍有执行资格。
    /// 返回：完整窗口布局与同次文件基线，首次缺席返回空，异常保留原文件并报告原因。
    public func restoreWindowLayout(
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> (layout: WindowSessionLayout, baseline: DiskBaseline)? {
        try FileStorage.validateFileURL(directory)
        let url = directory.appendingPathComponent("windows.json")
        guard try recoveryFileExists(url) else {
            return nil
        }
        let source = try readRecoveryFile(url, maximumBytes: WindowSessionLayout.maximumBytes, permit: permit)
        let layout = try JSONDecoder().decode(WindowSessionLayout.self, from: source.data)
        try layout.validate()
        guard permit() else {
            throw CancellationError()
        }
        return (layout, source.baseline)
    }

    /// 业务作用：单独确认窗口布局保存点，不能由迟到写入覆盖后来变化或失联的原布局。
    /// 参数说明:
    /// - layout: 当前完整窗口和分屏状态。
    /// - expected: 上次确认的磁盘基线，首次建立时为空。
    /// - permit: 本次写入的执行资格。
    /// 返回：容量、原来源与整体写入均确认时交付真实保存点，否则保留原布局。
    public func publishWindowLayout(
        _ layout: WindowSessionLayout,
        expected: DiskBaseline?,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws -> DiskBaseline {
        try layout.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(layout)
        guard data.count <= WindowSessionLayout.maximumBytes else {
            throw NateError.message("窗口布局归档超过 8 MiB。")
        }
        return try withStorageWrite(permit: permit) {
            store in
            // 原基线随同容量和目录权限一起复验，不能借正文恢复目录存在就替换后来布局。
            try store.saveRecoveryData(
                data,
                to: store.directory.appendingPathComponent("windows.json"),
                expected: expected,
                permit: permit
            )
        }
    }
}
