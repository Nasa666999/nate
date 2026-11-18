import Foundation

struct FoldedSearchScalar {
    let first: UInt32
    let second: UInt32
    let third: UInt32
    let count: Int

    /// 业务作用：顺序读取同一源标量的完整折叠，不把展开后的片段当作独立源字符。
    /// 参数说明:
    /// - index: 已由折叠数量限定的零起始结果索引。
    /// 返回：对应折叠标量；索引只能来自当前结果的有效范围。
    subscript(index: Int) -> UInt32 {
        index == 0 ? first : index == 1 ? second : third
    }
}

enum UnicodeSearchFold {
    /// 业务作用：普通与扩展搜索采用固定 Unicode 17.0.0 默认完整折叠，不依赖系统地区和 Unicode 库。
    /// 参数说明:
    /// - scalar: 一个完整源 Unicode 标量。
    /// - sensitive: 是否保留原标量而不折叠。
    /// 返回：一至三个折叠标量，不执行额外 NFC/NFD 归一化，不改变源正文。
    static func scalar(_ scalar: UInt32, sensitive: Bool) -> FoldedSearchScalar {
        if sensitive || scalar < 65 {
            return FoldedSearchScalar(first: scalar, second: 0, third: 0, count: 1)
        }
        if scalar <= 90 {
            return FoldedSearchScalar(first: scalar + 32, second: 0, third: 0, count: 1)
        }
        if scalar < 128 {
            return FoldedSearchScalar(first: scalar, second: 0, third: 0, count: 1)
        }
        var lower = 0
        var upper = UnicodeCaseFoldData.simple.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let entry = UnicodeCaseFoldData.simple[middle]
            let key = UInt32(entry >> 32)
            if key < scalar {
                lower = middle + 1
            }
            else if key > scalar {
                upper = middle
            }
            else {
                return FoldedSearchScalar(
                    first: UInt32(truncatingIfNeeded: entry),
                    second: 0,
                    third: 0,
                    count: 1
                )
            }
        }
        lower = 0
        upper = UnicodeCaseFoldData.expandedKeys.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let key = UnicodeCaseFoldData.expandedKeys[middle]
            if key < scalar {
                lower = middle + 1
            }
            else if key > scalar {
                upper = middle
            }
            else {
                let value = UnicodeCaseFoldData.expandedValues[middle]
                let third = UInt32(value & 0x1fffff)
                return FoldedSearchScalar(
                    first: UInt32(value >> 42),
                    second: UInt32((value >> 21) & 0x1fffff),
                    third: third,
                    count: third == 0 ? 2 : 3
                )
            }
        }
        return FoldedSearchScalar(first: scalar, second: 0, third: 0, count: 1)
    }
}
