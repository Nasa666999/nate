import Foundation

enum ConfigurationJSONInput {
    private struct Frame {
        let object: Bool
        var expectsKey = true
        var keys: Set<String> = []
    }

    /// 业务作用：独立配置 JSON 在业务解码前保持唯一键和有界结构，重复定义不能表达另一套配置。
    /// 参数说明:
    /// - data: 当前完整配置的 JSON 原字节。
    /// - maximumBytes: 调用方明确采用的原字节容量，最多 16 MiB。
    /// - maximumKeys: 整份对象的键数量上限，最多 131072。
    /// - label: 当前配置的用户可见名称。
    /// - permit: 当前完整语义校验仍有执行资格。
    /// 返回：合法 JSON、至多 64 层、符合共同键数且每键至多 512 UTF-8 字节时通过，重复或超限整体拒绝。
    static func validate(
        _ data: Data,
        maximumBytes: Int,
        maximumKeys: Int,
        label: String,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = UserConfigurationBudget(permit: permit)
        try budget.check()
        guard maximumBytes > 0, maximumBytes <= 16_777_216,
            maximumKeys > 0, maximumKeys <= 131_072, data.count <= maximumBytes
        else {
            throw NateError.message("\(label)的 JSON 字段超过当前完整容量。")
        }
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        try budget.check()
        let bytes = Array(data)
        var stack: [Frame] = []
        var cursor = 0
        var keys = 0
        var previousToken: UInt8?
        while cursor < bytes.count {
            if cursor & 4095 == 0 {
                try budget.check()
            }
            let token = bytes[cursor]
            switch token {
            case 123, 91:
                guard stack.count < 64 else {
                    throw NateError.message("\(label) JSON 超过 64 层结构。")
                }
                stack.append(Frame(object: bytes[cursor] == 123))
                cursor += 1
            case 125, 93:
                // Foundation 接受尾随逗号，但配置协议不采用这种宽松语法，避免不同读取者产生不同解释。
                guard !stack.isEmpty, previousToken != 44 else {
                    throw NateError.invalidText
                }
                stack.removeLast()
                cursor += 1
            case 44:
                if !stack.isEmpty, stack[stack.count - 1].object {
                    stack[stack.count - 1].expectsKey = true
                }
                cursor += 1
            case 34:
                let start = cursor
                cursor += 1
                while cursor < bytes.count {
                    if cursor & 4095 == 0 {
                        try budget.check()
                    }
                    if bytes[cursor] == 92 {
                        cursor += 2
                    }
                    else if bytes[cursor] == 34 {
                        cursor += 1
                        break
                    }
                    else {
                        cursor += 1
                    }
                }
                guard cursor <= bytes.count else {
                    throw NateError.invalidText
                }
                if !stack.isEmpty, stack[stack.count - 1].object, stack[stack.count - 1].expectsKey {
                    guard cursor - start <= 3074, keys < maximumKeys else {
                        throw NateError.message("\(label) JSON 键名称或键数量超过容量。")
                    }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor]))
                    let last = stack.count - 1
                    // 业务字典采用字符串身份，转义或规范等价外观不能绕过同一对象内的唯一键约束。
                    guard key.utf8.count <= 512, stack[last].keys.insert(key).inserted else {
                        throw NateError.message("\(label) JSON 含重复键或超长名称，未采用任何定义。")
                    }
                    stack[last].expectsKey = false
                    keys += 1
                }
            default:
                cursor += 1
            }
            if ![9, 10, 13, 32].contains(token) {
                previousToken = token
            }
        }
        guard stack.isEmpty else {
            throw NateError.invalidText
        }
        try budget.check()
    }
}
