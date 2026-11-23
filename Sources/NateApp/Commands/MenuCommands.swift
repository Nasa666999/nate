import AppKit
import NateCore
import NatePlatform
import NateStorage
import NateUI

extension ApplicationController: NSMenuItemValidation {
    /// 业务作用：建立共享命令菜单，键盘、工具栏和上下文调用同一业务入口。
    /// 参数说明: 无。
    /// 返回：适配 macOS 应用菜单并保持熟悉的编辑器功能分组。
    func buildMenus() {
        let bar = NSMenu()
        let application = NSMenu(title: "Nate")
        add(application, "关于 Nate", "about")
        add(application, "设置…", "preferences", key: ",")
        add(application, "样式与主题…", "themePreferences")
        add(application, "补全与参数提示…", "assistancePreferences")
        add(application, "Tab 与缩进…", "tabPreferences")
        add(application, "自动缩进与退格…", "indentationPreferences")
        add(application, "括号与引号配对…", "pairPreferences")
        add(application, "词字符与边界…", "wordBoundaryPreferences")
        add(application, "分隔符选择…", "delimiterSelectionPreferences")
        add(application, "日期时间格式…", "dateTimePreferences")
        add(application, "文件与新建默认设置…", "fileOpeningPreferences")
        add(application, "搜索引擎…", "webSearchPreferences")
        add(application, "导入用户配置…", "importUserConfiguration")
        add(application, "导出用户配置…", "exportUserConfiguration")
        add(application, "取消配置读写", "cancelUserConfiguration")
        add(application, "保存时备份设置…", "saveBackupPreferences")
        add(application, "恢复存储设置…", "recoveryStoragePreferences")
        add(application, "快捷键映射器…", "keyboardMap")
        application.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏 Nate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        application.addItem(hide)
        add(application, "退出 Nate", "quit", key: "q")
        attach(application, to: bar)
        let file = NSMenu(title: "文件")
        for (title, id, key) in [
            ("新建", "new", "n"), ("打开…", "open", "o"), ("立即保存", "save", "s"),
            ("另存为…", "saveAs", "S"), ("保存副本…", "saveCopy", ""), ("全部保存", "saveAll", ""),
            ("重新载入", "reload", ""), ("重命名…", "rename", ""), ("移到废纸篓…", "trash", ""),
            ("关闭", "close", "w"), ("关闭全部", "closeAll", ""), ("关闭其他", "closeOthers", ""),
            ("关闭未修改文档", "closeClean", ""), ("关闭非固定文档", "closeUnpinned", ""),
            ("恢复最近关闭", "reopenClosed", "T"), ("保存会话…", "saveSession", ""), ("打开会话…", "openSession", ""),
            ("页面设置…", "pageSetup", ""), ("打印…", "print", "p"),
            ("打印选区…", "printSelection", ""), ("立即打印", "printImmediately", ""),
            ("打印设置…", "printSettings", ""),
        ] {
            add(file, title, id, key: key)
        }
        let recent = NSMenu(title: "最近文件")
        add(file, "恢复已关闭临时内容…", "recoveryArchive")
        add(file, "恢复先前保留工作区…", "pausedWorkspaces")
        add(file, "取消保留工作区导入", "cancelPausedWorkspaceImport")
        add(file, "打开保存前备份…", "savedBackups")
        for path in recentFiles {
            add(recent, path, "recent:" + path)
        }
        add(recent, "打开全部最近文件", "openAllRecent")
        add(recent, "清空历史", "clearRecent")
        attach(recent, to: file)
        attach(file, to: bar)
        let edit = NSMenu(title: "编辑")
        add(edit, "撤销", "undo", key: "z")
        add(edit, "搜索选区或当前词", "searchOnInternet")
        add(edit, "重做", "redo", key: "Z")
        add(edit, "取消历史动作准备", "cancelHistoryAction")
        for (title, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSResponder.selectAll(_:)), "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        add(edit, "剪贴板历史…", "clipboardHistory")
        add(edit, "清空剪贴板历史", "clearClipboardHistory")
        add(edit, "无选区复制与剪切整行", "clipboardCopyLine")
        add(edit, "粘贴换行适配当前文档", "clipboardAdaptEndings")
        add(edit, "粘贴为纯文本", "pasteAsPlainText", key: "V")
        let specialPaste = NSMenu(title: "特殊粘贴与二进制")
        for (title, id) in [
            ("粘贴 HTML 源码", "pasteHTMLSource"), ("粘贴 RTF 源码", "pasteRTFSource"),
            ("复制二进制内容", "copyBinary"), ("剪切二进制内容", "cutBinary"),
            ("粘贴二进制内容", "pasteBinary"),
        ] {
            add(specialPaste, title, id)
        }
        attach(specialPaste, to: edit)
        add(edit, "取消剪贴板准备", "cancelClipboard")
        let cases = NSMenu(title: "大小写")
        for (title, command) in [
            ("大写", TextCommand.uppercase), ("小写", .lowercase), ("首字母大写", .titlecase),
            ("句首大写", .sentencecase), ("反转大小写", .invertCase), ("随机大小写", .randomCase),
            ("掩盖为块字符", .maskBlocks), ("掩盖为圆点", .maskDots),
        ] {
            add(cases, title, "edit:" + command.rawValue)
        }
        attach(cases, to: edit)
        let lines = NSMenu(title: "行操作与排序")
        for (title, command) in [
            ("复制行或选区", TextCommand.duplicate), ("删除行", .deleteLines), ("合并行", .joinLines),
            ("删除重复行", .uniqueLines), ("删除连续重复行", .uniqueAdjacent),
        ] {
            add(lines, title, "edit:" + command.rawValue)
        }
        let sorts = NSMenu(title: "排序整行")
        for (kind, title) in [
            (LineSortKind.lexicographic, "字符序"), (.ignoringCase, "忽略大小写"),
            (.locale, "区域规则（\(Locale.current.identifier)）"), (.integer, "带符号整数片段"),
            (.decimalComma, "逗号小数"), (.decimalDot, "点号小数"), (.length, "行长度"),
        ] {
            add(sorts, title + "升序", "sort:" + kind.rawValue + ":asc")
            add(sorts, title + "降序", "sort:" + kind.rawValue + ":desc")
        }
        add(sorts, "反转行序", "sort:reverse:asc")
        add(sorts, "随机行序", "sort:random:asc")
        add(sorts, "完整排序选项…", "lineSort")
        add(sorts, "取消排序准备", "cancelLineSort")
        attach(sorts, to: lines)
        add(lines, "上移行", "moveLineUp")
        add(lines, "下移行", "moveLineDown")
        add(lines, "上方插入空行", "blankAbove")
        add(lines, "下方插入空行", "blankBelow")
        attach(lines, to: edit)
        let whitespace = NSMenu(title: "空白与缩进")
        for (title, command) in [
            ("删除行首空白", TextCommand.trimLeading), ("删除行尾空白", .trimTrailing),
            ("两端裁剪", .trimBoth), ("删除空行", .removeEmpty), ("删除仅含空白的行", .removeBlank),
            ("Tab 转空格", .tabsToSpaces), ("行首空格转 Tab", .leadingSpacesToTabs), ("增加缩进", .indent),
            ("减少缩进", .outdent),
        ] {
            add(whitespace, title, "edit:" + command.rawValue)
        }
        attach(whitespace, to: edit)
        add(edit, "切换行注释", "comment", key: "/")
        add(edit, "块注释", "blockComment")
        add(edit, "列编辑器…", "columnEditor")
        add(edit, "取消列编辑计算", "cancelColumnEditor")
        let rectangle = NSMenu(title: "矩形扩展")
        for (title, id, code) in [
            ("向左", "rectangleLeft", NSLeftArrowFunctionKey),
            ("向右", "rectangleRight", NSRightArrowFunctionKey),
            ("向上", "rectangleUp", NSUpArrowFunctionKey),
            ("向下", "rectangleDown", NSDownArrowFunctionKey),
        ] {
            add(rectangle, title, id, key: UnicodeScalar(code).map(String.init) ?? "")
            rectangle.items.last?.keyEquivalentModifierMask = [.control, .option, .shift]
        }
        attach(rectangle, to: edit)
        add(edit, "补全文档与语言", "complete")
        add(edit, "补全文档单词", "completeWords")
        add(edit, "补全语言关键字与函数", "completeLanguage")
        add(edit, "函数参数提示", "signature")
        add(edit, "手动补全路径", "completePath")
        add(edit, "选择全部匹配", "selectMatches")
        add(edit, "追加下一个匹配", "addMatch", key: "d")
        add(edit, "跳过当前匹配", "skipMatch")
        add(edit, "撤回最近选区", "removeMatchSelection", key: "d")
        edit.items.last?.keyEquivalentModifierMask = [.command, .shift]
        add(edit, "多选匹配区分大小写", "multipleSelectionCase")
        add(edit, "多选匹配仅全词", "multipleSelectionWord")
        add(edit, "取消多选匹配计算", "cancelMultipleSelection")
        add(edit, "插入短日期时间", "dateTimeShort")
        add(edit, "插入长日期时间", "dateTimeLong")
        add(edit, "插入自定义日期时间", "dateTime")
        add(edit, "插入 / 覆盖", "overwrite")
        attach(edit, to: bar)
        let search = NSMenu(title: "搜索")
        add(search, "增量查找", "incrementalSearch", key: "i")
        search.items.last?.keyEquivalentModifierMask = [.command, .option]
        add(search, "选中并查找下一处", "selectFindNext", key: "e")
        add(search, "选中并查找上一处", "selectFindPrevious", key: "e")
        search.items.last?.keyEquivalentModifierMask = [.command, .shift]
        add(search, "临时查找下一处", "volatileFindNext", key: "e")
        search.items.last?.keyEquivalentModifierMask = [.command, .option]
        add(search, "临时查找上一处", "volatileFindPrevious", key: "e")
        search.items.last?.keyEquivalentModifierMask = [.command, .option, .shift]
        add(search, "取消快捷查找", "cancelQuickFind")
        add(search, "跳转到匹配括号", "matchingBracket", key: "b")
        add(search, "选择整对括号", "selectBracketPair", key: "b")
        search.items.last?.keyEquivalentModifierMask = [.command, .option]
        add(search, "选择括号内部", "selectInsideBracket", key: "B")
        add(search, "选择配置分隔符内部", "selectConfiguredDelimiters")
        search.addItem(.separator())
        for (title, id, key) in [
            ("查找…", "find", "f"), ("替换…", "replace", "H"), ("文件中查找…", "findFiles", "F"),
            ("项目中查找…", "findProjects", ""),
            ("下一个匹配", "findNext", "g"), ("上一个匹配", "findPrevious", "G"), ("跳转行…", "goto", "l"),
            ("切换书签", "bookmark", ""), ("下一个书签", "nextBookmark", ""), ("上一个书签", "previousBookmark", ""),
            ("清空书签", "clearBookmarks", ""), ("反转书签", "invertBookmarks", ""), ("复制书签行", "copyBookmarks", ""),
            ("删除书签行", "deleteBookmarks", ""), ("删除非书签行", "deleteUnbookmarked", ""),
            ("剪切书签行", "cutBookmarks", ""), ("用剪贴板替换书签行", "replaceBookmarks", ""),
            ("取消书签行操作", "cancelBookmarkAction", ""),
        ] {
            add(search, title, id, key: key)
        }
        addStyleMarkMenus(to: search)
        addSelectedTextHighlightMenus(to: search)
        attach(search, to: bar)
        let view = NSMenu(title: "视图")
        for (title, id) in [
            ("自动换行", "wrap"), ("显示符号", "symbols"), ("放大", "zoomIn"), ("缩小", "zoomOut"),
            ("重置缩放", "zoomReset"), ("浅色主题", "themeLight"), ("深色主题", "themeDark"), ("系统主题", "themeSystem"),
            ("左右分屏 / 克隆", "splitVertical"), ("上下分屏 / 克隆", "splitHorizontal"), ("关闭分屏", "unsplit"),
            ("垂直同步滚动", "syncVerticalScroll"), ("水平同步滚动", "syncHorizontalScroll"),
            ("从右到左", "rtl"), ("固定标签", "pin"), ("编辑器只读", "readOnly"), ("监视文件", "monitor"),
            ("打开目录工作区…", "folder"), ("刷新目录工作区", "refreshFolder"), ("关闭目录工作区", "closeFolder"),
            ("项目面板 1", "projectPanel:0"), ("项目面板 2", "projectPanel:1"), ("项目面板 3", "projectPanel:2"),
            ("搜索结果", "showSearchResults"), ("工具输出", "showToolOutput"), ("隐藏结果区域", "hideResults"),
            ("函数列表", "symbolsList"), ("文档统计", "statistics"), ("全屏", "fullscreen"),
        ] {
            add(view, title, id)
        }
        addTabLayoutMenu(to: view)
        view.addItem(.separator())
        for (title, id, key, shifted) in [
            ("收起当前块", "foldCurrent", "[", false),
            ("展开当前块", "unfoldCurrent", "]", false),
            ("全部收起", "foldAll", "[", true),
            ("全部展开", "unfoldAll", "]", true),
        ] {
            add(view, title, id, key: key)
            view.items.last?.keyEquivalentModifierMask =
                shifted ? [.command, .option, .shift] : [.command, .option]
        }
        let levels = NSMenu(title: "按层级收起")
        for level in 1...8 {
            add(levels, "第 \(level) 层", "foldLevel:\(level)")
        }
        attach(levels, to: view)
        attach(view, to: bar)
        let encoding = NSMenu(title: "编码")
        let convert = NSMenu(title: "转换为编码")
        let reinterpret = NSMenu(title: "以编码重新解释")
        for (index, item) in TextEncoding.available.enumerated() {
            add(convert, item.name, "encoding:\(index)")
            add(reinterpret, item.name, "reinterpret:\(index)")
        }
        attach(convert, to: encoding)
        attach(reinterpret, to: encoding)
        add(encoding, "转换换行为 LF", "edit:eolLF")
        add(encoding, "转换换行为 CRLF", "edit:eolCRLF")
        add(encoding, "转换换行为 CR", "edit:eolCR")
        attach(encoding, to: bar)
        let language = NSMenu(title: "语言")
        add(language, "新建 UDL…", "newUDL")
        add(language, "导入 UDL XML…", "importUDL")
        add(language, "编辑 / 重命名当前 UDL…", "editUDL")
        add(language, "复制当前 UDL…", "duplicateUDL")
        add(language, "导出当前 UDL…", "exportUDL")
        add(language, "删除当前自定义 UDL…", "deleteUDL")
        language.addItem(.separator())
        add(language, "自动识别", "detectLanguage")
        for definition in registry?.languages ?? [] where definition.id != "searchResult" {
            add(language, definition.name, "language:" + definition.id)
        }
        attach(language, to: bar)
        let tools = NSMenu(title: "工具")
        add(tools, "文件写入任务…", "fileTasks")
        add(tools, "重新保存当前侧栏恢复状态", "resetSidebarRecovery")
        add(tools, "取消文件读取", "cancelReads")
        add(tools, "取消外部命令", "cancelExternalCommand")
        add(tools, "上次外部命令结果", "lastExternalOutput")
        add(tools, "取消文本工具转换", "cancelTextTool")
        add(tools, "取消文档比较", "cancelDocumentComparison")
        for (title, id) in [
            ("JSON 格式化", "tool:json"), ("XML 格式化", "tool:xml"),
            ("ASCII / UTF-8 转 HEX", "tool:hexEncode"), ("HEX 转文本 / 原字节", "tool:hexDecode"),
            ("HEX 转换格式…", "hexConversionSettings"),
            ("导出 HTML…", "exportHTML"), ("导出 RTF…", "exportRTF"), ("Markdown 预览", "markdownPreview"),
            ("文档比较…", "compare"), ("字符与进制转换…", "characterConverter"),
        ] {
            add(tools, title, id)
        }
        for algorithm in DigestAlgorithm.allCases {
            let menu = NSMenu(title: algorithm.title + " 摘要")
            add(menu, "直接输入文本…", "digest:\(algorithm.rawValue):text")
            add(menu, "按行独立文本…", "digest:\(algorithm.rawValue):lines")
            add(menu, "多个磁盘文件…", "digest:\(algorithm.rawValue):files")
            add(menu, "当前选区到剪贴板", "digest:\(algorithm.rawValue):selection")
            add(menu, "当前选区或全文到剪贴板", "tool:\(algorithm.rawValue)")
            attach(menu, to: tools)
        }
        let mime = NSMenu(title: "MIME 编解码")
        for (title, id) in [
            ("Base64 编码（带填充）", "tool:base64Encode"),
            ("Base64 编码（无填充）", "tool:base64EncodeUnpadded"),
            ("Base64 编码（64 列 LF）", "tool:base64EncodeWrapped"),
            ("Base64 逐行编码", "tool:base64EncodeByLine"),
            ("Base64 严格解码", "tool:base64Decode"),
            ("Base64 分段解码（保留分隔符）", "tool:base64DecodeSegments"),
            ("Base64 逐行解码", "tool:base64DecodeByLine"),
            ("Quoted-Printable 编码", "tool:quotedPrintableEncode"),
            ("Quoted-Printable 解码", "tool:quotedPrintableDecode"),
            ("URL 编码（RFC 3986）", "tool:urlEncode"),
            ("URL 编码（RFC 1738）", "tool:urlEncodeRFC1738"),
            ("URL 编码（扩展）", "tool:urlEncodeExtended"),
            ("URL 编码（全部字节）", "tool:urlEncodeFull"),
            ("URL 逐行编码（RFC 1738）", "tool:urlEncodeRFC1738ByLine"),
            ("URL 逐行编码（扩展）", "tool:urlEncodeExtendedByLine"),
            ("URL 逐行编码（全部字节）", "tool:urlEncodeFullByLine"),
            ("URL 解码", "tool:urlDecode"),
            ("SAML 解码（URL / Base64 / DEFLATE）", "tool:samlDecode"),
        ] {
            add(mime, title, id)
        }
        attach(mime, to: tools)
        attach(tools, to: bar)
        let macro = NSMenu(title: "宏")
        for (title, id) in [
            ("开始 / 停止录制", "recordMacro"), ("播放一次", "playMacro"), ("重复执行…", "repeatMacro"),
            ("运行至文档末尾", "macroUntilEnd"),
            ("停止播放", "cancelMacro"),
            ("命名宏管理…", "macroLibrary"), ("保存当前录制为命名宏…", "saveNamedMacro"),
            ("查看已载入宏…", "previewMacro"),
            ("保存宏…", "saveMacro"), ("载入宏…", "loadMacro"),
        ] {
            add(macro, title, id)
        }
        attach(macro, to: bar)
        let run = NSMenu(title: "运行")
        add(run, "一次运行…", "run")
        add(run, "命名运行配置…", "runCommands")
        attach(run, to: bar)
        let windows = NSMenu(title: "窗口")
        add(windows, "下一个标签", "nextTab")
        add(windows, "上一个标签", "previousTab")
        add(windows, "文档列表…", "documentList")
        windows.delegate = self
        populateWindowDocuments(in: windows)
        attach(windows, to: bar)
        NSApp.windowsMenu = windows
        let help = NSMenu(title: "帮助")
        add(help, "使用说明", "help")
        attach(help, to: bar)
        installKeyboardMap(in: bar)
        appendMacroLibraryMenu(to: macro, root: bar)
        appendRunCommandMenu(to: run, root: bar)
        NSApp.mainMenu = bar
    }

