import Foundation

public struct TextRelocation: Sendable {
    public let source: ByteRange
    public let destination: ByteRange

    /// 业务作用：记录一段原文在整行重排后的实际位置，行结束符允许按目标行的原有类型调整。
    /// 参数说明:
    /// - source: 修改前的完整位置区间。
    /// - destination: 修改后的对应位置区间，空区间仍保留明确端点。
    /// 返回：尚未验证整份覆盖关系的单段移动意图。
    public init(source: ByteRange, destination: ByteRange) {
        self.source = source
        self.destination = destination
    }
}

public struct TextAnchorRelocation: Sendable {
    public let source: Int
    public let destination: Int

    /// 业务作用：行首、行尾和空行位置跟随原正文，独立于固定物理行结束符的字节移动。
    /// 参数说明:
    /// - source: 原文中的明确锚点。
    /// - destination: 移动后仍属于同一原文的锚点。
    /// 返回：由完整重排索引统一校验的点位置意图。
    public init(source: Int, destination: Int) {
        self.source = source
        self.destination = destination
    }
}

public struct TextPermutation: Sendable {
    public let scope: ByteRange
    let forward: [TextRelocation]
    private let backward: [TextRelocation]
    let anchors: [TextAnchorRelocation]
    private let reverseAnchors: [TextAnchorRelocation]
    var indexedCount: Int {
        forward.count + anchors.count
    }
    var isIdentity: Bool {
        let bytes = forward.allSatisfy {
            $0.source == $0.destination
        }
        return bytes
            && anchors.allSatisfy {
                $0.source == $0.destination
            }
    }
    var retainedBytes: Int {
        (forward.count + backward.count) * MemoryLayout<TextRelocation>.stride
            + (anchors.count + reverseAnchors.count) * MemoryLayout<TextAnchorRelocation>.stride
    }

    /// 业务作用：完整重排只接受源与目标都连续覆盖同一区间的移动，不能以交叠或缺口伪造位置权限。
    /// 参数说明:
    /// - scope: 本次重新排列的完整正文区间，区间之外位置保持不变。
    /// - segments: 正文和行结束符的全部对应关系，最多二十万零两段。
    /// - anchors: 行首、行尾与空行的明确后侧锚点，最多二十万零两项。
    /// 返回：已验证双向位置索引；负位置、缺口、交叠、越界或取消时失败。
    public init(scope: ByteRange, segments: [TextRelocation], anchors: [TextAnchorRelocation] = []) throws {
        guard scope.lower >= 0, scope.upper >= scope.lower, segments.count <= 200_002,
            anchors.count <= 200_002
        else {
            throw NateError.invalidRange
        }
        try Task.checkCancellation()
        let original = segments.sorted {
            (a: TextRelocation, b: TextRelocation) -> Bool in
            if a.source.lower == b.source.lower {
                return a.source.upper < b.source.upper
            }
            return a.source.lower < b.source.lower
        }
        let inverse = segments.map {
            TextRelocation(source: $0.destination, destination: $0.source)
        }.sorted {
            (a: TextRelocation, b: TextRelocation) -> Bool in
            if a.source.lower == b.source.lower {
                return a.source.upper < b.source.upper
            }
            return a.source.lower < b.source.lower
        }
        try Self.validate(original, scope: scope)
        try Self.validate(inverse, scope: scope)
        let points = try Self.anchorIndex(anchors, scope: scope)
        let reversed = try Self.anchorIndex(
            points.map {
                TextAnchorRelocation(source: $0.destination, destination: $0.source)
            },
            scope: scope
        )
        self.scope = scope
        forward = original
        backward = inverse
        self.anchors = points
        reverseAnchors = reversed
    }

    /// 业务作用：已经完整验证的两个索引在撤销和重做时共享存储，不重新排序整份行表。
    /// 参数说明:
    /// - scope: 原重排区间。
    /// - forward: 已验证的源位置索引。
    /// - backward: 已验证的目标位置索引。
    /// - anchors: 已验证的原锚点索引。
    /// - reverseAnchors: 已验证的目标锚点索引。
    /// 返回：两份索引结构共享的不可变移动关系。
    private init(
        scope: ByteRange,
        forward: [TextRelocation],
        backward: [TextRelocation],
        anchors: [TextAnchorRelocation],
        reverseAnchors: [TextAnchorRelocation]
    ) {
        self.scope = scope
        self.forward = forward
        self.backward = backward
        self.anchors = anchors
        self.reverseAnchors = reverseAnchors
    }

    /// 业务作用：撤销沿实际目标位置返回原文，混合换行的端点采用同一明确归属。
    /// 参数说明: 无。
    /// 返回：与本次移动共用索引存储的逆向映射。
    public var inverse: TextPermutation {
        TextPermutation(
            scope: scope,
            forward: backward,
            backward: forward,
            anchors: reverseAnchors,
            reverseAnchors: anchors
        )
    }

