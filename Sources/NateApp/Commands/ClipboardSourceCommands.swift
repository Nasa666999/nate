import AppKit
import NateCore
import NateStorage
import NateUI

extension ApplicationController {
    /// 业务作用：源码剪贴板只使用应用随包代码页，编辑视图不自行寻找系统或网络编码资源。
    /// 参数说明:
    /// - window: 当前明确连接的工作区。
    /// 返回：全部编辑视图使用固定严格解码来源，不读取系统剪贴板内容。
    func connectClipboardSource(_ window: EditorWindow) {
        let catalog = codecs
        window.setClipboardMarkupDecoder {
            data,
            format,
            deadline in
            try ClipboardMarkupSource.decode(data, format: format, catalog: catalog, deadline: deadline)
        }
    }
}
