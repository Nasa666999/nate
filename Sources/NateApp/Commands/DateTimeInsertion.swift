import AppKit
import NateCore

extension ApplicationController {
    /// 业务作用：先确认真实正文与输入权限，再把一次固定时刻的完整结果交给统一输入事务。
    /// 参数说明:
    /// - mode: 短日期时间、长日期时间或用户自定义格式。
    /// 返回：全部光标插入同一完整文本且只产生普通输入历史；失败不删除原选择。
    func insertDateTime(_ mode: DateTimeInsertionMode) {
        guard !closing else {
            return
        }
        // 未能进入正文的候选不能被日期文字覆盖；确认失败时原地保留组合与原选择。
        guard mainWindow?.editor.finishComposition() != false,
            let (_, _, editor) = quickFindContext(), !editor.document.isReadOnly
        else {
            return
        }
        let date = Date()
        let settings = currentDateTimeSettings()
        do {
            let output = try settings.formatted(date: date, mode: mode)
            _ = insert(output)
        }
        catch {
            mainWindow?.status.stringValue = "日期时间未插入：" + error.localizedDescription
        }
    }
}
