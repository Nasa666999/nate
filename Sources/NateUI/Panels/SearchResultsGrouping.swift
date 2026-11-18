import Foundation

extension SearchResultsPanel {
    /// 业务作用：按真实匹配起始行合并已有预览，每条命中的完整范围和顺序仍独立保留。
    /// 参数说明:
    /// - rows: 同一固定来源中通过筛选的实际匹配。
    /// 返回：逐匹配或逐起始行的非空展示组，不读取正文、不合并不同文件或批次。
    func resultGroups(_ rows: [SearchPreviewRow]) -> [[SearchPreviewRow]] {
        guard preferences.oneRowPerLine else {
            return rows.map {
                [$0]
            }
        }
        var groups: [[SearchPreviewRow]] = []
        var indices: [Int: Int] = [:]
        for row in rows {
            if let index = indices[row.line] {
                groups[index].append(row)
            }
            else {
                indices[row.line] = groups.count
                groups.append([row])
            }
        }
        return groups
    }
}