    /// 业务作用：光标优先使用明确后侧锚点随原行移动，未指定锚点的边界按原前段或原后段归属。
    /// 参数说明:
    /// - position: 修改前的正文位置。
    /// - affinity: 边界归属前段或后段；空行与无末尾换行保留明确后侧锚点。
    /// 返回：区间外原位保留，正文内按片段移动，长度改变的行结束符只映射到其有效端点。
    public func map(_ position: Int, affinity: PositionAffinity = .after) -> Int {
        guard position >= scope.lower, position <= scope.upper, !forward.isEmpty else {
            return position
        }
        if affinity == .after, let point = anchor(at: position) {
            return point
        }
        var lower = 0, upper = forward.count
        if affinity == .after {
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if forward[middle].source.lower <= position {
                    lower = middle + 1
                }
                else {
                    upper = middle
                }
            }
            guard lower > 0 else {
                return position
            }
            let segment = forward[lower - 1]
            // 末尾有换行时区间之后仍是独立行；无换行时零长度结束符为末尾正文保留自己的锚点。
            if position == scope.upper && !segment.source.isEmpty {
                return position
            }
            return Self.offset(position, in: segment)
        }
        guard position > scope.lower else {
            return position
        }
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if forward[middle].source.upper < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < forward.count else {
            return position
        }
        return Self.offset(position, in: forward[lower])
    }

    /// 业务作用：明确行锚点使用二分索引，物理换行保持原位时光标仍可跟随自己的行首与行尾。
    /// 参数说明:
    /// - position: 当前原文位置。
    /// 返回：该位置存在明确锚点时提供目标，否则由原字节片段处理。
    private func anchor(at position: Int) -> Int? {
        var lower = 0, upper = anchors.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if anchors[middle].source < position {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        guard lower < anchors.count, anchors[lower].source == position else {
            return nil
        }
        return anchors[lower].destination
    }

    /// 业务作用：明确点位置必须在同一区间中可逆，空行重复端点只允许相同目标，不能任意挑选。
    /// 参数说明:
    /// - values: 源到目标的全部点意图。
    /// - scope: 唯一重排范围。
    /// 返回：按源位置排序且去重的索引；越界、同点不同目标或取消时整体失败。
    private static func anchorIndex(_ values: [TextAnchorRelocation], scope: ByteRange) throws
        -> [TextAnchorRelocation]
    {
        let sorted = values.sorted {
            $0.source < $1.source
        }
        var result: [TextAnchorRelocation] = []
        for (index, value) in sorted.enumerated() {
            if index & 255 == 0 {
                try Task.checkCancellation()
            }
            guard value.source >= scope.lower, value.source <= scope.upper,
                value.destination >= scope.lower, value.destination <= scope.upper
            else {
                throw NateError.invalidRange
            }
            if let last = result.last, last.source == value.source {
                guard last.destination == value.destination else {
                    throw NateError.message("同一行锚点具有不同目标，未选择任意一份位置映射。")
                }
            }
            else {
                result.append(value)
            }
        }
        return result
    }

    /// 业务作用：仅在片段自身的真实范围内转移偏移，行结束符缩短不能制造越界位置。
    /// 参数说明:
    /// - position: 归属于该片段的原位置。
    /// - segment: 已验证的源与目标片段。
    /// 返回：同长正文保留精确偏移，空片段采用目标起点，原片段终点采用目标终点。
    private static func offset(_ position: Int, in segment: TextRelocation) -> Int {
        guard !segment.source.isEmpty else {
            return segment.destination.lower
        }
        if position == segment.source.upper {
            return segment.destination.upper
        }
        return segment.destination.lower + min(position - segment.source.lower, segment.destination.count)
    }

    /// 业务作用：一份移动索引必须覆盖全部原区间，空端点不能借缺口跨入未授权正文。
    /// 参数说明:
    /// - values: 已按源起点、终点排序的索引。
    /// - scope: 唯一允许重排的完整范围。
    /// 返回：源片段无缺口、目标合法时通过，否则整体拒绝。
    private static func validate(_ values: [TextRelocation], scope: ByteRange) throws {
        var cursor = scope.lower
        var previous: TextRelocation?
        for (index, value) in values.enumerated() {
            if index & 255 == 0 {
                try Task.checkCancellation()
            }
            guard value.source.lower == cursor, value.source.upper >= value.source.lower,
                value.source.upper <= scope.upper,
                value.destination.lower >= scope.lower, value.destination.upper >= value.destination.lower,
                value.destination.upper <= scope.upper
            else {
                throw NateError.invalidRange
            }
            if let previous, previous.source.isEmpty, previous.source == value.source,
                previous.destination.lower != value.destination.lower
            {
                throw NateError.message("同一空端点具有不同移动目标，未选择任意一份位置映射。")
            }
            cursor = value.source.upper
            previous = value
        }
        guard cursor == scope.upper else {
            throw NateError.invalidRange
        }
    }
}
