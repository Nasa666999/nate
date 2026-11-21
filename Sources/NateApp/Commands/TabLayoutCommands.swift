import AppKit
import NateCore

private struct TabLayoutArchive: Codable {
    let format: Int
    let layout: DocumentTabLayout
}

extension ApplicationController {
    /// 业务作用：完整读取独立标签布局偏好，未知或损坏内容保留原值并明确采用水平布局。
    /// 参数说明: 无。
    /// 返回：已验证的布局；读取失败不覆盖归档或影响正文保存。
    func currentDocumentTabLayout() -> DocumentTabLayout {
        let domain = tabPreferences.defaults ?? .standard
        tabPreferences.layoutWarning = nil
        guard let object = domain.object(forKey: "documentTabLayout") else {
            return .horizontal
        }
        do {
            guard let data = object as? Data, data.count <= 1024,
                let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(fields.keys) == ["format", "layout"]
            else {
                throw NateError.message("标签布局不是完整的 1 KiB 以内归档。")
            }
            let archive = try JSONDecoder().decode(TabLayoutArchive.self, from: data)
            guard archive.format == 1 else {
                throw NateError.message("标签布局格式尚不受支持。")
            }
            return archive.layout
        }
        catch {
            tabPreferences.layoutWarning = "标签布局未被读取，原归档保留；本次采用水平布局。" + error.localizedDescription
            return .horizontal
        }
    }

    /// 业务作用：明确选择一个布局后保存整份偏好，并在当前窗口原位应用。
    /// 参数说明:
    /// - layout: 用户通过共享命令选择的合法布局。
    /// 返回：完整编码后一次保存；失败保留原偏好与窗口布局，正文及候选不被提交。
    func chooseDocumentTabLayout(_ layout: DocumentTabLayout) {
        guard !closing, let window = mainWindow else {
            return
        }
        do {
            let data = try JSONEncoder().encode(
                TabLayoutArchive(
                    format: 1,
                    layout: layout
                )
            )
            (tabPreferences.defaults ?? .standard).set(data, forKey: "documentTabLayout")
            tabPreferences.layoutWarning = nil
            window.setDocumentTabLayout(layout)
            refreshUI()
        }
        catch {
            window.status.stringValue = "标签布局未保存：" + error.localizedDescription
        }
    }

    /// 业务作用：视图菜单以共享稳定指令提供三个实际布局，键盘映射和菜单使用相同入口。
    /// 参数说明:
    /// - parent: 当前视图菜单。
    /// 返回：加入具名标签布局子菜单，不创建空功能入口。
    func addTabLayoutMenu(to parent: NSMenu) {
        let menu = NSMenu(title: "标签栏布局")
        for (name, mode) in [("水平", DocumentTabLayout.horizontal), ("垂直", .vertical), ("多行", .multiline)] {
            add(menu, name, "tabLayout:" + mode.rawValue)
        }
        attach(menu, to: parent)
    }
}
