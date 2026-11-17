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
    var format = 2
    var active: UUID?
    var documents: [RecoveryReference]
}

public struct RecoveryStore: Sendable {
    public let directory: URL
    let chunkCache = RecoveryChunkCache()

    /// 业务作用：将恢复内容固定到可写的用户数据目录。
    /// 参数说明:
    /// - directory: 本实例专属恢复目录。
    /// 返回：不依赖应用包位置的恢复存储。
    public init(directory: URL) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    /// 业务作用：为显式传入完整字符串的调用者建立分块检查点，正文树调用方使用流式入口。
    /// 参数说明:
    /// - document: 已提交文档及恢复元数据。
    /// 返回：内容分块和清单已同步后的引用，不发布工作区索引。
    public func checkpoint(_ document: RecoveryDocument) throws -> RecoveryReference {
        try checkpoint(metadata: document, text: PieceTree(document.text))
    }

    /// 业务作用：为需要完整字符串的调用者读取已验证恢复内容，应用编辑流程直接取得正文树。
    /// 参数说明: 无。
    /// 返回：最近有效工作区的全部正文；损坏内容不会退化为空文档。
    public func restore() throws -> (documents: [RecoveryDocument], active: UUID?) {
        let recovered = try restoreSnapshots()
        return (
            recovered.documents.map {
                var record = $0.metadata
                record.text = $0.text.text()
                return record
            }, recovered.active
        )
    }
}
