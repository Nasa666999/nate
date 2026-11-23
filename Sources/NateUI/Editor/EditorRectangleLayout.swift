import AppKit
import CryptoKit
import NateCore

extension EditorView {
    /// 业务作用：为原生矩形取得可跨重启比较的实际字体、容器和样式证据，不依赖进程内对象身份。
    /// 参数说明: 无。
    /// 返回：当前参数有效时的布局上下文；超量或非法字体参数为空，不能授权视觉列修改。
    var currentRectangleLayoutContext: RectangleLayoutContext? {
        try? RectangleLayoutContext(
            fontName: font.fontName,
            pointSize: Double(font.pointSize),
            fontTraits: UInt32(truncatingIfNeeded: font.fontDescriptor.symbolicTraits.rawValue),
            layoutWidth: Double(nativeBodyLayoutWidth),
            rightToLeft: rtl,
            styleIdentity: rectangleStyleIdentity
        )
    }

    /// 业务作用：矩形视觉修改只沿原生布局证据执行，缺失或改变的上下文不能静默改选其它字节。
    /// 参数说明: 无。
    /// 返回：原生矩形没有有效布局绑定或当前排版已不一致时为真，普通选择为假。
    public var hasStaleRectangleLayout: Bool {
        guard let state = viewSelectionState, case .rectangle(let shape) = state.shape else {
            return false
        }
        guard let original = shape.layoutContext, let current = currentRectangleLayoutContext else {
            return true
        }
        return shape.needsRevalidation || original != current || !shape.hasCompleteProjections
            || shape.zeroWidth && abs(shape.anchorX - shape.headX) >= 0.5
    }

    /// 业务作用：布局改变后的矩形仍保留完整身份和形态，但必须明确重新定义边缘后才能进行视觉修改。
    /// 参数说明: 无。
    /// 返回：需要重新选择时的具体说明，否则为空。
    public var rectangleLayoutStatus: String? {
        hasStaleRectangleLayout ? "矩形的字体、版面或样式已改变，请重新选择矩形边缘；原范围与身份保留。" : nil
    }

    /// 业务作用：所有原生列准备共用同一门禁，无法证明当前像素仍代表原列时不取得修改权。
    /// 参数说明: 无。
    /// 返回：普通选择或矩形上下文完全一致时继续，否则明确失败且不改正文或选择。
    func requireCurrentRectangleLayout() throws {
        // 像素必须仍代表原字节和列；布局缺失或已变化时拒绝新修改，不选择任何近似正文。
        if let status = rectangleLayoutStatus {
            throw NateError.message(status)
        }
    }

