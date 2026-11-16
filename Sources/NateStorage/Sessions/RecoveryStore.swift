import Foundation
import NateCore

public struct RecoveryDocument: Sendable, Codable {
    public var id: UUID
    public var revision: UInt64
    public var name: String
    public var text: String
    public var path: String?
    public var encoding: TextEncoding
    public var baseline: DiskBaseline?
    public var language: String
    public var selections: [TextSelection]
    public var bookmarks: Set<Int>
    public var readOnly: Bool
    public var lineEnding: LineEnding?

    /// 业务作用：固定已提交正文及恢复所需元数据，不包含输入法预编辑。
    /// 参数说明:
    /// - id: 稳定文档身份。
    /// - revision: 本次快照修订。
    /// - name: 标签名称。
    /// - text: 已提交正文。
    /// - path: 原目标，可为空。
    /// - encoding: 原路径保存参数。
    /// - baseline: 恢复后覆盖前必须复验的磁盘证据。
    /// - language: 文档语言标识。
    /// - selections: 完整选区。
    /// - bookmarks: 书签行。
    /// - readOnly: 编辑器只读状态。
    /// - lineEnding: 新插入换行的规则，旧记录可为空。
    /// 返回：可校验、独立于原路径的恢复内容。
    public init(
        id: UUID,
        revision: UInt64,
        name: String,
        text: String,
        path: String?,
        encoding: TextEncoding,
        baseline: DiskBaseline?,
        language: String,
        selections: [TextSelection],
        bookmarks: Set<Int>,
        readOnly: Bool,
        lineEnding: LineEnding? = nil
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.text = text
        self.path = path
        self.encoding = encoding
        self.baseline = baseline
        self.language = language
        self.selections = selections
        self.bookmarks = bookmarks
        self.readOnly = readOnly
        self.lineEnding = lineEnding
    }
}

public struct RecoveryReference: Sendable, Codable {
    public var id: UUID
    public var file: String
    public var checksum: String
    public var name: String?
}

struct RecoveryIndex: Codable {
    var format = 1
    var active: UUID?
    var documents: [RecoveryReference]
}

public struct RecoveryStore: Sendable {
    public let directory: URL

    /// 业务作用：将恢复内容固定到可写的用户数据目录。
    /// 参数说明:
    /// - directory: 本实例专属恢复目录。
    /// 返回：不依赖应用包位置的恢复存储。
    public init(directory: URL) {
        self.directory = directory
    }

    /// 业务作用：先持久化正文快照，索引可靠发布前不删除旧内容。
    /// 参数说明:
    /// - document: 已提交文档快照。
    /// 返回：已同步且可验证的索引引用。
    public func checkpoint(_ document: RecoveryDocument) throws -> RecoveryReference {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(document)
        let filename = document.id.uuidString + "-" + UUID().uuidString + ".json"
        _ = try FileStorage.save(data, to: directory.appendingPathComponent(filename), expected: nil)
        return RecoveryReference(
            id: document.id,
            file: filename,
            checksum: FileStorage.digest(data),
            name: document.name
        )
    }

    /// 业务作用：可靠更新打开文档清单，关闭的文档不在下一次启动复活。
    /// 参数说明:
    /// - references: 已经持久化的快照引用，按标签顺序排列。
    /// - active: 活动标签身份。
    /// 返回：新索引同步完成；上一份有效索引另行保留。
    public func publish(_ references: [RecoveryReference], active: UUID?) throws {
        let target = directory.appendingPathComponent("session.json")
        let previous = directory.appendingPathComponent("session.previous.json")
        if FileManager.default.fileExists(atPath: target.path) {
            let old = try Data(contentsOf: target)
            var fallback = try JSONDecoder().decode(RecoveryIndex.self, from: old)
            guard fallback.format == 1 else {
                throw NateError.message("不能覆盖较新格式的恢复索引。")
            }
            let openIDs = Set(references.map(\.id))
            // 已关闭身份从两份索引同时排除，当前索引受损时也不能复活关闭内容。
            fallback.documents.removeAll {
                !openIDs.contains($0.id)
            }
            if !fallback.documents.contains(where: {
                $0.id == fallback.active
            }) {
                fallback.active = nil
            }
            let previousData = try JSONEncoder().encode(fallback)
            let oldBaseline =
                FileManager.default.fileExists(atPath: previous.path)
                ? try FileStorage.baseline(previous) : nil
            _ = try FileStorage.save(previousData, to: previous, expected: oldBaseline)
        }
        let data = try JSONEncoder().encode(RecoveryIndex(active: active, documents: references))
        let expected =
            FileManager.default.fileExists(atPath: target.path) ? try FileStorage.baseline(target) : nil
        _ = try FileStorage.save(data, to: target, expected: expected)
    }

    /// 业务作用：校验索引、文件名和完整性，损坏记录不被当成空文本。
    /// 参数说明: 无。
    /// 返回：可恢复文档与活动身份；索引损坏时尝试上一份有效记录。
    public func restore() throws -> (documents: [RecoveryDocument], active: UUID?) {
        var lastError: (any Error)?
        var found = false
        for filename in ["session.json", "session.previous.json"] {
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            found = true
            do {
                let index = try JSONDecoder().decode(RecoveryIndex.self, from: Data(contentsOf: url))
                guard index.format == 1 else {
                    throw NateError.message("恢复索引格式较新，现有内容已保留。")
                }
                let documents = try index.documents.map {
                    reference in
                    guard !reference.file.contains("/"), !reference.file.contains("..") else {
                        throw NateError.invalidRange
                    }
                    let data = try Data(contentsOf: directory.appendingPathComponent(reference.file))
                    guard FileStorage.digest(data) == reference.checksum else {
                        throw NateError.message("恢复快照完整性校验失败。")
                    }
                    let document = try JSONDecoder().decode(RecoveryDocument.self, from: data)
                    guard document.id == reference.id else {
                        throw NateError.message("恢复文档身份不匹配。")
                    }
                    return document
                }
                return (documents, index.active)
            }
            catch {
                lastError = error
            }
        }
        if found, let lastError {
            throw lastError
        }
        return ([], nil)
    }

    /// 业务作用：只在两份索引可靠后清理不再被引用的精确快照路径。
    /// 参数说明:
    /// - retention: 额外保留旧快照的时间，秒。
    /// 返回：清理本目录内已过期且无人引用的记录。
    public func collect(retention: TimeInterval = 7 * 86_400) throws {
        var keep: Set<String> = ["session.json", "session.previous.json", "closed-index.json"]
        keep.formUnion(try archivedReferences().map(\.file))
        for name in ["session.json", "session.previous.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let index = try JSONDecoder().decode(RecoveryIndex.self, from: data)
                guard index.format == 1 else {
                    throw NateError.message("恢复索引格式不可识别，停止清理并保留全部快照。")
                }
                keep.formUnion(index.documents.map(\.file))
            }
        }
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            guard !keep.contains(url.lastPathComponent), url.pathExtension == "json",
                UUID(uuidString: String(url.lastPathComponent.prefix(36))) != nil,
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                Date().timeIntervalSince(date) > retention
            else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}
