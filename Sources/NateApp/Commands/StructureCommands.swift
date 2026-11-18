import AppKit
import NateCore
import NateSearch
import NateSyntax

extension ApplicationController {
    /// 业务作用：显示或关闭函数侧栏，独立结构资源决定可用能力。
    /// 参数说明: 无。
    /// 返回：可见时自动跟随当前文档；无规则或解析失败在侧栏明确反馈。
    func showSymbols() {
        guard let window = mainWindow else {
            return
        }
        if window.isStructureVisible {
            closeStructure()
        }
        else {
            window.setStructureVisible(true)
            requestStructure(force: true)
        }
    }

    /// 业务作用：取消并撤销旧结构请求，旧范围不能继续作为导航权威。
    /// 参数说明: 无。
    /// 返回：任务代次失效，现有编辑和恢复任务不受影响。
    func cancelStructure() {
        structureTask?.cancel()
        structureTask = nil
        structureGeneration = UUID()
        structureRequestKey = nil
        mainWindow?.structurePanel.onNavigate = nil
    }

    /// 业务作用：关闭侧栏时立即结束计算并释放结构快照。
    /// 参数说明: 无。
    /// 返回：编辑区域重新使用侧栏空间，文档继续打开。
    func closeStructure() {
        cancelStructure()
        mainWindow?.structurePanel.showState("")
        mainWindow?.setStructureVisible(false)
    }

    /// 业务作用：当前正文与规则代次变化后在后台解析，迟到结果只能发布到原文档修订。
    /// 参数说明:
    /// - force: 是否忽略同一请求的去重，供用户显式刷新。
    /// 返回：异步更新侧栏，主线程不运行正则或复制全文。
    func requestStructure(force: Bool = false) {
        guard !closing, let document = active, let window = mainWindow, window.isStructureVisible else {
            return
        }
        let language = document.language
        let catalogGeneration = functionListCatalog?.generation
        let key =
            "\(document.buffer.id):\(document.buffer.revision):\(language):\(catalogGeneration?.uuidString ?? "")"
        guard force || key != structureRequestKey else {
            return
        }
        cancelStructure()
        structureRequestKey = key
        guard let definition = functionListCatalog?.definition(for: language) else {
            window.structurePanel.showState("当前语言没有适用的函数列表规则。")
            return
        }
        let generation = structureGeneration
        let snapshot = document.buffer.snapshot
        window.structurePanel.showState("正在解析 \(definition.displayName)…")
        structureTask = Task {
            [weak self, weak document, weak window] in
            guard let self, let document, let window else {
                return
            }
            do {
                if !force {
                    try await Task.sleep(for: .milliseconds(180))
                }
                let worker = Task.detached(priority: .userInitiated) {
                    guard snapshot.text.byteCount <= 64 * 1024 * 1024 else {
                        throw NateError.message("函数列表正文超过 64 MB 预算。")
                    }
                    try Task.checkCancellation()
                    let input = PreparedSearchInput(snapshot: snapshot)
                    return try FunctionListEngine.analyze(snapshot: snapshot, definition: definition) {
                        expression,
                        scope,
                        firstOnly in
                        var options = SearchOptions()
                        options.mode = .regex
                        options.query = expression
                        options.dotMatchesNewline = true
                        return try input.find(
                            options: options,
                            scope: scope,
                            firstOnly: firstOnly,
                            allowEmpty: false
                        )
                        .hits.map {
                            guard let range = $0.range else {
                                throw NateError.invalidRange
                            }
                            return range
                        }
                    }
                }
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
                // 文档关闭、语言切换和资源重载都撤销旧任务的导航范围，不能只比较正文内容。
                guard generation == self.structureGeneration, self.active === document,
                    !document.closing, document.buffer.revision == snapshot.revision,
                    document.language == language, self.functionListCatalog?.generation == catalogGeneration,
                    window.isStructureVisible
                else {
                    return
                }
                window.structurePanel.update(result, detail: definition.displayName + " · 双击或回车定位")
                window.structurePanel.onNavigate = {
                    [weak self, weak document, weak window] range in
                    guard let self, let document, let window else {
                        return
                    }
                    // 候选尚未安全进入正文时，后续动作会丢失输入或沿旧坐标操作，确认失败必须原地停止。
                    guard window.editor.finishComposition() else {
                        return
                    }
                    // 输入法确认可能提交新修订，定位前必须再次核验而不能把旧范围夹紧后使用。
                    guard self.active === document, document.buffer.revision == result.revision,
                        document.language == language, generation == self.structureGeneration,
                        !document.closing
                    else {
                        self.requestStructure(force: true)
                        return
                    }
                    window.window?.makeFirstResponder(window.editor)
                    window.editor.viewSelections = [TextSelection(anchor: range.lower, head: range.upper)]
                    window.editor.refresh(reveal: true)
                    self.refreshUI()
                }
            }
            catch is CancellationError {}
            catch {
                if generation == self.structureGeneration, window.isStructureVisible {
                    window.structurePanel.showState("函数列表未完成：" + error.localizedDescription)
                }
            }
        }
    }
}
