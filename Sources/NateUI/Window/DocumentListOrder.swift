import Foundation

public enum DocumentListOrder: String, CaseIterable, Sendable {
    case tabOrder
    case name
    case fileExtension
    case path

    /// 业务作用：工具栏与窗口菜单对同一排序选项采用相同名称。
    /// 参数说明: 无。
    /// 返回：可显示于原生排序菜单的用户名称。
    var title: String {
        switch self {
        case .tabOrder: return "标签顺序"
        case .name: return "名称"
        case .fileExtension: return "扩展名"
        case .path: return "路径"
        }
    }

    /// 业务作用：用原始名称和路径排序可见文档，保存标记、同名目录说明和标签顺序仍由原身份决定。
    /// 参数说明:
    /// - tabs: 当前窗口按标签顺序提供的完整呈现。
    /// 返回：采用系统自然比较的显示顺序，无路径或扩展名的文档排在对应列表末尾，同键保留标签顺序。
    func sorted(_ tabs: [TabPresentation]) -> [TabPresentation] {
        guard self != .tabOrder else {
            return tabs
        }
        let entries = tabs.enumerated().map {
            (index: $0.offset, tab: $0.element, key: key(for: $0.element))
        }
        return entries.sorted {
            left,
            right in
            switch (left.key, right.key) {
            case (nil, .some): return false
            case (.some, nil): return true
            case (.some(let lhs), .some(let rhs)):
                let order = lhs.localizedStandardCompare(rhs)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
            case (nil, nil): break
            }
            return left.index < right.index
        }.map(\.tab)
    }

    /// 业务作用：为每个文档提取一份排序键，未命名文档的显示名仍可参与名称及扩展名排序。
    /// 参数说明:
    /// - tab: 保留原始名称、路径及身份的文档呈现。
    /// 返回：当前字段的原值，没有适用字段时为空。路径与扩展名只读取现有元数据。
    private func key(for tab: TabPresentation) -> String? {
        switch self {
        case .tabOrder: return nil
        case .name: return tab.title
        case .fileExtension:
            let fileExtension = ((tab.path ?? tab.title) as NSString).pathExtension
            return fileExtension.isEmpty ? nil : fileExtension
        case .path: return tab.path
        }
    }
}
