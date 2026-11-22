import AppKit
import NateCore

extension TextComparisonWindow {
    /// 业务作用：完整变更列表采用原生惰性行视图，数量不会因窗口高度而被截断。
    /// 参数说明:
    /// - tableView: 本比较窗口的变更列表。
    /// 返回：完整已求解变更数，没有差异时为零。
    public func numberOfRows(in tableView: NSTableView) -> Int {
        comparison.hunks.count
    }

    /// 业务作用：变更条目明确标识增删方向及两侧原行位置，空侧仍显示可定位插入锚点。
    /// 参数说明:
    /// - tableView: 本窗口的完整变更列表。
    /// - tableColumn: 原生请求的变更列。
    /// - row: 当前可见的零基变更索引。
    /// 返回：具有完整提示的两行单元格；越界请求不产生其它变更的替代条目。
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard comparison.hunks.indices.contains(row) else {
            return nil
        }
        let identity = NSUserInterfaceItemIdentifier("comparison-change")
        let label =
            tableView.makeView(withIdentifier: identity, owner: self) as? NSTextField
            ?? NSTextField(wrappingLabelWithString: "")
        label.identifier = identity
        let hunk = comparison.hunks[row]
        let kind = hunk.originalLines.isEmpty ? "新增" : hunk.revisedLines.isEmpty ? "删除" : "修改"
        label.stringValue =
            "\(row + 1). \(kind)\n左 \(Self.lineLabel(hunk.originalLines)) · 右 \(Self.lineLabel(hunk.revisedLines))"
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = label.stringValue
        return label
    }

    /// 业务作用：鼠标或键盘选择列表项时同时定位两侧只读范围。
    /// 参数说明:
    /// - notification: 原生列表选择改变通知。
    /// 返回：有效新条目完成双侧定位，取消列表选择不移动正文视口。
    public func tableViewSelectionDidChange(_ notification: Notification) {
        let index = changes.selectedRow
        if index != selectedChange {
            selectChange(index)
        }
    }

    /// 业务作用：明确变更跳转仅改变独立比较视图，插入和删除的空侧定位到原始锚点。
    /// 参数说明:
    /// - index: 完整变更集合中的零基索引。
    /// 返回：有效索引同步选择两侧并显示变更起点，越界不改变当前状态。
    public func selectChange(_ index: Int) {
        guard comparison.hunks.indices.contains(index) else {
            return
        }
        selectedChange = index
        let hunk = comparison.hunks[index]
        synchronizing = true
        defer {
            synchronizing = false
        }
        for (editor, range) in [(originalEditor, hunk.originalRange), (revisedEditor, hunk.revisedRange)] {
            do {
                try editor.setSelectionState(
                    SelectionState(selections: [
                        TextSelection(
                            anchor: range.lower,
                            head: range.upper
                        )
                    ])
                )
                editor.refresh()
                if let scroll = editor.enclosingScrollView {
                    scroll.contentView.scroll(
                        to: NSPoint(
                            x: 0,
                            y: scroll.contentView.bounds.minY
                        )
                    )
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                editor.revealSelection(
                    TextSelection(
                        anchor: range.lower,
                        head: range.lower
                    )
                )
            }
            catch {
                summary.stringValue = "变更定位未完成：" + error.localizedDescription
                return
            }
        }
        if changes.selectedRow != index {
            changes.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        changes.scrollRowToVisible(index)
        updateSummary()
    }

    /// 业务作用：上一个变更在完整集合中循环，不通过修改源选区执行导航。
    /// 参数说明: 无。
    /// 返回：有变更时定位上一项，初始或首项回到末项。
    @objc func previousChange() {
        guard !comparison.hunks.isEmpty else {
            return
        }
        selectChange(selectedChange <= 0 ? comparison.hunks.count - 1 : selectedChange - 1)
    }

    /// 业务作用：下一个变更在完整集合中循环，列表外的变更也具有同等导航资格。
    /// 参数说明: 无。
    /// 返回：有变更时定位下一项，末项后回到首项。
    @objc func nextChange() {
        guard !comparison.hunks.isEmpty else {
            return
        }
        selectChange((selectedChange + 1) % comparison.hunks.count)
    }

    /// 业务作用：状态展示实际增删行数及当前变更身份，相同正文不冒充已比较文件编码相同。
    /// 参数说明: 无。
    /// 返回：完整比较统计及当前导航位置进入可访问标签。
    func updateSummary() {
        if comparison.hunks.isEmpty {
            summary.stringValue = "两侧正文相同，包含全部实际换行；文件编码与 BOM 见下方说明。"
        }
        else {
            let position =
                selectedChange < 0 ? "尚未选择变更" : "当前 \(selectedChange + 1)/\(comparison.hunks.count)"
            summary.stringValue =
                "\(comparison.hunks.count) 处变更 · 左侧删除 \(comparison.removedLineCount) 行 · 右侧新增 \(comparison.insertedLineCount) 行 · \(position)"
        }
    }

    /// 业务作用：真实源行号与空侧插入点分别呈现，不制造源文件不存在的占位行。
    /// 参数说明:
    /// - range: 零基、右端开放的原物理行区间。
    /// 返回：一基原行范围，空区间显示锚点。
    private static func lineLabel(_ range: Range<Int>) -> String {
        range.isEmpty
            ? "\(range.lowerBound + 1)（锚点）"
            : range.count == 1 ? "\(range.lowerBound + 1)" : "\(range.lowerBound + 1)–\(range.upperBound)"
    }
}
