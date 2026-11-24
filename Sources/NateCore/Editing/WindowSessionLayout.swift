import Foundation

public struct WindowSessionFrame: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// 业务作用：保存原窗口屏幕范围，恢复层再按可用显示器的真实几何限位。
    /// 参数说明:
    /// - x: 原窗口左边界的屏幕坐标。
    /// - y: 原窗口下边界的屏幕坐标。
    /// - width: 原窗口宽度。
    /// - height: 原窗口高度。
    /// 返回：待完整恢复验证的持久化几何。
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WindowSessionViewport: Codable, Sendable, Equatable {
    public let line: Int
    public let offset: Double
    public let x: Double

    /// 业务作用：保存顶端逻辑行与行内像素偏移，使屏幕和排版改变后仍可定位原位置。
    /// 参数说明:
    /// - line: 顶端实际逻辑行。
    /// - offset: 对该行起点的垂直偏移。
    /// - x: 视口横向滚动位置。
    /// 返回：待页面按实际几何复验的只读锚点。
    public init(line: Int, offset: Double, x: Double) {
        self.line = line
        self.offset = offset
        self.x = x
    }
}

public struct WindowSessionView: Codable, Sendable, Equatable {
    public let documentID: UUID
    public let revision: UInt64
    public let selection: SelectionState?
    public let viewport: WindowSessionViewport?
    public let wrapLines: Bool
    public let rightToLeft: Bool

    private enum CodingKeys: String, CodingKey {
        case documentID, revision, selection, viewport, wrapLines, rightToLeft
    }

    /// 业务作用：独立编辑视图与共享正文用身份和修订关联，两个克隆仍可保留不同的选择和视口。
    /// 参数说明:
    /// - documentID: 视图持有的正文身份。
    /// - revision: 选择与滚动坐标对应的正文修订。
    /// - selection: 此视图的完整选择和主项。
    /// - viewport: 当前可追踪的顶行及像素偏移。
    /// - wrapLines: 此视图是否软换行。
    /// - rightToLeft: 此视图是否从右向左呈现。
    /// 返回：与某一正文修订关联的待恢复视图状态。
    public init(
        documentID: UUID,
        revision: UInt64,
        selection: SelectionState?,
        viewport: WindowSessionViewport?,
        wrapLines: Bool,
        rightToLeft: Bool
    ) {
        self.documentID = documentID
        self.revision = revision
        self.selection = selection
        self.viewport = viewport
        self.wrapLines = wrapLines
        self.rightToLeft = rightToLeft
    }

    /// 业务作用：全量稳定选择使用已有紧凑协议，损坏选择不能降级为部分身份后安装。
    /// 参数说明:
    /// - decoder: 已有界读取的窗口归档解码器。
    /// 返回：全部字段和选择摘要成功验证后恢复，损坏格式整体失败。
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try fields.decode(UUID.self, forKey: .documentID)
        revision = try fields.decode(UInt64.self, forKey: .revision)
        selection = try fields.decodeIfPresent(Data.self, forKey: .selection).map {
            try SelectionStateArchive.decode($0)
        }
        viewport = try fields.decodeIfPresent(WindowSessionViewport.self, forKey: .viewport)
        wrapLines = try fields.decode(Bool.self, forKey: .wrapLines)
        rightToLeft = try fields.decode(Bool.self, forKey: .rightToLeft)
    }

    /// 业务作用：布局归档嵌入完整选择摘要而不展开重复的 UUID 字符串。
    /// 参数说明:
    /// - encoder: 窗口布局外层归档编码器。
    /// 返回：写入有界紧凑选择与窗口显示字段，任何字段失败时拒绝此次保存。
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(documentID, forKey: .documentID)
        try fields.encode(revision, forKey: .revision)
        try fields.encodeIfPresent(selection.map { try SelectionStateArchive.encode($0) }, forKey: .selection)
        try fields.encodeIfPresent(viewport, forKey: .viewport)
        try fields.encode(wrapLines, forKey: .wrapLines)
        try fields.encode(rightToLeft, forKey: .rightToLeft)
    }
}

public struct WindowSession: Codable, Sendable, Equatable {
    public let tabs: [UUID]
    public let frame: WindowSessionFrame
    public let primary: WindowSessionView
    public let secondary: WindowSessionView?
    public let verticalSplit: Bool
    public let splitFraction: Double
    public let secondaryFocused: Bool

