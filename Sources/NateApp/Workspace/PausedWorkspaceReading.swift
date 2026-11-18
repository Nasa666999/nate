import Foundation
import NateCore
import NateStorage

struct PausedWorkspacePayload: Sendable {
    let documents: [RecoveredSnapshot]
    let active: UUID?
    let sidebars: SidebarRecoveryState?
}

enum PausedWorkspaceReading {
    /// 业务作用：逐项枚举先前保留目录，不递归读取正文或把符号链接目录当成可恢复入口。
    /// 参数说明:
    /// - support: 当前应用数据根目录。
    /// - permit: 本次列举仍有效的读取资格。
    /// 返回：最多一千个有合法身份的保留目录；超过一万项根目录条目、读取失败或失权整体失败。
    static func choices(in support: URL, permit: @Sendable () -> Bool) throws -> [URL] {
        try FileStorage.validateFileURL(support)
        let root = support.resolvingSymlinksInPath().standardizedFileURL
        var failure: (any Error)?
        guard
            let entries = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: {
                    _,
                    error in
                    failure = error
                    return false
                }
            )
        else {
            throw NateError.message("应用数据目录无法列举，原保留记录未改变。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var count = 0
        var choices: [URL] = []
        for case let url as URL in entries {
            guard permit(), !Task.isCancelled else {
                throw CancellationError()
            }
            count += 1
            guard count <= 10_000, ContinuousClock.now < deadline else {
                throw NateError.message("应用数据目录条目超过一万项或列举超过五秒，未展示部分保留清单。")
            }
            guard validName(url.lastPathComponent) else {
                continue
            }
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if attributes.isDirectory == true && attributes.isSymbolicLink != true {
                choices.append(url)
                guard choices.count <= 1000 else {
                    throw NateError.message("先前保留工作区超过一千份，请先整理保留目录。")
                }
            }
        }
        if let failure {
            throw failure
        }
        return choices.sorted {
            $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
        }
    }

    /// 业务作用：固定用户选择的普通保留目录，目录改向不能借初始化解析转为另一处恢复权限。
    /// 参数说明:
    /// - directory: 清单中由用户明确选择的原目录。
    /// 返回：路径未改向的恢复读取器；链接、未知命名或非目录均拒绝，不创建任何目录。
    static func store(at directory: URL) throws -> RecoveryStore {
        try FileStorage.validateFileURL(directory)
        let original = directory.standardizedFileURL
        let store = RecoveryStore(directory: original)
        let attributes = try original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard validName(original.lastPathComponent), attributes.isDirectory == true,
            attributes.isSymbolicLink != true,
            store.directory.path.utf8.elementsEqual(original.path.utf8)
        else {
            throw NateError.message("先前保留目录已改变或被链接代替，未读取其它位置。")
        }
        return store
    }

    /// 业务作用：仅按最终选择读取完整正文，侧栏只作为已验证纯数据携带，原恢复记录保持只读。
    /// 参数说明:
    /// - directory: 用户选择的固定保留目录。
    /// - includeDocuments: 是否读取完整正文与活动身份，为假时不解析正文依赖。
    /// - sidebars: 用户明确选择恢复的完整侧栏，没有选择时为空。
    /// - remainingBytes: 当前工作区可接收的正文总字节数。
    /// - remainingDocuments: 当前工作区可接收的文档数。
    /// - permit: 当前导入仍有效的执行资格。
    /// 返回：完整不可变导入内容；取消、目录改变或正文依赖无效时失败，不返回部分文档。
    static func read(
        _ directory: URL,
        includeDocuments: Bool,
        sidebars: SidebarRecoveryState?,
        remainingBytes: Int,
        remainingDocuments: Int,
        permit: @Sendable () -> Bool
    ) throws -> PausedWorkspacePayload {
        guard permit(), !Task.isCancelled else {
            throw CancellationError()
        }
        let store = try store(at: directory)
        try sidebars?.validate()
        let restored =
            try includeDocuments
            ? store.restoreSnapshots(
                maximumWorkspaceBytes: remainingBytes,
                maximumDocuments: remainingDocuments,
                permit: permit
            ) : (documents: [], active: nil)
        guard permit(), !Task.isCancelled else {
            throw CancellationError()
        }
        _ = try Self.store(at: directory)
        return PausedWorkspacePayload(
            documents: restored.documents,
            active: restored.active,
            sidebars: sidebars
        )
    }

    /// 业务作用：保留目录只接受应用生成的独立身份，不把相似前缀的用户目录自动列为恢复内容。
    /// 参数说明:
    /// - name: 根目录条目的完整名称。
    /// 返回：固定前缀与完整 UUID 同时有效时为真。
    private static func validName(_ name: String) -> Bool {
        name.hasPrefix("Recovery-paused-")
            && UUID(uuidString: String(name.dropFirst("Recovery-paused-".count))) != nil
    }
}
