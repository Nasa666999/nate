import Foundation

public struct FileFilters: Sendable {
    let includes: [String]
    let excludes: [String]
    let rootDirectories: [String]
    let recursiveDirectories: [String]

    /// 业务作用：解释 Notepad++ 的空格分隔过滤规则，排除优先于包含。
    /// 参数说明:
    /// - expression: 文件过滤框原文。
    /// 返回：独立的文件和目录过滤条件。
    public init(_ expression: String) {
        var includes: [String] = []
        var excludes: [String] = []
        var rootDirectories: [String] = []
        var recursiveDirectories: [String] = []
        for token in expression.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("!+\\") {
                recursiveDirectories.append(String(token.dropFirst(3)))
            }
            else if token.hasPrefix("!\\") {
                rootDirectories.append(String(token.dropFirst(2)))
            }
            else if token.hasPrefix("!") {
                excludes.append(String(token.dropFirst()))
            }
            else {
                includes.append(token)
            }
        }
        self.includes = includes.isEmpty ? ["*.*"] : includes
        self.excludes = excludes
        self.rootDirectories = rootDirectories
        self.recursiveDirectories = recursiveDirectories
    }

    /// 业务作用：按 Windows 风格通配符判断文件，*.* 包含无扩展名文件。
    /// 参数说明:
    /// - filename: 当前文件名。
    /// 返回：满足包含且未被排除时为真。
    public func accepts(_ filename: String) -> Bool {
        includes.contains {
            Self.glob($0, filename)
        }
            && !excludes.contains {
                Self.glob($0, filename)
            }
    }

    /// 业务作用：防止进入明确排除目录，根级与递归排除分别生效。
    /// 参数说明:
    /// - name: 目录名。
    /// - depth: 相对搜索根的层级，第一层为零。
    /// 返回：该目录可遍历时为真。
    public func acceptsDirectory(_ name: String, depth: Int) -> Bool {
        !recursiveDirectories.contains {
            Self.glob($0, name)
        }
            && !(depth == 0
                && rootDirectories.contains {
                    Self.glob($0, name)
                })
    }

    /// 业务作用：用有限状态通配匹配代替 shell 展开，不解释引号或命令。
    /// 参数说明:
    /// - pattern: * 和 ? 模式。
    /// - value: 单个文件或目录名。
    /// 返回：不区分大小写的完整匹配。
    static func glob(_ pattern: String, _ value: String) -> Bool {
        if pattern == "*.*" || pattern == "*" {
            return true
        }
        let p = Array(pattern.lowercased())
        let v = Array(value.lowercased())
        var i = 0
        var j = 0
        var star: Int?
        var restart = 0
        while j < v.count {
            if i < p.count && (p[i] == "?" || p[i] == v[j]) {
                i += 1
                j += 1
            }
            else if i < p.count && p[i] == "*" {
                star = i
                i += 1
                restart = j
            }
            else if let star {
                i = star + 1
                restart += 1
                j = restart
            }
            else {
                return false
            }
        }
        while i < p.count && p[i] == "*" {
            i += 1
        }
        return i == p.count
    }
}