    /// 业务作用：保留原窗口标签顺序、几何与最多两个独立正文视图。
    /// 参数说明:
    /// - tabs: 此窗口按实际顺序持有的标签身份。
    /// - frame: 按屏幕坐标记录的窗口区域。
    /// - primary: 第一正文视图。
    /// - secondary: 第二正文视图，单视图时为空。
    /// - verticalSplit: 为真时左右排列，否则上下排列。
    /// - splitFraction: 分隔位置占可用宽度或高度的比例。
    /// - secondaryFocused: 第二视图是否曾持有本窗口的编辑焦点。
    /// 返回：待整份窗口布局复验的一个窗口。
    public init(
        tabs: [UUID],
        frame: WindowSessionFrame,
        primary: WindowSessionView,
        secondary: WindowSessionView?,
        verticalSplit: Bool,
        splitFraction: Double,
        secondaryFocused: Bool
    ) {
        self.tabs = tabs
        self.frame = frame
        self.primary = primary
        self.secondary = secondary
        self.verticalSplit = verticalSplit
        self.splitFraction = splitFraction
        self.secondaryFocused = secondaryFocused
    }

    /// 业务作用：窗口焦点恢复时确定原编辑视图和活动标签共用的实际文档。
    /// 参数说明: 无。
    /// 返回：原活动视图；单视图窗口使用第一视图。
    public var activeView: WindowSessionView {
        secondaryFocused ? secondary ?? primary : primary
    }
}

public struct WindowSessionLayout: Codable, Sendable, Equatable {
    public static let maximumBytes = 8_388_608
    private var format = 1
    public let windows: [WindowSession]
    public let activeWindow: Int

    /// 业务作用：独立记录全部窗口及当前窗口范围，文档正文继续由各自恢复记录保护。
    /// 参数说明:
    /// - windows: 按工作区记录顺序捕获的窗口。
    /// - activeWindow: 其中实际接收正文命令的窗口位置。
    /// 返回：待验证与持久化的视图快照。
    public init(windows: [WindowSession], activeWindow: Int) {
        self.windows = windows
        self.activeWindow = activeWindow
    }

    /// 业务作用：布局只有覆盖同一批实际文档时才可恢复，不能将旧窗口关联重用到其它正文。
    /// 参数说明: 无。
    /// 返回：所有窗口标签的共享正文身份集合。
    public var documentIDs: Set<UUID> {
        Set(windows.flatMap(\.tabs))
    }

    /// 业务作用：整份复验窗口、标签、视口和选择规模，异常布局不得产生部分窗口或超量分配。
    /// 参数说明: 无。
    /// 返回：全部局部字段和累积容量合法时完成；任何非法引用或几何拒绝整份布局。
    public func validate() throws {
        guard format == 1, (1...32).contains(windows.count), windows.indices.contains(activeWindow) else {
            throw NateError.message("窗口恢复格式、窗口数量或活动窗口无法识别。")
        }
        var shared: Set<UUID> = []
        var selections = 0
        for entry in windows {
            let tabs = Set(entry.tabs)
            guard (1...1024).contains(entry.tabs.count), tabs.count == entry.tabs.count,
                (-1_048_576...1_048_576).contains(entry.frame.x),
                (-1_048_576...1_048_576).contains(entry.frame.y),
                (1...65_536).contains(entry.frame.width), (1...65_536).contains(entry.frame.height),
                (0...1).contains(entry.splitFraction), !entry.secondaryFocused || entry.secondary != nil
            else {
                throw NateError.message("窗口尺寸、标签集合或分屏位置无效。")
            }
            shared.formUnion(tabs)
            guard shared.count <= 1024 else {
                throw NateError.message("窗口布局包含超过 1024 个共享文档。")
            }
            for view in [entry.primary, entry.secondary].compactMap({ $0 }) {
                guard tabs.contains(view.documentID) else {
                    throw NateError.message("分屏引用了窗口标签之外的正文。")
                }
                if let viewport = view.viewport {
                    guard viewport.line >= 0, viewport.offset.isFinite, viewport.x.isFinite, viewport.x >= 0
                    else {
                        throw NateError.message("窗口滚动锚点无效。")
                    }
                }
                selections += view.selection?.entries.count ?? 0
                guard selections <= 200_000 else {
                    throw NateError.message("窗口布局的完整选择超过共同容量。")
                }
            }
        }
    }
}
