import Foundation
import NateCore
import NateStorage

struct ProjectSearchPanelCapture: Sendable {
    let index: Int
    let workspace: ProjectWorkspace
    let definitionPath: String?
    let selectedPaths: Set<Data>
}

struct ProjectSearchReference: Sendable {
    let path: String
    let needsConsent: Bool
}

struct ProjectSearchReferenceSet: Sendable {
    let references: [ProjectSearchReference]
    let failures: [String]
}

enum ProjectSearchReferenceResolver {
    /// 业务作用：大项目定义在独立队列中只做字符串解释，原始引用顺序与点目录语义保持不变。
    /// 参数说明:
    /// - captures: 当前所选面板的完整不可变定义及已有位置选择。
    /// - filters: 当前完整文件名过滤条件。
    /// - token: 当前解析任务的取消权限。
    /// 返回：无文件访问能力的绝对路径和逐项解释失败；取消或失败容量超限终止整个未授权计划。
    static func resolve(
        _ captures: [ProjectSearchPanelCapture],
        filters: String,
        token: CancellationToken
    ) throws -> ProjectSearchReferenceSet {
        try token.check()
        // 项目没有共同物理根，目录排除不能被悄悄解释为虚拟分组或任意磁盘层级。
        guard
            !filters.split(whereSeparator: \.isWhitespace).contains(where: {
                $0.hasPrefix("!\\") || $0.hasPrefix("!+\\")
            })
        else {
            throw NateError.message("项目范围按实际文件名包含和排除；目录排除规则请在文件中查找使用。")
        }
        var references: [ProjectSearchReference] = []
        var failures: [String] = []
        for capture in captures {
            try token.check()
            for node in capture.workspace.files {
                try token.check()
                do {
                    let path = try ProjectReferencePath.absolute(
                        node.path ?? "",
                        relativeTo: capture.definitionPath
                    )
                    references.append(
                        ProjectSearchReference(
                            path: path,
                            needsConsent: ProjectReferencePath.referencesVolume(path)
                                && !capture.selectedPaths.contains(Data(path.utf8))
                        )
                    )
                }
                catch {
                    failures.append(
                        "面板 \(capture.index + 1) · \(label(node.name))：\(error.localizedDescription)"
                    )
                    guard failures.count <= 10_000 else {
                        throw NateError.message("未解释引用超过 10000 项，请缩小项目范围；文件未读取。")
                    }
                }
            }
        }
        return ProjectSearchReferenceSet(references: references, failures: failures)
    }

    /// 业务作用：失败和授权提示只使用有界单行摘要，完整引用独立保留并参与实际路径解释。
    /// 参数说明:
    /// - raw: 文件名或原始引用位置。
    /// 返回：至多 240 个原文字符构成的单行摘要，不作为文件身份或访问路径。
    static func label(_ raw: String) -> String {
        String(raw.prefix(240))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "\\0")
    }
}
