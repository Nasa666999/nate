import Foundation
import NateCore
import NateUI

@MainActor
final class SearchResultBatchState {
    let presentation: SearchResultBatchPresentation
    let destinations: [UUID: ResultNavigation]
    let footprint: Int
    let matchCount: Int

    /// 业务作用：结果只保留定位证据和元数据，弱文档权威不会把关闭后的正文留在历史中。
    /// 参数说明:
    /// - presentation: 已通过完整容量和身份验证的批次。
    /// - destinations: 与每条显示命中一一对应的稳定定位证据。
    /// - footprint: 已验证的 UTF-8 元数据容量。
    /// - matchCount: 该批次全部实际命中数，包含无法无损定位的匹配。
    /// 返回：可独立清除的结果批次，不持有源正文快照。
    init(
        presentation: SearchResultBatchPresentation,
        destinations: [UUID: ResultNavigation],
        footprint: Int,
        matchCount: Int
    ) {
        self.presentation = presentation
        self.destinations = destinations
        self.footprint = footprint
        self.matchCount = matchCount
    }
}

extension ApplicationController {
    /// 业务作用：新查询完整发布为独立历史批次，容量不足时移除最旧批次并收回其定位权。
    /// 参数说明:
    /// - id: 实际查询的稳定请求身份。
    /// - query: 本次执行的完整表达式。
    /// - scope: 实际参与查询的范围说明。
    /// - files: 按来源顺序排列的完整结果分组。
    /// - notes: 真实跳过、无法定位或零匹配说明。
    /// - destinations: 显示命中与原文档或磁盘证据的完整对应集合。
    /// 返回：为满足二十批、十万命中和 64 MiB 容量而移除的旧批次数；失败保留原历史。
    func publishSearchResults(
        id: UUID,
        query: String,
        scope: String,
        files: [SearchResultFilePresentation],
        notes: [String],
        destinations: [(UUID, ResultNavigation)]
    ) throws -> Int {
        let presentation = SearchResultBatchPresentation(
            id: id,
            query: query,
            scope: scope,
            files: files,
            notes: notes
        )
        let footprint = try presentation.validatedFootprint()
        var mapping: [UUID: ResultNavigation] = [:]
        for (hit, destination) in destinations {
            guard mapping[hit] == nil else {
                throw NateError.message("搜索结果定位身份重复，原历史保留。")
            }
            mapping[hit] = destination
        }
        var rowCount = 0
        for file in files {
            for row in file.rows {
                guard mapping[row.id]?.range == row.range else {
                    throw NateError.message("显示命中与定位范围不一致，原历史保留。")
                }
                rowCount += 1
            }
        }
        guard mapping.count == rowCount,
            !resultBatches.contains(where: {
                $0.presentation.id == id
            })
        else {
            throw NateError.message("搜索批次或定位集合无效，原历史保留。")
        }
        let batch = SearchResultBatchState(
            presentation: presentation,
            destinations: mapping,
            footprint: footprint,
            matchCount: files.reduce(0) {
                $0 + $1.matchCount
            }
        )
        var candidate = [batch] + resultBatches
        var bytes = candidate.reduce(0) {
            $0 + $1.footprint
        }
        var rows = candidate.reduce(0) {
            $0 + $1.matchCount
        }
        var removed = 0
        while candidate.count > 20 || bytes > 64 * 1024 * 1024 || rows > 100_000 {
            let oldest = candidate.removeLast()
            bytes -= oldest.footprint
            rows -= oldest.matchCount
            removed += 1
        }
        // 完整候选先通过呈现验证，再发布拥有者索引；失败不能留下半份定位证据的新历史。
        try mainWindow?.presentSearchResults(candidate.map(\.presentation))
        resultBatches = candidate
        resultNavigation = files.flatMap {
            $0.rows
        }.compactMap {
            mapping[$0.id]
        }
        return removed
    }

    /// 业务作用：结果树按稳定批次与命中身份定位，旧行号和已清除历史不拥有源文档焦点。
    /// 参数说明:
    /// - batch: 用户当前激活的批次身份。
    /// - hit: 该批次内的稳定命中身份。
    /// 返回：仍保留的真实命中进入统一导航，失效身份保持正文不变。
    func navigateSearchResult(batch: UUID, hit: UUID) {
        guard
            let target = resultBatches.first(where: {
                $0.presentation.id == batch
            })?.destinations[hit]
        else {
            return
        }
        navigateResultTarget(
            target,
            current: {
                [weak self] in
                self?.resultBatches.first(where: {
                    $0.presentation.id == batch
                })?.destinations[hit] != nil
            }
        )
    }

    /// 业务作用：清除只回收所选结果的元数据和定位权，正文、查询输入与其他批次保持独立。
    /// 参数说明:
    /// - ids: 用户明确选择清除的稳定批次身份。
    /// 返回：当前存在的批次被完整移除，等待中的旧定位立即失权。
    func removeSearchResultBatches(_ ids: [UUID]) {
        let selected = Set(ids)
        let candidate = resultBatches.filter {
            !selected.contains($0.presentation.id)
        }
        guard candidate.count != resultBatches.count else {
            return
        }
        // 先撤销旧导航再收回批次，迟到读取不能在清除之后重新激活其来源。
        resultNavigationGeneration = UUID()
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        do {
            try mainWindow?.presentSearchResults(candidate.map(\.presentation))
            resultBatches = candidate
            if let latest = candidate.first {
                resultNavigation = latest.presentation.files.flatMap {
                    $0.rows
                }.compactMap {
                    latest.destinations[$0.id]
                }
            }
            else {
                resultNavigation = []
            }
        }
        catch {
            mainWindow?.status.stringValue = error.localizedDescription
        }
    }
}
