import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：离开标签时收录这扇窗口的独立光标与视口，不能从另一个克隆借用选择。
    /// 参数说明: 无。
    /// 返回：当前视图的选择、对应修订和原视口。
    func currentTabViewPosition() -> WindowSessionView {
        editor.sessionView()
    }

    /// 业务作用：切换回来时按共享正文修订链复算本窗口的选区和视口。
    /// 参数说明:
    /// - container: 当前编辑视图使用的滚动容器。
    /// 返回：有效选择及时恢复，缺失映射时沿用当前正文的合法状态。
    func restoreTabViewPosition(in container: NSScrollView) {
        let id = editor.document.id
        if let position = tabViewPositions[id]?.rebased(for: editor.document) {
            tabViewPositions[id] = position
            editor.restoreSessionPosition(position)
            if window?.isKeyWindow == true, window?.firstResponder === editor {
                editor.synchronizeDocumentSelectionState()
            }
            if position.viewport != nil {
                return
            }
        }
        container.contentView.scroll(to: .zero)
        container.reflectScrolledClipView(container.contentView)
    }

    /// 业务作用：移入原先没有该文档的窗口时接收原视图位置，使用同一正文映射完整选区。
    /// 参数说明:
    /// - id: 被移入的共享文档身份。
    /// - source: 当前实际持有原标签和视图位置的窗口。
    /// 返回：目标窗口保存待显示的位置，调用不会改变两个窗口的键盘焦点。
    public func receiveTabViewPosition(_ id: UUID, from source: EditorWindow) {
        tabViewPositions[id] =
            source.editor.document.id == id ? source.currentTabViewPosition() : source.tabViewPositions[id]
    }

    /// 业务作用：释放已经离开当前窗口的标签位置，防止关闭后重新打开时继承旧的选择。
    /// 参数说明:
    /// - id: 已移除标签的实际身份。
    /// 返回：释放保留的位置，不改变其它标签或当前视图。
    public func forgetTabViewPosition(_ id: UUID) {
        tabViewPositions.removeValue(forKey: id)
    }
}

extension WindowSessionView {
    /// 业务作用：隐藏标签与移入视图的原位置沿正文修订链前进，并用真实字节锚点复算逻辑顶行。
    /// 参数说明:
    /// - document: 仍持有同一稳定身份的实际正文。
    /// 返回：状态与当前修订对齐；缺少完整映射时只保留仍可证明的位置。
    @MainActor
    func rebased(for document: DocumentBuffer) -> WindowSessionView? {
        guard documentID == document.id else {
            return nil
        }
        if revision == document.revision {
            return self
        }
        let selection = selection.flatMap { document.mapSelectionState($0, from: revision) }
        let viewport = viewport.flatMap {
            anchor -> WindowSessionViewport? in
            guard let byte = anchor.byteOffset,
                let mapped = document.mapSelections(
                    [TextSelection(anchor: byte, head: byte)],
                    from: revision
                )?.first,
                document.text.isBoundary(mapped.head)
            else {
                return nil
            }
            let line = document.text.lineNumber(at: mapped.head)
            return WindowSessionViewport(
                line: line,
                offset: anchor.offset,
                x: anchor.x,
                byteOffset: document.text.lineStart(line)
            )
        }
        return WindowSessionView(
            documentID: documentID,
            revision: document.revision,
            selection: selection,
            viewport: viewport,
            wrapLines: wrapLines,
            rightToLeft: rightToLeft,
            zoomPoints: zoomPoints
        )
    }
}
