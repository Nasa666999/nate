import Foundation
import NateCore

public enum MacroActionPresentation {
    /// 业务作用：用可辨认的动作名称展示宏内容，摘要不把控制字符当成空动作。
    /// 参数说明:
    /// - action: 一个完整语义动作。
    /// 返回：用于列表的有界说明；完整内容另由详情读取。
    public static func summary(_ action: MacroAction) -> String {
        switch action {
        case .input(let text):
            let preview = String(String.UnicodeScalarView(text.unicodeScalars.prefix(60)))
            return "输入 " + visible(preview)
        case .command(let name):
            return "文本命令：" + (commandNames[name] ?? name)
        case .lineSort(let options):
            let direction =
                options.kind == .random || options.kind == .reverse
                ? "" : (options.descending ? " · 降序" : " · 升序")
            return "整行排序：" + sortName(options.kind) + direction
        case .clipboard(let payload, let adapting):
            let kind: String
            switch payload.shape {
            case .stream: kind = "片段"
            case .lines: kind = "整行"
            case .rectangle: kind = "矩形"
            }
            return "粘贴\(kind) · \(payload.fragments.count) 项" + (adapting ? " · 适配换行" : "")
        }
    }

    /// 业务作用：显示选中动作的完整原文和真实参数，不展开尚未进入正文的虚拟空白。
    /// 参数说明:
    /// - action: 当前明确查看的完整动作。
    /// 返回：包含原始 Unicode、NUL 与换行身份的只读详情，不取得播放资格。
    public static func detail(_ action: MacroAction) -> String {
        switch action {
        case .input(let text):
            return "输入 · \(text.utf8.count) 字节\n\n" + visible(text)
        case .command(let name):
            return "文本命令：" + (commandNames[name] ?? name) + "\n标识：" + name
        case .lineSort(let options):
            let direction =
                options.kind == .random || options.kind == .reverse
                ? "不适用" : (options.descending ? "降序" : "升序")
            let locale = options.localeIdentifier + (options.kind == .locale ? "" : "（当前类型不使用区域比较）")
            return "整行排序\n类型：\(sortName(options.kind))\n方向：\(direction)\n语言地区：\(locale)"
        case .clipboard(let payload, _):
            var value =
                "\(summary(action))\n主项：\(payload.primaryIndex + 1)\n换行：\(payload.lineEnding.rawValue)\n"
            for (index, fragment) in payload.fragments.enumerated() {
                value +=
                    "\n片段 \(index + 1) · 文档顺序 \(fragment.documentOrder + 1) · \(fragment.reversed ? "反向" : "正向")\n"
                value += "定位空白 \(fragment.virtualStart) 列 · 选中尾部 \(fragment.virtualTail) 列\n"
                value += visible(fragment.text) + "\n"
            }
            return value
        }
    }

    /// 业务作用：仅预览标明控制字符身份，不修改宏载荷或实际插入内容。
    /// 参数说明:
    /// - text: 所属动作的原文。
    /// 返回：保留真实换行布局的可见表示。
    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\0", with: "␀")
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\n", with: "↵\n")
    }

    /// 业务作用：排序预览使用与编辑任务一致的用户名称，不用协议标识代替实际比较规则。
    /// 参数说明:
    /// - kind: 已验证的排序类型。
    /// 返回：明确区分字符、语言、数值和直接行重排的中文名称。
    private static func sortName(_ kind: LineSortKind) -> String {
        switch kind {
        case .lexicographic: return "字符顺序"
        case .ignoringCase: return "忽略大小写"
        case .locale: return "语言地区规则"
        case .integer: return "带符号整数片段"
        case .decimalComma: return "逗号小数"
        case .decimalDot: return "点号小数"
        case .length: return "行长度"
        case .reverse: return "反转行序"
        case .random: return "随机行序"
        }
    }

    private static let commandNames: [String: String] = [
        "uppercase": "大写", "lowercase": "小写", "titlecase": "词首大写", "sentencecase": "句首大写",
        "invertCase": "反转大小写", "randomCase": "随机大小写", "trimLeading": "去行首空白",
        "trimTrailing": "去行尾空白", "trimBoth": "去两端空白", "removeEmpty": "移除空行",
        "removeBlank": "移除空白行", "joinLines": "合并行", "tabsToSpaces": "Tab 转空格",
        "spacesToTabs": "空格转 Tab", "leadingSpacesToTabs": "行首空格转 Tab", "sortAscending": "升序排序",
        "sortDescending": "降序排序", "sortIgnoringCase": "忽略大小写排序", "sortNumeric": "整数片段排序",
        "sortLength": "按行长度排序", "reverseLines": "反转行序", "shuffleLines": "随机行序",
        "uniqueLines": "去除重复行", "uniqueAdjacent": "去除相邻重复行", "duplicate": "复制选择或整行",
        "deleteLines": "删除整行", "moveUp": "上移行", "moveDown": "下移行", "insertAbove": "上方插入行",
        "insertBelow": "下方插入行", "indent": "增加缩进", "outdent": "减少缩进", "eolLF": "转换为 LF",
        "eolCRLF": "转换为 CRLF", "eolCR": "转换为 CR", "maskBlocks": "掩盖为块字符", "maskDots": "掩盖为圆点",
    ]
}
