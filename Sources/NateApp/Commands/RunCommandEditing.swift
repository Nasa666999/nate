import AppKit
import NateCore
import NatePlatform
import NateUI

private struct RunArgumentArray: Decodable {
    let values: [String]

    /// 业务作用：JSON 只接受有界字符串数组，不把嵌套对象或过多条目建立成可执行参数。
    /// 参数说明:
    /// - decoder: 已限制原始 JSON 字节数的解码器。
    /// 返回：最多一千零二十四项且累计不超过 4 MiB 的完整模板。
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard
            container.count.map({
                $0 <= NamedRunCommand.maximumArguments
            }) ?? true
        else {
            throw NateError.message("参数数组超过一千零二十四项。")
        }
        var values: [String] = []
        var bytes = 0
        while !container.isAtEnd {
            guard values.count < NamedRunCommand.maximumArguments else {
                throw NateError.message("参数数组超过一千零二十四项。")
            }
            let value = try container.decode(String.self)
            guard value.utf8.count <= NamedRunCommand.maximumFieldBytes,
                value.utf8.count <= NamedRunCommand.maximumTemplateBytes - bytes
            else {
                throw NateError.message("单个参数模板超过 1 MiB 或完整参数超过 4 MiB。")
            }
            bytes += value.utf8.count
            values.append(value)
        }
        self.values = values
    }
}

extension ApplicationController {
    /// 业务作用：完整表单解析成唯一结构化定义，原始程序和参数不会在解析时进入 shell。
    /// 参数说明:
    /// - draft: 点击时固定的完整草稿。
    /// - temporary: 空名称是否仅供临时预览使用。
    /// - id: 本次保存已固定的新身份，省略时沿原身份或建立临时身份。
    /// 返回：完整合法定义；错误保留当前表单，不保存或执行。
    nonisolated static func runCommandDefinition(
        _ draft: RunCommandDraft,
        temporary: Bool,
        id: UUID? = nil
    ) throws -> NamedRunCommand {
        guard draft.argumentsJSON.utf8.count <= 32 * 1_048_576 else {
            throw NateError.message("参数 JSON 超过 32 MiB，请保留完整内容后缩短输入。")
        }
        let arguments = try JSONDecoder().decode(RunArgumentArray.self, from: Data(draft.argumentsJSON.utf8))
        return try NamedRunCommand(
            id: id ?? draft.id ?? UUID(),
            name: temporary && draft.name.isEmpty ? "临时运行" : draft.name,
            executable: draft.executable,
            arguments: arguments.values,
            directory: draft.directory.isEmpty ? nil : draft.directory,
            shortcut: draft.shortcut
        )
    }

    /// 业务作用：保存完整草稿前核对真实绑定所有者，名称修改保留原身份，删除过的身份不能被旧表单复活。
    /// 参数说明:
    /// - draft: 当前明确点击保存的原文输入。
    /// 返回：合法完整候选进入串行保存；冲突或解析失败保留原库与草稿。
    func saveRunCommandDraft(_ draft: RunCommandDraft) {
        let runtime = runCommands
        guard canChangeRunCommands(), runtime.importCandidate == nil else {
            return
        }
        let id = draft.id ?? UUID()
        if let shortcut = draft.shortcut,
            let conflict = commandShortcutConflict(shortcut, excluding: "savedRun:" + id.uuidString)
        {
            runtime.failure = "快捷键与“" + conflict + "”冲突，配置未改变。"
            refreshRunCommandPresentation()
            return
        }
        changeRunCommandLibrary(
            {
                library in
                let definition = try Self.runCommandDefinition(draft, temporary: false, id: id)
                var commands = library.commands
                if draft.id != nil {
                    // 原身份缺席代表表单来源已经失效，不能把旧编辑当成新建命令重新加入。
                    guard
                        let index = commands.firstIndex(where: {
                            $0.id == id
                        })
                    else {
                        throw NateError.message("原运行配置已经移除，请明确新建配置。")
                    }
                    commands[index] = definition
                }
                else {
                    commands.append(definition)
                }
                return try RunCommandLibrary(commands)
            },
            selecting: id
        )
    }

    /// 业务作用：删除稳定配置须明确确认，菜单与快捷键在完整列表保存后同时移除。
    /// 参数说明:
    /// - id: 当前明确选择的配置身份。
    /// 返回：确认后保存完整剩余列表；取消不改变任何定义或进程。
    func deleteRunCommand(_ id: UUID) {
        let runtime = runCommands
        guard canChangeRunCommands(), runtime.importCandidate == nil,
            let definition = runtime.library.commands.first(where: {
                $0.id == id
            })
        else {
            return
        }
        let question = NSAlert()
        question.messageText = "删除运行配置“" + definition.name + "”？"
        question.informativeText = "将移除此命名配置和对应快捷键，已经启动的外部命令仍由独立任务管理。"
        question.addButton(withTitle: "删除配置")
        question.addButton(withTitle: "保留")
        guard question.runModal() == .alertFirstButtonReturn else {
            return
        }
        changeRunCommandLibrary {
            library in
            try RunCommandLibrary(
                library.commands.filter {
                    $0.id != id
                }
            )
        }
    }
}
