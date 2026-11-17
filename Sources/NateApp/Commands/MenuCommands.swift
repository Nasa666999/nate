import AppKit
import NateCore
import NatePlatform
import NateStorage

extension ApplicationController: NSMenuItemValidation {
    /// 业务作用：建立共享命令菜单，键盘、工具栏和上下文调用同一业务入口。
    /// 参数说明: 无。
    /// 返回：适配 macOS 应用菜单并保持熟悉的编辑器功能分组。
    func buildMenus() {
        let bar = NSMenu()
        let application = NSMenu(title: "Nate")
        add(application, "关于 Nate", "about")
        add(application, "设置…", "preferences", key: ",")
        add(application, "补全与参数提示…", "assistancePreferences")
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
        ] {
            add(file, title, id, key: key)
        }
        let recent = NSMenu(title: "最近文件")
        add(file, "恢复已关闭临时内容…", "recoveryArchive")
        add(file, "恢复先前保留工作区…", "pausedWorkspaces")
        for path in recentFiles {
            add(recent, path, "recent:" + path)
        }
        add(recent, "打开全部最近文件", "openAllRecent")
        add(recent, "清空历史", "clearRecent")
        attach(recent, to: file)
        attach(file, to: bar)
        let edit = NSMenu(title: "编辑")
        add(edit, "撤销", "undo", key: "z")
        add(edit, "重做", "redo", key: "Z")
        for (title, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSResponder.selectAll(_:)), "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        add(edit, "剪贴板历史…", "clipboardHistory")
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
            ("字符升序", .sortAscending), ("字符降序", .sortDescending), ("忽略大小写排序", .sortIgnoringCase),
            ("数值排序", .sortNumeric), ("按行长度排序", .sortLength), ("反转行序", .reverseLines),
            ("随机行序", .shuffleLines), ("删除重复行", .uniqueLines), ("删除连续重复行", .uniqueAdjacent),
        ] {
            add(lines, title, "edit:" + command.rawValue)
        }
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
        add(edit, "补全文档与语言", "complete")
        add(edit, "补全文档单词", "completeWords")
        add(edit, "补全语言关键字与函数", "completeLanguage")
        add(edit, "函数参数提示", "signature")
        add(edit, "手动补全路径", "completePath")
        add(edit, "选择全部匹配", "selectMatches")
        add(edit, "追加下一个匹配", "addMatch", key: "d")
        add(edit, "插入日期时间", "dateTime")
        add(edit, "插入 / 覆盖", "overwrite")
        attach(edit, to: bar)
        let search = NSMenu(title: "搜索")
        for (title, id, key) in [
            ("查找…", "find", "f"), ("替换…", "replace", "H"), ("文件中查找…", "findFiles", "F"),
            ("下一个匹配", "findNext", "g"), ("上一个匹配", "findPrevious", "G"), ("跳转行…", "goto", "l"),
            ("切换书签", "bookmark", ""), ("下一个书签", "nextBookmark", ""), ("上一个书签", "previousBookmark", ""),
            ("清空书签", "clearBookmarks", ""), ("反转书签", "invertBookmarks", ""), ("复制书签行", "copyBookmarks", ""),
            ("删除书签行", "deleteBookmarks", ""), ("删除非书签行", "deleteUnbookmarked", ""),
        ] {
            add(search, title, id, key: key)
        }
        attach(search, to: bar)
        let view = NSMenu(title: "视图")
        for (title, id) in [
            ("自动换行", "wrap"), ("显示符号", "symbols"), ("放大", "zoomIn"), ("缩小", "zoomOut"),
            ("重置缩放", "zoomReset"), ("浅色主题", "themeLight"), ("深色主题", "themeDark"), ("系统主题", "themeSystem"),
            ("左右分屏 / 克隆", "splitVertical"), ("上下分屏 / 克隆", "splitHorizontal"), ("关闭分屏", "unsplit"),
            ("从右到左", "rtl"), ("固定标签", "pin"), ("编辑器只读", "readOnly"), ("监视文件", "monitor"),
            ("打开目录工作区…", "folder"), ("函数列表", "symbolsList"), ("文档统计", "statistics"), ("全屏", "fullscreen"),
        ] {
            add(view, title, id)
        }
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
        add(tools, "取消文件读取", "cancelReads")
        for (title, id) in [
            ("JSON 格式化", "tool:json"), ("XML 格式化", "tool:xml"), ("Base64 编码", "tool:base64Encode"),
            ("Base64 解码", "tool:base64Decode"), ("URL 编码", "tool:urlEncode"), ("URL 解码", "tool:urlDecode"),
            ("文本转 HEX", "tool:hexEncode"), ("HEX 转文本", "tool:hexDecode"), ("MD5 摘要", "tool:md5"),
            ("SHA-1 摘要", "tool:sha1"), ("SHA-256 摘要", "tool:sha256"), ("SHA-512 摘要", "tool:sha512"),
            ("导出 HTML…", "exportHTML"), ("导出 RTF…", "exportRTF"), ("Markdown 预览", "markdownPreview"),
            ("文档比较…", "compare"), ("字符与进制转换…", "characterConverter"),
        ] {
            add(tools, title, id)
        }
        attach(tools, to: bar)
        let macro = NSMenu(title: "宏")
        for (title, id) in [
            ("开始 / 停止录制", "recordMacro"), ("播放一次", "playMacro"), ("重复执行…", "repeatMacro"),
            ("保存宏…", "saveMacro"), ("载入宏…", "loadMacro"), ("运行外部命令…", "run"),
        ] {
            add(macro, title, id)
        }
        attach(macro, to: bar)
        let windows = NSMenu(title: "窗口")
        add(windows, "下一个标签", "nextTab")
        add(windows, "上一个标签", "previousTab")
        for document in documents {
            add(windows, document.name, "activate:" + document.buffer.id.uuidString)
        }
        attach(windows, to: bar)
        NSApp.windowsMenu = windows
        let help = NSMenu(title: "帮助")
        add(help, "使用说明", "help")
        attach(help, to: bar)
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
        if id == "recordMacro" {
            menuItem.state = macroRecording ? .on : .off
        }
        if id == "playMacro" {
            return !macroRecording && !macroActions.isEmpty
        }
        if id == "undo" {
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo
                ?? (active?.buffer.canUndo ?? false)
        }
        if id == "redo" {
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo
                ?? (active?.buffer.canRedo ?? false)
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
