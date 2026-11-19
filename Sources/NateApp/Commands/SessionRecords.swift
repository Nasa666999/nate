import Foundation
import NateCore

struct SessionFile: Codable, Sendable {
    var format = 2
    var documents: [SessionDocument]
}

struct SessionDocument: Codable, Sendable {
    var path: String
    var language: String
    var selections: [TextSelection]
    var readOnly: Bool
    var bookmarks: Set<Int>
    var selectionState: SelectionState?

    /// 业务作用：固定已命名文档的完整选择，普通会话不保存正文或输入法候选。
    /// 参数说明:
    /// - path: 文档实际本地路径。
    /// - language: 用户选择的语言标识。
    /// - selections: 旧式调用提供的几何。
    /// - readOnly: 恢复时的文档只读状态。
    /// - bookmarks: 真实逻辑行书签。
    /// - selectionState: 可选的完整稳定身份和矩形形态。
    /// 返回：尚未与再次读取的正文绑定的会话条目。
    init(
        path: String,
        language: String,
        selections: [TextSelection],
        readOnly: Bool,
        bookmarks: Set<Int>,
        selectionState: SelectionState? = nil
    ) {
        self.path = path
        self.language = language
        self.selections = selections
        self.readOnly = readOnly
        self.bookmarks = bookmarks
        self.selectionState = selectionState
    }

    /// 业务作用：完整归档一旦存在就必须完整解析，不使用旧几何掩盖损坏或未知格式。
    /// 参数说明:
    /// - decoder: 已受会话总大小约束的解码器。
    /// 返回：完整会话条目；旧记录继续保留原几何供正文读取后验证。
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let state = try values.decodeIfPresent(Data.self, forKey: .selectionArchive).map {
            try SelectionStateArchive.decode($0)
        }
        self.init(
            path: try values.decode(String.self, forKey: .path),
            language: try values.decode(String.self, forKey: .language),
            selections: try state?.selections ?? values.decode([TextSelection].self, forKey: .selections),
            readOnly: try values.decode(Bool.self, forKey: .readOnly),
            bookmarks: try values.decode(Set<Int>.self, forKey: .bookmarks),
            selectionState: state
        )
    }

    /// 业务作用：会话只保存一份紧凑完整选择，书签顺序固定使同一元数据具有稳定字节表示。
    /// 参数说明:
    /// - encoder: 所属会话提供的编码器。
    /// 返回：完整条目进入会话；编码失败不发布部分会话文件。
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(language, forKey: .language)
        try values.encode(selectionState == nil ? selections : [], forKey: .selections)
        try values.encodeIfPresent(
            selectionState.map {
                try SelectionStateArchive.encode($0)
            },
            forKey: .selectionArchive
        )
        try values.encode(readOnly, forKey: .readOnly)
        try values.encode(bookmarks.sorted(), forKey: .bookmarks)
    }

    private enum CodingKeys: String, CodingKey {
        case path, language, selections, readOnly, bookmarks, selectionArchive
    }
}
