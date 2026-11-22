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
    public var selectionState: SelectionState?
    public var bookmarks: Set<Int>
    public var readOnly: Bool
    public var lineEnding: LineEnding?
    public var pinned: Bool?

    /// 业务作用：恢复进度使用完整元数据的原字节证据，正文由独立修订和内容清单绑定。
    /// 参数说明: 无。
    /// 返回：稳定 SHA-256；无法编码时使用独立身份，不冒用任何既有检查点。
    public var metadataKey: String {
        var metadata = self
        metadata.text = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(metadata) else {
            return UUID().uuidString
        }
        return FileStorage.digest(data)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case name
        case text
        case path
        case encoding
        case baseline
        case language
        case selections
        case bookmarks
        case readOnly
        case lineEnding
        case pinned
        case selectionArchive
    }

    /// 业务作用：按固定行号编码书签，避免集合遍历顺序导致相同恢复元数据生成不同清单。
    /// 参数说明:
    /// - encoder: 调用方配置的编码器，清单入口另外固定字典键顺序。
    /// 返回：全部业务字段交给编码器，书签按行号排列；编码失败向上传递。
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(revision, forKey: .revision)
        try values.encode(name, forKey: .name)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(path, forKey: .path)
        try values.encode(encoding, forKey: .encoding)
        try values.encodeIfPresent(baseline, forKey: .baseline)
        try values.encode(language, forKey: .language)
        // 完整归档已有全部几何，旧字段保持可读但不再重复十万项坐标和稳定身份。
        try values.encode(SelectionGeometries(selectionState == nil ? selections : []), forKey: .selections)
        try values.encodeIfPresent(
            selectionState.map {
                try SelectionStateArchive.encode($0)
            },
            forKey: .selectionArchive
        )
        try values.encode(bookmarks.sorted(), forKey: .bookmarks)
        try values.encode(readOnly, forKey: .readOnly)
        try values.encodeIfPresent(lineEnding, forKey: .lineEnding)
        try values.encodeIfPresent(pinned, forKey: .pinned)
    }

    /// 业务作用：有完整选择归档的记录只允许完整恢复，损坏或未知格式不能降级成旧几何。
    /// 参数说明:
    /// - decoder: 已由所属恢复文件限制容量的解码器。
    /// 返回：保留全部选择身份的元数据；旧记录继续使用原几何，正文边界由载入入口另行验证。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let archive = try values.decodeIfPresent(Data.self, forKey: .selectionArchive)
        let state = try archive.map {
            try SelectionStateArchive.decode($0)
        }
        let geometries = try values.decode(SelectionGeometries.self, forKey: .selections).values
        guard state == nil || geometries.isEmpty else {
            throw NateError.message("恢复记录同时包含两份不同选择来源，原记录保留。")
        }
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            revision: try values.decode(UInt64.self, forKey: .revision),
            name: try values.decode(String.self, forKey: .name),
            text: try values.decode(String.self, forKey: .text),
            path: try values.decodeIfPresent(String.self, forKey: .path),
            encoding: try values.decode(TextEncoding.self, forKey: .encoding),
            baseline: try values.decodeIfPresent(DiskBaseline.self, forKey: .baseline),
            language: try values.decode(String.self, forKey: .language),
            selections: state?.selections ?? geometries,
            bookmarks: try values.decode(Set<Int>.self, forKey: .bookmarks),
            readOnly: try values.decode(Bool.self, forKey: .readOnly),
            lineEnding: try values.decodeIfPresent(LineEnding.self, forKey: .lineEnding),
            pinned: try values.decodeIfPresent(Bool.self, forKey: .pinned),
            selectionState: state
        )
    }

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
    /// - pinned: 标签固定状态；旧记录可为空并按未固定恢复。
    /// - selectionState: 可选的完整选择身份与形态，存在时与 selections 必须一致。
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
        lineEnding: LineEnding? = nil,
        pinned: Bool? = nil,
        selectionState: SelectionState? = nil
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
        self.pinned = pinned
        self.selectionState = selectionState
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
    var storagePolicy: RecoveryStoragePolicy
    var storageBudget: RecoveryWriteBudget?
    var progress: RecoveryProgressObservation = {
        _ in
    }

    /// 业务作用：将恢复内容固定到可写的用户数据目录。
    /// 参数说明:
    /// - directory: 本实例专属恢复目录。
    /// - storagePolicy: 后续恢复写入采用的总量策略，不限制读取已有内容。
    /// 返回：不依赖应用包位置的恢复存储；无效目录保留原证据，实际访问时明确拒绝。
    public init(directory: URL, storagePolicy: RecoveryStoragePolicy = RecoveryStoragePolicy()) {
        self.storagePolicy = storagePolicy
        do {
            try FileStorage.validateFileURL(directory)
            self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        }
        catch {
            // 无效输入不能先被转成可写的其它目录，后续读写仍依据原始 URL 拒绝。
            self.directory = directory
        }
    }

    /// 业务作用：在恢复目录合法时为完整字符串建立分块检查点，正文树调用方使用流式入口。
    /// 参数说明:
    /// - document: 已提交文档及恢复元数据。
    /// 返回：内容分块和清单已同步后的引用，不发布工作区索引。
    public func checkpoint(_ document: RecoveryDocument) throws -> RecoveryReference {
        try FileStorage.validateFileURL(directory)
        return try checkpoint(metadata: document, text: PieceTree(document.text))
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
