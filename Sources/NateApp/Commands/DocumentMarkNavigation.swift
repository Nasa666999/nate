import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：颜色导航按每个原始范围移动，重叠或相邻标记不会被合并绘制范围跳过。
    /// 参数说明:
    /// - style: 用户指定的查找颜色或持久样式。
    /// - backwards: 是否定位上一个标记。
    /// 返回：完整目标范围进入当前正文选区并展开所需折叠，首尾循环；正文和颜色状态不变。
    func navigateDocumentMarks(_ style: DocumentMarkStyle, backwards: Bool) {
        guard let context = currentMarkEditor(modifying: false) else {
            return
        }
        let ranges = context.document.buffer.marks.ranges(for: style)
        guard !ranges.isEmpty else {
            markFeedback("当前颜色组没有标记。")
            return
        }
        let selected = context.editor.primarySelection?.range ?? ByteRange(0, 0)
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = ranges[middle]
            if range.lower < selected.lower || range.lower == selected.lower && range.upper < selected.upper {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        let index: Int
        if lower < ranges.count, ranges[lower] == selected {
            index = (lower + (backwards ? ranges.count - 1 : 1)) % ranges.count
        }
        else {
            var start = 0
            var end = ranges.count
            while start < end {
                let middle = start + (end - start) / 2
                let before =
                    backwards ? ranges[middle].lower < selected.lower : ranges[middle].lower < selected.upper
                if before {
                    start = middle + 1
                }
                else {
                    end = middle
                }
            }
            index = backwards ? (start + ranges.count - 1) % ranges.count : start % ranges.count
        }
        // 用户选择了新的完整导航目标，先收回其它等待中的焦点和选择权限，再同步发布正文选区。
        cancelSearchMarking()
        cancelDocumentMarkCopy()
        cancelIncrementalSearch(resetOrigin: true)
        cancelProjectOpen()
        directoryWorkspace?.cancelOpen()
        cancelSearchResultPathOpen()
        searchNavigationGeneration = UUID()
        resultNavigationGeneration = UUID()
        resultNavigationTask?.cancel()
        resultNavigationTask = nil
        let range = ranges[index]
        context.document.buffer.selections = [TextSelection(anchor: range.lower, head: range.upper)]
        context.window.editor.refresh(reveal: true)
        context.window.window?.makeFirstResponder(context.window.editor)
        refreshUI()
        markFeedback("已定位颜色标记 \(index + 1) / \(ranges.count)。")
    }
}