    /// 业务作用：将独立功能组接到上层菜单。
    /// 参数说明:
    /// - menu: 功能组。
    /// - parent: 上层菜单。
    /// 返回：增加具名子菜单。
    func attach(_ menu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
    }

    /// 业务作用：所有编辑器菜单动作携带稳定命令标识。
    /// 参数说明:
    /// - menu: 所属菜单。
    /// - title: 用户名称。
    /// - id: 共享动作标识。
    /// - key: macOS 快捷键，大小写大写表示 Shift。
    /// 返回：可由统一路由校验的菜单项。
    func add(_ menu: NSMenu, _ title: String, _ id: String, key: String = "") {
        let item = NSMenuItem(
            title: title,
            action: #selector(menuAction(_:)),
            keyEquivalent: key.lowercased()
        )
        item.keyEquivalentModifierMask = key != key.lowercased() ? [.command, .shift] : [.command]
        item.target = self
        item.representedObject = id
        menu.addItem(item)
    }

    /// 业务作用：菜单动作进入与工具栏一致的分发入口。
    /// 参数说明:
    /// - sender: 携带命令标识的菜单项。
    /// 返回：执行同一范围与状态合同。
    @objc func menuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            // 动态列表只拥有生成时的标签集合与布局，旧菜单不能先确认候选再发现目标已经改变。
            if id.hasPrefix("activate:"), !validateMenuItem(sender) {
                mainWindow?.status.stringValue = "文档列表已改变，请重新打开后选择。"
                return
            }
            route(id)
        }
    }

    /// 业务作用：菜单启用与选中状态反映当前焦点和编辑权限。
    /// 参数说明:
    /// - menuItem: 待验证项目。
    /// 返回：只读文档不能执行正文写入，查找框撤销保持自身上下文。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let id = menuItem.representedObject as? String else {
            return true
        }
        if id.hasPrefix("activate:") {
            let fields =
                menuItem.identifier?.rawValue.split(separator: ".", omittingEmptySubsequences: false) ?? []
            guard let documentID = UUID(uuidString: String(id.dropFirst("activate:".count))),
                fields.count == 2, let source = UUID(uuidString: String(fields[0])),
                UUID(uuidString: String(fields[1])) == documentID,
                source == mainWindow?.tabOrderIdentity,
                documents.contains(where: {
                    $0.buffer.id == documentID
                })
            else {
                return false
            }
            menuItem.state = documentID == activeID ? .on : .off
            return !closing
        }
        if id == "documentList" {
            return !closing && mainWindow != nil && !documents.isEmpty
        }
        if id.hasPrefix("tabLayout:") {
            guard let mode = DocumentTabLayout(rawValue: String(id.dropFirst("tabLayout:".count))) else {
                return false
            }
            menuItem.state = mainWindow?.documentTabLayout == mode ? .on : .off
            return !closing && mainWindow != nil
        }
        if id.hasPrefix("savedRun:") {
            return !closing && runCommands.ready && runCommands.task == nil
                && runCommands.prepareTask == nil && runCommands.importTask == nil
                && externalCommandTask == nil && active != nil
                && runCommands.library.commands.contains(where: {
                    "savedRun:" + $0.id.uuidString == id
                })
        }
        if let enabled = validateClipboardMenu(menuItem, id: id) {
            return enabled
        }
        if id == "cancelTextTool" {
            return textTools.task != nil || digests.task != nil
        }
        if id == "characterConverter" || id == "hexConversionSettings" {
            return !closing && mainWindow?.hasMarkedEditorInput != true
        }
        if id.hasPrefix("digest:") {
            guard !closing, mainWindow?.hasMarkedEditorInput != true else {
                return false
            }
            if id.hasSuffix(":selection") {
                guard textTools.task == nil, let (_, _, editor) = quickFindContext(),
                    let state = editor.viewSelectionState, state.entries.count == 1,
                    case .stream = state.shape, let entry = state.entries.first,
                    !entry.selection.range.isEmpty, entry.selection.virtualColumn == 0
                else {
                    return false
                }
                return true
            }
            return digests.task == nil
        }
        if ["print", "printImmediately", "printSelection", "printSettings", "pageSetup"].contains(id) {
            guard !closing, !printing.busy, let document = active, !document.closing,
                !document.buffer.isEditingSuspended, mainWindow?.hasMarkedEditorInput == false
            else {
                return false
            }
            if id == "printSelection" {
                guard let (_, _, editor) = quickFindContext(), let state = editor.viewSelectionState,
                    state.entries.count == 1, case .stream = state.shape,
                    let entry = state.entries.first, !entry.selection.range.isEmpty,
                    entry.selection.virtualColumn == 0
                else {
                    return false
                }
            }
            return true
        }
        if id.hasPrefix("tool:") {
            let digest = ["tool:md5", "tool:sha1", "tool:sha256", "tool:sha512"].contains(id)
            guard textTools.task == nil, let (document, _, editor) = quickFindContext(),
                digest || !document.buffer.isReadOnly,
                let state = editor.viewSelectionState, state.entries.count == 1,
                case .stream = state.shape, state.entries.first?.selection.virtualColumn == 0
            else {
                return false
            }
            return true
        }
        if let enabled = validateMacroMenu(menuItem, id: id) {
            return enabled
        }
        if id == "resetSidebarRecovery" {
            return !closing && recovery != nil && !sidebarRecovery.loading && sidebarRecovery.task == nil
        }
        if id == "pausedWorkspaces" {
            return !closing && applicationSupport != nil && pausedWorkspace.task == nil
        }
        if id == "cancelPausedWorkspaceImport" {
            return !closing && pausedWorkspace.task != nil && !pausedWorkspace.published
        }
        if id == "columnEditor" {
            return !closing && columnEditing.task == nil && quickFindContext() != nil
                && active?.buffer.isReadOnly == false
        }
        if ["rectangleLeft", "rectangleRight", "rectangleUp", "rectangleDown"].contains(id) {
            return !closing && quickFindContext()?.2.canExtendRectangle == true
        }
        if id == "cancelColumnEditor" {
            return columnEditing.task != nil
        }
        if id == "cancelLineSort" {
            return lineSorting.task != nil
        }
        if id == "lineSort" || id.hasPrefix("sort:") {
            return lineSorting.task == nil && quickFindContext() != nil && active?.buffer.isReadOnly == false
        }
        if id == "cancelHistoryAction" {
            return historyAction.task != nil
        }
        if let enabled = validateStyleMarkMenu(menuItem, id: id) {
            return enabled
        }
        if let enabled = validateBookmarkMenu(id) {
            return enabled
        }
        if let enabled = validateSelectedTextHighlightMenu(menuItem, id: id) {
            return enabled
        }
        if let enabled = validateQuickFindMenu(id) {
            return enabled
        }
        if id == "searchOnInternet" {
            return webSearchAvailable()
        }
        if let enabled = validateConfigurationAndComparisonMenu(id) {
            return enabled
        }
        if let enabled = validateScrollSynchronizationMenu(menuItem, id: id) {
            return enabled
        }
        if let enabled = validateMultipleSelectionMenu(menuItem, id: id) {
            return enabled
        }
        if let action = foldAction(for: id) {
            guard !closing, let window = mainWindow, NSApp.keyWindow === window.window,
                let editor = NSApp.keyWindow?.firstResponder as? EditorView, editor === window.editor
            else {
                return false
            }
            return editor.foldingAvailable(action)
        }
        if ["matchingBracket", "selectBracketPair", "selectInsideBracket"].contains(id) {
            guard !closing, let window = mainWindow, NSApp.keyWindow === window.window,
                let editor = NSApp.keyWindow?.firstResponder as? EditorView, editor === window.editor,
                !editor.document.isEditingSuspended
            else {
                return false
            }
            switch id {
            case "matchingBracket": return editor.bracketNavigationAvailable(.jump)
            case "selectBracketPair": return editor.bracketNavigationAvailable(.selectPair)
            default: return editor.bracketNavigationAvailable(.selectInside)
            }
        }
        if id.hasPrefix("language:") {
            menuItem.state = active?.language == String(id.dropFirst(9)) ? .on : .off
        }
        if id == "readOnly" {
            menuItem.state = active?.buffer.isReadOnly == true ? .on : .off
        }
        if id == "wrap" {
            menuItem.state = mainWindow?.editor.wrapLines == true ? .on : .off
        }
        if id == "symbols" {
            menuItem.state = mainWindow?.editor.showSymbols == true ? .on : .off
        }
        if id == "symbolsList" {
            menuItem.state = mainWindow?.isStructureVisible == true ? .on : .off
        }
        if id == "cancelExternalCommand" {
            return externalCommandTask != nil
        }
        if id == "lastExternalOutput" {
            return lastExternalOutput != nil
        }
        if id == "undo" {
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo
                ?? (historyAction.task == nil && quickFindContext() != nil && active?.buffer.canUndo == true)
        }
        if id == "redo" {
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo
                ?? (historyAction.task == nil && quickFindContext() != nil && active?.buffer.canRedo == true)
        }
        if id.hasPrefix("edit:") || ["comment", "blockComment", "columnEditor"].contains(id) {
            return active?.buffer.isReadOnly == false
        }
        if ["trash", "rename", "reload", "monitor"].contains(id) {
            return active?.url != nil
        }
        return true
    }
}