    /// 业务作用：显式程序化选择可把尚无原生上下文的逻辑矩形绑定到当前视图，既有证据不能被隐式重授。
    /// 参数说明:
    /// - state: 调用方明确提供的完整新选择。
    /// 返回：保留所有身份、方向与边缘的状态；既有布局原样保留，非法当前参数时拒绝首次绑定。
    func bindingRectangleLayout(_ state: SelectionState) throws -> SelectionState {
        guard case .rectangle(let shape) = state.shape else {
            return state
        }
        // 保留的旧正文形态不是一次新选择，重新安装视图不能自动恢复其视觉修改权。
        if shape.needsRevalidation {
            return state
        }
        guard !shape.zeroWidth || abs(shape.anchorX - shape.headX) < 0.5 else {
            throw NateError.message("零宽矩形必须具有同一原生视觉边缘。")
        }
        guard let context = currentRectangleLayoutContext else {
            throw NateError.message("当前字体或版面不具备合法矩形布局证据。")
        }
        if let original = shape.layoutContext, original != context {
            return state
        }
        _ = try state.validated(in: document.text)
        let entries = Dictionary(
            uniqueKeysWithValues: state.entries.map {
                ($0.id, $0)
            }
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var edges: [SelectionVirtualEdge] = []
        for edge in shape.edges {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, let entry = entries[edge.selectionID] else {
                throw NateError.message("矩形实际边缘绑定超时或身份缺失，原选择保留。")
            }
            let actual = try rectangleSourceProjection(entry, shape: shape)
            _ = try actual.validated(for: entry.selection, in: document.text)
            // 既有真实范围不能在字形变化后被重新授权；明确的新几何可以首次取得完整投影。
            guard edge.projection == nil || edge.projection == actual else {
                throw NateError.message("矩形字形边缘已经改变，请重新选择；原范围与身份保留。")
            }
            edges.append(
                try SelectionVirtualEdge(
                    selectionID: edge.selectionID,
                    leadingColumns: edge.leadingColumns,
                    trailingColumns: edge.trailingColumns,
                    projection: actual
                )
            )
        }
        return try state.usingShape(
            .rectangle(
                RectangleSelectionShape(
                    anchorX: shape.anchorX,
                    headX: shape.headX,
                    zeroWidth: shape.zeroWidth,
                    edges: edges,
                    anchorID: shape.anchorID,
                    headID: shape.headID,
                    layoutContext: context
                )
            )
        )
    }

    /// 业务作用：逐行准备通过稳定身份取得原投影，不为十万行逐项扫描完整边缘数组。
    /// 参数说明:
    /// - id: 原选择行的稳定身份。
    /// 返回：现存原行的实际投影；新扩展目标或普通选择为空，不授予其它行的权限。
    func existingRectangleProjection(_ id: UUID) -> RectangleEditProjection? {
        if rectangleProjectionGeneration != selectionGeneration {
            if let state = viewSelectionState, case .rectangle(let shape) = state.shape {
                rectangleProjectionCache = Dictionary(
                    uniqueKeysWithValues: shape.edges.compactMap {
                        edge in
                        edge.projection.map {
                            (edge.selectionID, $0)
                        }
                    }
                )
            }
            else {
                rectangleProjectionCache = [:]
            }
            rectangleProjectionGeneration = selectionGeneration
        }
        return rectangleProjectionCache[id]
    }

    /// 业务作用：实际字形可能在异步着色后改变，逐行复验真实范围与 Tab 保留列，不能沿原像素删除其它内容。
    /// 参数说明:
    /// - actual: 当前原生排版取得的完整实际投影。
    /// - entry: 同一行的明确逻辑目标，新扩展行尚无既有编辑证据。
    /// 返回：原目标投影一致或属于本次明确新扩展目标时继续；不一致保留全部正文与原选择。
    func verifyRectangleProjection(_ actual: RectangleEditProjection, for entry: SelectionEntry) throws {
        _ = try actual.validated(for: entry.selection, in: document.text)
        if let expected = existingRectangleProjection(entry.id), actual != expected {
            throw NateError.message("矩形真实字节或 Tab 边缘已随字形改变，请重新选择；原内容保留。")
        }
    }

    /// 业务作用：实际样式资源与视图缩放形成稳定摘要，资源往返也先收回后台视觉动作的发布权。
    /// 参数说明: 无。
    /// 返回：更新当前原生字体样式及缩放身份，读取次数不随绘制帧数重复放大。
    func updateRectangleStyleIdentity() {
        var hash = SHA256()
        hash.update(data: Data("NateRectangleStyles".utf8))
        hash.update(data: EditorNativeLayoutPolicy.identityData)
        hash.update(data: Data("tabWidth=\(tabSettings.width)".utf8))
        hash.update(data: Data("fontZoom=\(fontZoomAdjustment)".utf8))
        if let editorTheme {
            hash.update(data: Data(editorTheme.identity.utf8))
        }
        for data in [languageResource ?? Data(), userLanguage?.originalXML ?? Data()] {
            hash.update(data: Data(String(data.count).utf8))
            hash.update(data: Data([0]))
            hash.update(data: data)
        }
        if let userLanguage {
            UDLResourceIdentity.update(userLanguage, hash: &hash)
        }
        let digest = hash.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        if digest != rectangleStyleIdentity {
            // 后台复制和粘贴仍依赖旧字形，资源恢复原值不能复活已经失权的请求。
            clipboard.cancel()
            rectangleStyleIdentity = digest
        }
    }
}
