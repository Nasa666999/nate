import AppKit
import NateCore

private struct EditorTextLinkResponse: Sendable {
    let line: Int
    let page: DocumentTextLinkPage?
    let reason: String?
}

extension EditorView {
    /// 业务作用：视口链接分析只沿本视图可见物理行请求，不枚举折叠正文或复制大文档。
    /// 参数说明: 无。
    /// 返回：当前视口前 256 个可见逻辑行，纵向读取范围最多 8192 像素。
    func textLinkVisibleLines() -> [Int] {
        let first = max(0, projection.line(at: max(0, visibleRect.minY - 8)))
        let bottom = visibleRect.minY + min(8192, max(0, visibleRect.height))
        let last = min(document.text.lineCount - 1, projection.line(at: bottom) + 1)
        guard first <= last else {
            return []
        }
        return Array(projection.visibleLines(in: first...last).prefix(256))
    }

    /// 业务作用：每个链接页绑定实际缓冲区、修订、不可变根与完整协议，来源变化先收回旧点击资格。
    /// 参数说明: 无。
    /// 返回：安排至多 128 行及 256 KiB 的后台准备；失败行明确记忆，同一视口重绘不反复计算。
    func prepareTextLinks() {
        guard textLinkSettings.mode != .disabled, composition == nil else {
            textLinks.hovered = nil
            toolTip = nil
            return
        }
        let snapshot = document.snapshot
        let settings = textLinkSettings
        let key = EditorTextLinkSource(
            document: ObjectIdentifier(document),
            documentID: snapshot.id,
            revision: snapshot.revision,
            root: snapshot.text.sourceIdentity,
            settings: settings
        )
        let state = textLinks
        if state.source != key {
            // 新正文或配置不能先显示旧链接再等待重算，点击证据与分析任务一同失权。
            state.reset()
            state.source = key
            toolTip = nil
            window?.invalidateCursorRects(for: self)
        }
        let visible = textLinkVisibleLines()
        let visibleSet = Set(visible)
        state.pages = state.pages.filter {
            visibleSet.contains($0.key)
        }
        state.refused = state.refused.filter {
            visibleSet.contains($0.key)
        }
        if state.task != nil, state.requested.isDisjoint(with: visibleSet) {
            // 已离开原请求视口时不等待旧页占用通道，旧任务即使随后返回也没有发布票据。
            state.task?.cancel()
            state.task = nil
            state.taskID = nil
            state.requested = []
        }
        state.status =
            visible.compactMap {
                state.refused[$0]
            }.first
        guard state.task == nil else {
            return
        }
        var requests: [(Int, ByteRange)] = []
        var bytes = 0
        for line in visible where state.pages[line] == nil && state.refused[line] == nil {
            let range = snapshot.text.lineRange(line)
            guard range.count <= 65_536 else {
                state.refused[line] = "当前行超过 64 KiB，链接识别暂停；正文保持可编辑。"
                continue
            }
            if requests.count == 128 || range.count > 262_144 - bytes {
                break
            }
            requests.append((line, range))
            bytes += range.count
        }
        state.status =
            visible.compactMap {
                state.refused[$0]
            }.first
        guard !requests.isEmpty else {
            return
        }
        let generation = state.generation
        let ticket = UUID()
        state.taskID = ticket
        state.requested = Set(requests.map(\.0))
        startTextLinkAnalysis(
            snapshot: snapshot,
            settings: settings,
            requests: requests,
            key: key,
            generation: generation,
            ticket: ticket
        )
    }

    /// 业务作用：当前批次在后台准备完整行，返回后复验文档实例和不可变根，迟到结果不能重新授予点击权限。
    /// 参数说明:
    /// - snapshot: 本批次固定的不可变正文。
    /// - settings: 当前完整协议和显示定义。
    /// - requests: 已按当前视口及容量限制选择的物理行与范围。
    /// - key: 原视图的实际文档及配置来源。
    /// - generation: 本次仍有发布资格的来源代次。
    /// - ticket: 当前唯一批次票据。
    /// 返回：完整且来源保持的页被发布；取消或来源变化不产生页或悬停目标，单行失败独立说明。
    private func startTextLinkAnalysis(
        snapshot: DocumentSnapshot,
        settings: TextLinkSettings,
        requests: [(Int, ByteRange)],
        key: EditorTextLinkSource,
        generation: UUID,
        ticket: UUID
    ) {
        let state = textLinks
        state.task = Task {
            [weak self] in
            guard let self else {
                return
            }
            defer {
                if state.taskID == ticket {
                    state.task = nil
                    state.taskID = nil
                    state.requested = []
                }
            }
            let worker = Task.detached(priority: .utility) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var result: [EditorTextLinkResponse] = []
                for (line, range) in requests {
                    try Task.checkCancellation()
                    do {
                        let page = try DocumentTextLinkPage(
                            snapshot: snapshot,
                            range: range,
                            settings: settings,
                            deadline: deadline
                        )
                        result.append(EditorTextLinkResponse(line: line, page: page, reason: nil))
                    }
                    catch is CancellationError {
                        throw CancellationError()
                    }
                    catch {
                        result.append(
                            EditorTextLinkResponse(line: line, page: nil, reason: error.localizedDescription)
                        )
                    }
                }
                return result
            }
            do {
                let pages = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 同编号及同修订仍可能属于重新建立的缓冲区，实例、根、配置和票据必须共同保持。
                guard !Task.isCancelled, state.generation == generation, state.taskID == ticket,
                    state.source == key, ObjectIdentifier(self.document) == key.document,
                    self.document.id == snapshot.id, self.document.revision == snapshot.revision,
                    self.document.text.sourceIdentity == snapshot.text.sourceIdentity,
                    self.textLinkSettings == settings
                else {
                    return
                }
                let visible = Set(self.textLinkVisibleLines())
                for response in pages where visible.contains(response.line) {
                    state.pages[response.line] = response.page
                    state.refused[response.line] = response.reason
                }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
            catch {
                guard !Task.isCancelled, state.generation == generation, state.taskID == ticket else {
                    return
                }
                state.status = "链接识别已暂停，正文保持：" + error.localizedDescription
                self.needsDisplay = true
            }
        }
    }
}
