import Foundation

struct UnicodeIdentifierRules: Codable, Sendable {
    let start: [[UInt32]]
    let continuation: [[UInt32]]

    enum CodingKeys: String, CodingKey {
        case start, continuation
    }

    /// 业务作用：校验固定 Unicode 标识符范围，资源损坏不能改变字符串前缀和代码边界。
    /// 参数说明:
    /// - decoder: 随语言资源提供的闭区间列表。
    /// 返回：有界、有序且不重叠的非 ASCII 范围；非法资源拒绝载入。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode([[UInt32]].self, forKey: .start)
        continuation = try container.decode([[UInt32]].self, forKey: .continuation)
        for key in [CodingKeys.start, .continuation] {
            let ranges = key == .start ? start : continuation
            guard ranges.count <= 4096 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Unicode 标识符范围超过容量。"
                )
            }
            var previous: UInt32 = 127
            for range in ranges {
                guard range.count == 2, range[0] > previous, range[0] <= range[1],
                    range[1] <= 0x10ffff, range[1] < 0xd800 || range[0] > 0xdfff
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription: "Unicode 标识符范围无序、重叠或含非法码点。"
                    )
                }
                previous = range[1]
            }
        }
    }

    /// 业务作用：按固定码点集合判定标识符边界，系统 Unicode 数据变化不改变既有语言规则。
    /// 参数说明:
    /// - scalar: 已确认的非 ASCII Unicode 码点。
    /// - first: 是否位于标识符首位。
    /// 返回：码点属于相应闭区间时为真。
    func contains(_ scalar: UInt32, first: Bool) -> Bool {
        let ranges = first ? start : continuation
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle][1] < scalar {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        return lower < ranges.count && ranges[lower][0] <= scalar
    }
}
