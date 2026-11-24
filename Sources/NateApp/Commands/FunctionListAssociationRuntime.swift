import Foundation
import NateCore
import NatePlatform
import NateStorage
import NateSyntax

@MainActor
final class FunctionListAssociationRuntime {
    struct Entry {
        let generation = UUID()
        let value: UserFunctionListAssociations?
        let baseline: DiskBaseline?
        var diagnostic: String? = nil
    }

    enum Change {
        case importing(URL, expecting: UUID)
        case edit(Data, expecting: UUID)
        case reload
        case restore(expecting: UUID)
    }

    var entry = Entry(value: nil, baseline: nil)
    var ready = false
    var busy = false
}

extension ApplicationController {
    /// 业务作用：启动恢复最后完整保存的关联，解析失败时保留原磁盘证据和随包定义。
    /// 参数说明: 无。
    /// 返回：可用用户映射或实际失败说明；任何损坏组合都不会作为导航规则启用。
    func loadFunctionListAssociations() async {
        guard let applicationSupport, !functionListAssociations.ready, !functionListAssociations.busy else {
            return
        }
        functionListAssociations.busy = true
        defer {
            functionListAssociations.busy = false
            functionListAssociations.ready = true
        }
        let store = FunctionListAssociationStore(directory: applicationSupport)
        do {
            let disk = try await readIO.readCancellable { token in
                try store.load(permit: { !token.isCancelled })
            }
            let bundled = functionListCatalog
            let entry: FunctionListAssociationRuntime.Entry
            do {
                let value = try await readIO.readCancellable { token in
                    try disk?.data.map {
                        try UserFunctionListAssociations.restoring(
                            $0,
                            bundled: bundled,
                            permit: { !token.isCancelled }
                        )
                    }
                }
                entry = .init(value: value, baseline: disk?.baseline)
            }
            catch is CancellationError {
                throw CancellationError()
            }
            catch {
                entry = .init(value: nil, baseline: disk?.baseline, diagnostic: error.localizedDescription)
            }
            try Task.checkCancellation()
            guard !closing, self.applicationSupport == applicationSupport else {
                return
            }
            functionListAssociations.entry = entry
            if let diagnostic = entry.diagnostic {
                SystemIntegration.alert("函数列表关联未载入", diagnostic)
            }
        }
        catch is CancellationError {}
        catch {
            SystemIntegration.alert("函数列表关联未载入", error.localizedDescription)
        }
    }

    /// 业务作用：导入、编辑、重读和恢复都按原操作资格校验，只有完整归档可靠持久化才发布。
    /// 参数说明:
    /// - change: 本次用户确认的来源、操作和打开界面时的代次。
    /// 返回：实际生效的用户关联状态；过期、无效、冲突或取消时仍使用原导航规则。
    func changeFunctionListAssociations(_ change: FunctionListAssociationRuntime.Change) async throws {
        guard let applicationSupport, functionListAssociations.ready, !functionListAssociations.busy,
            !closing, mainWindow?.hasMarkedEditorInput != true
        else {
            throw NateError.message("当前不能应用函数列表关联。")
        }
        let old = functionListAssociations.entry
        switch change {
        case .importing(_, let generation), .edit(_, let generation), .restore(let generation):
            guard generation == old.generation else {
                throw NateError.message("函数列表关联已经改变，请重新打开。")
            }
        case .reload:
            break
        }
        functionListAssociations.busy = true
        defer {
            functionListAssociations.busy = false
        }
        let store = FunctionListAssociationStore(directory: applicationSupport)
        let bundled = functionListCatalog
        let value: UserFunctionListAssociations?
        var baseline = old.baseline
        switch change {
        case .importing(let url, _):
            let access = fileAccess
            value = try await readIO.readCancellable { token in
                let permit: @Sendable () -> Bool = { !token.isCancelled }
                return try access.withRead(at: url, permit: permit) { coordinated in
                    try UserFunctionListAssociations.importing(coordinated, bundled: bundled, permit: permit)
                }
            }
        case .edit(let data, _):
            let rules = old.value?.archive.rules ?? [:]
            value = try await readIO.readCancellable { token in
                try UserFunctionListAssociations(
                    .init(map: data, rules: rules),
                    bundled: bundled,
                    permit: { !token.isCancelled }
                )
            }
        case .reload:
            let disk = try await readIO.readCancellable { token in
                try store.load(permit: { !token.isCancelled })
            }
            baseline = disk?.baseline
            value = try await readIO.readCancellable { token in
                try disk?.data.map {
                    try UserFunctionListAssociations.restoring(
                        $0,
                        bundled: bundled,
                        permit: { !token.isCancelled }
                    )
                }
            }
        case .restore:
            value = nil
        }
        // 文件选择或解析等待期间可能开始关闭，原支持目录或归档代次变化必须撤回此次写入资格。
        try Task.checkCancellation()
        guard !closing, self.applicationSupport == applicationSupport,
            functionListAssociations.entry.generation == old.generation,
            functionListCatalog?.generation == bundled?.generation, mainWindow?.hasMarkedEditorInput != true
        else {
            throw NateError.message("函数列表关联的来源已经改变，未应用。")
        }
        if case .reload = change {
            // 重读尚未提交持久化副作用，解析期间再次改写会撤销本轮读到的组合。
            let loaded = baseline
            let current = try await readIO.readCancellable { token in
                try store.load(permit: { !token.isCancelled })?.baseline
            }
            guard current == loaded, !closing, self.applicationSupport == applicationSupport,
                functionListCatalog?.generation == bundled?.generation
            else {
                throw NateError.message("函数列表关联已改变，请重新载入。")
            }
        }
        else {
            let expected = baseline
            baseline = try await fileIO.run {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try value.map { try encoder.encode($0.archive) }
                return try store.publish(data, expected: expected)
            }
        }
        // 持久化返回后只向原支持目录发布，已成功写入的完整归档由下次启动正常读取。
        guard self.applicationSupport == applicationSupport else {
            throw NateError.message("关联已写入原支持目录，请从当前目录重新载入。")
        }
        functionListAssociations.entry = .init(value: value, baseline: baseline)
        invalidateFunctionLists(for: nil)
    }

    /// 业务作用：语言独立设置之外先应用用户关联和同层规则，再查询随包映射及文件名回退。
    /// 参数说明:
    /// - language: 编辑文档真实语言标识。
    /// 返回：生效的原 XML 定义和必要的用户编译结果，供导航与独立资源菜单使用相同来源。
    func mappedFunctionList(
        for language: String
    ) -> (definition: FunctionListDefinition, prepared: PreparedFunctionList?)? {
        functionListAssociations.entry.value?.resolution(for: language, bundled: functionListCatalog)
            ?? functionListCatalog?.definition(for: language).map { ($0, nil) }
    }
}
