import Foundation
import NateCore

struct ResourceXMLNode: Sendable {
    let name: String
    let attributes: [String: String]
    var children: [ResourceXMLNode] = []
    var text = ""
}

enum ResourceXML {
    /// 业务作用：语言辅助资源使用受限 UTF-8 XML，不允许资源读取触发实体展开或联网。
    /// 参数说明:
    /// - data: 完整资源字节，最多 8 MB。
    /// 返回：通过深度、节点及字段限额检查的树；失败不发布部分规则。
    static func parse(_ data: Data) throws -> ResourceXMLNode {
        guard data.count <= 8_388_608, let source = String(data: data, encoding: .utf8),
            !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
            !source.localizedCaseInsensitiveContains("<!ENTITY")
        else {
            throw NateError.message("语言辅助资源必须是无 DTD 和实体声明、不超过 8 MB 的 UTF-8 XML。")
        }
        let reader = ResourceXMLReader()
        let parser = XMLParser(data: try preservingAttributeNewlines(source))
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        guard parser.parse(), !reader.exceeded, let root = reader.root else {
            throw NateError.message(
                reader.exceeded
                    ? "语言辅助资源超出节点或深度预算。"
                    : parser.parserError?.localizedDescription ?? "语言辅助 XML 没有根节点。"
            )
        }
        return root
    }

    /// 业务作用：兼容资源中的多行表达式和说明保留属性换行，避免 XML 标准化吞掉正则行注释边界。
    /// 参数说明:
    /// - source: 已通过容量与实体门禁的 UTF-8 XML。
    /// 返回：仅将属性中的换行和 Tab 改写为等价字符引用，普通文本与 CDATA 保持原值。
    static func preservingAttributeNewlines(_ source: String) throws -> Data {
        let bytes = Array(source.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var tag = false
        var quote: UInt8?
        while index < bytes.count {
            guard output.count <= 16_777_216 else {
                throw NateError.message("语言辅助资源的属性展开超过 16 MB。")
            }
            if !tag && bytes[index] == 60 {
                let suffix = bytes[index...]
                let end: [UInt8]? =
                    suffix.starts(with: Array("<!--".utf8))
                    ? Array("-->".utf8)
                    : suffix.starts(with: Array("<![CDATA[".utf8)) ? Array("]]>".utf8) : nil
                if let end {
                    repeat {
                        output.append(bytes[index])
                        index += 1
                    } while index < bytes.count && !bytes[index...].starts(with: end)
                    let count = min(end.count, bytes.count - index)
                    output.append(contentsOf: bytes[index..<(index + count)])
                    index += count
                    continue
                }
                tag = true
            }
            let byte = bytes[index]
            if let current = quote {
                if byte == current {
                    quote = nil
                }
                else if byte == 10 || byte == 13 || byte == 9 {
                    output.append(contentsOf: Array(byte == 9 ? "&#9;".utf8 : "&#10;".utf8))
                    if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 {
                        index += 1
                    }
                    index += 1
                    continue
                }
            }
            else if tag && (byte == 34 || byte == 39) {
                quote = byte
            }
            else if byte == 62 {
                tag = false
            }
            output.append(byte)
            index += 1
        }
        guard output.count <= 16_777_216 else {
            throw NateError.message("语言辅助资源的属性展开超过 16 MB。")
        }
        return Data(output)
    }
}

private final class ResourceXMLReader: NSObject, XMLParserDelegate {
    var stack: [ResourceXMLNode] = []
    var root: ResourceXMLNode?
    var nodes = 0
    var exceeded = false

    /// 业务作用：每个资源节点在进入临时树之前执行规模门禁。
    /// 参数说明:
    /// - parser: 当前受限解析器。
    /// - elementName: 当前元素名。
    /// - namespaceURI: 元素命名空间。
    /// - qName: 限定元素名。
    /// - attributeDict: 原始属性集合。
    /// 返回：合法节点进入栈；超限立即中止。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        nodes += 1
        guard stack.count < 64, nodes <= 100_000,
            attributeDict.count <= 128,
            attributeDict.values.allSatisfy({
                $0.utf8.count <= 1_048_576
            })
        else {
            exceeded = true
            parser.abortParsing()
            return
        }
        stack.append(ResourceXMLNode(name: elementName, attributes: attributeDict))
    }

    /// 业务作用：将片段文本追加到唯一当前节点，XML 转义只由解析器解释一次。
    /// 参数说明:
    /// - parser: 当前解析器。
    /// - string: 当前文本片段。
    /// 返回：文本在所属节点保留。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else {
            return
        }
        stack[stack.count - 1].text += string
    }

    /// 业务作用：闭合节点后才发布到父节点，根节点完整闭合后可供规则校验。
    /// 参数说明:
    /// - parser: 当前解析器。
    /// - elementName: 闭合元素名。
    /// - namespaceURI: 元素命名空间。
    /// - qName: 限定元素名。
    /// 返回：完成的树节点。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let node = stack.popLast() else {
            return
        }
        if stack.isEmpty {
            root = node
        }
        else {
            stack[stack.count - 1].children.append(node)
        }
    }
}
