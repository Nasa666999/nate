import Foundation
import NateCore

public enum MacroActionPresentation {
    /// 业务作用：用可辨认的动作名称展示宏内容，摘要不把控制字符当成空动作。
    /// 参数说明:
    /// - action: 一个完整语义动作。
    /// 返回：用于列表的有界说明；完整内容另由详情读取。
    public static func summary(_ action: MacroAction) -> String {
        switch action {
        case .completion(let command):
            let preview = String(String.UnicodeScalarView(command.replacement.unicodeScalars.prefix(60)))
            return "确认补全 · " + visible(preview)
        case .pairInput(let command):
            return "配对输入：" + visible(command.input) + " · "
                + visible(command.pair.opening + command.pair.closing)
        case .clipboardCopy(let cutting, let line):
            return (cutting ? "剪切" : "复制") + "当前选择" + (line ? " · 无选区时整行" : " · 无选区时不复制整行")
        case .search(let search):
            let name = searchName(search.command)
            let preview = String(String.UnicodeScalarView(search.options.query.unicodeScalars.prefix(60)))
            return name + " · " + search.options.mode.rawValue + " · " + visible(preview)
        case .editor(let command):
            return "编辑动作：" + editorName(command)
        case .input(let text):
            let preview = String(String.UnicodeScalarView(text.unicodeScalars.prefix(60)))
            return "输入 " + visible(preview)
        case .command(let name):
            if let title = BookmarkAction(rawValue: name)?.macroTitle {
                return title
            }
            if let navigation = BracketNavigation(rawValue: name) {
                return navigation.title
            }
            if let quickFind = QuickFindAction(rawValue: name) {
                return quickFind.title
            }
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
        case .completion(let command):
            return "确认补全\n使用播放时当前光标之前的相同原始前缀。\n\n前缀：\n" + visible(command.prefix)
                + "\n\n确认原文：\n" + visible(command.replacement)
        case .pairInput(let command):
            return "配对输入\n实际字符：" + visible(command.input) + "\n开端：" + visible(command.pair.opening)
                + "\n闭合：" + visible(command.pair.closing) + "\n越过已有闭合符：\(command.skipExisting)"
                + "\n播放采用此完整定义；全部普通选择一次提交，失败时停止后续动作。"
        case .clipboardCopy(let cutting, let line):
            return (cutting ? "剪切" : "复制") + "播放时的完整当前选择\n无普通选区时复制主光标整行：\(line)"
                + "\n成功写入系统剪贴板后才" + (cutting ? "提交删除事务并继续。" : "继续后续动作。")
        case .search(let search):
            let options = search.options
            return searchName(search.command) + "\n模式：" + options.mode.rawValue
                + "\n区分大小写：\(options.caseSensitive)\n全词：\(options.wholeWord)\n点匹配换行：\(options.dotMatchesNewline)"
                + "\n循环：\(options.wrap)\n反向：\(options.backwards)\n仅选区：\(options.selectionOnly)\n替换后停留：\(search.stayAfterReplace)"
                + "\n匹配上限：\(options.maxMatches)\n计算上限：\(options.stepLimit)"
                + "\n递归目录：\(options.recursive)\n隐藏文件：\(options.includeHidden)\n忽略打开缓冲区：\(options.ignoreOpenBuffers)（目录选项不用于当前文档动作）"
                + "\n\n查找原文：\n" + visible(options.query) + "\n\n替换原文：\n" + visible(options.replacement)
        case .editor(let command):
            return "编辑动作：" + editorName(command) + "\n标识：" + command.rawValue
        case .input(let text):
            return "输入 · \(text.utf8.count) 字节\n\n" + visible(text)
        case .command(let name):
            if let title = BookmarkAction(rawValue: name)?.macroTitle {
                return title + "\n使用播放时的当前文档、书签集合及主光标。"
            }
            if let navigation = BracketNavigation(rawValue: name) {
                return navigation.title + "\n使用播放时的正文、语言和主光标。"
            }
            if let quickFind = QuickFindAction(rawValue: name) {
                let options =
                    quickFind.isVolatile
                    ? "保留查找条件与历史，忽略大小写、允许子串并循环。"
                    : "更新当前查询与历史，采用当前大小写、整词与循环选项。"
                return quickFind.title + "\n查找播放时的实际选区或完整光标词。\n" + options
            }
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

    /// 业务作用：方向、选择和删除详情展示实际语义，避免用选择器或光标坐标掩盖执行内容。
    /// 参数说明:
    /// - command: 当前受支持的原生编辑动作。
    /// 返回：不依赖键位配置的中文动作名称。
    private static func editorName(_ command: EditorCommand) -> String {
        switch command {
        case .deleteBackward: return "向前退格"
        case .insertTab: return "按当前规则输入 Tab"
        case .backTab: return "退 Tab 或减少缩进"
        case .insertNewline: return "按当前规则逐光标换行"
        case .insertMarkupTagEnd: return "输入标签结束符并按当前语言闭合"
        case .insertOpeningBrace: return "输入左花括号并按当前语言对齐"
        case .insertClosingBrace: return "输入右花括号并按当前语言对齐"
        case .insertOpeningBracket: return "输入左方括号并按当前语言对齐"
        case .insertClosingBracket: return "输入右方括号并按当前语言对齐"
        case .insertClosingParenthesis: return "输入右圆括号并按当前语言对齐"
        case .deleteForward: return "向后删除"
        case .moveLeft: return "左移一个字形"
        case .moveRight: return "右移一个字形"
        case .moveUp: return "上移一个可见行"
        case .moveDown: return "下移一个可见行"
        case .extendLeft: return "向左扩展一个字形"
        case .extendRight: return "向右扩展一个字形"
        case .extendUp: return "向上扩展一个可见行"
        case .extendDown: return "向下扩展一个可见行"
        case .lineStart: return "移到逻辑行首"
        case .lineEnd: return "移到逻辑行尾"
        case .extendLineStart: return "扩展到逻辑行首"
        case .extendLineEnd: return "扩展到逻辑行尾"
        case .documentStart: return "移到文档开头"
        case .documentEnd: return "移到文档末尾"
        case .extendDocumentStart: return "扩展到文档开头"
        case .extendDocumentEnd: return "扩展到文档末尾"
        case .wordLeft: return "移到前一个词边界"
        case .wordRight: return "移到后一个词边界"
        case .extendWordLeft: return "向前扩展到词边界"
        case .extendWordRight: return "向后扩展到词边界"
        case .selectAll: return "全选正文"
        case .collapseSelection: return "只保留主选区"
        }
    }

    /// 业务作用：搜索预览明确区分导航、单项替换和整批替换，防止只看表达式而误判修改范围。
    /// 参数说明:
    /// - command: 当前文档搜索动作。
    /// 返回：实际执行范围的中文名称。
    private static func searchName(_ command: MacroSearchCommand) -> String {
        switch command {
        case .next: return "查找下一处"
        case .previous: return "查找上一处"
        case .replaceOne: return "替换当前完整匹配"
        case .replaceAll: return "替换当前文档全部适用匹配"
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
