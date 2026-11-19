import Foundation
import NateCore
import zlib

private enum MIMEDeflateFailure: Error {
    case invalidStream
}

extension MIMECodec {
    /// 业务作用：按 URL、Base64、可选 DEFLATE 的固定顺序还原 SAML 传输，全部阶段共用预算。
    /// 参数说明:
    /// - bytes: 只包含消息值的原传输，不含 SAMLRequest= 或其它查询字段。
    /// - budget: 不可在阶段切换时延长的执行与容量预算。
    /// 返回：完整且格式良好的 XML 原字节；不验证签名、身份、受众或有效期，不访问网络。
    static func decodeSAML(_ bytes: [UInt8], budget: MIMEBudget) throws -> [UInt8] {
        let decoded = try decodeBase64(
            decodeURL(bytes, budget: budget),
            operation: .base64Decode,
            budget: budget
        )
        try budget.check(output: decoded.count)
        guard !decoded.isEmpty else {
            throw NateError.message("SAML 消息为空。")
        }
        let prefix = decoded.drop(while: {
            [9, 10, 13, 32].contains($0)
        })
        let looksLikeXML =
            prefix.first == 60 || decoded.starts(with: [0xEF, 0xBB, 0xBF])
            || decoded.starts(with: [0xFF, 0xFE]) || decoded.starts(with: [0xFE, 0xFF])
        if looksLikeXML {
            do {
                try validateSAMLXML(Data(decoded), budget: budget)
                return decoded
            }
            catch {
                // 字节前缀不能证明传输格式；合法原始 DEFLATE 也可能具有类似 XML 的起始位。
                try budget.check()
            }
        }
        let result = try inflateSAML(decoded, budget: budget)
        try validateSAMLXML(Data(result), budget: budget)
        return result
    }

    /// 业务作用：以六十四 KiB 块展开受限压缩消息，必须验证流结束且全部输入被消费。
    /// 参数说明:
    /// - bytes: 原始 DEFLATE，或具有完整头部证据的 zlib、gzip 流。
    /// - budget: 包含已完成 URL 和 Base64 阶段的原执行预算。
    /// 返回：完整解压字节；截断、尾随内容、拼接流、字典依赖及膨胀超限失败。
    static func inflateSAML(_ bytes: [UInt8], budget: MIMEBudget) throws -> [UInt8] {
        let gzip = bytes.starts(with: [31, 139])
        let zlib =
            bytes.count >= 2 && bytes[0] & 15 == 8 && bytes[0] >> 4 <= 7
            && (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0
        do {
            // SAML Redirect 的权威格式是原始 DEFLATE，偶合 zlib 头的存储块不能被误判为另一协议。
            return try inflateSAMLStream(bytes, window: -MAX_WBITS, budget: budget)
        }
        catch MIMEDeflateFailure.invalidStream {
            guard gzip || zlib else {
                throw NateError.message("SAML 压缩流无效、截断或包含尾随数据。")
            }
            do {
                return try inflateSAMLStream(bytes, window: gzip ? MAX_WBITS + 16 : MAX_WBITS, budget: budget)
            }
            catch MIMEDeflateFailure.invalidStream {
                throw NateError.message("SAML 压缩流无效、截断、需要外部字典或包含尾随数据。")
            }
        }
    }

    /// 业务作用：按一个明确包装格式验证完整压缩流，结构错误与预算失败分别处理。
    /// 参数说明:
    /// - bytes: 完整压缩原字节。
    /// - window: 系统 zlib 的原始、zlib 或 gzip 格式标志。
    /// - budget: 全部格式尝试共用的原执行预算。
    /// 返回：只在全部输入恰好形成一个完整流时提供完整字节；超限不进入其它格式重试。
    private static func inflateSAMLStream(_ bytes: [UInt8], window: Int32, budget: MIMEBudget) throws
        -> [UInt8]
    {
        var stream = z_stream()
        guard inflateInit2_(&stream, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NateError.message("无法建立 SAML 解压通道。")
        }
        defer {
            inflateEnd(&stream)
        }
        var input = bytes
        return try input.withUnsafeMutableBytes {
            source in
            stream.next_in = source.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(source.count)
            var output: [UInt8] = []
            var block = [UInt8](repeating: 0, count: 65_536)
            while true {
                try budget.check(output: output.count)
                let before = stream.total_in
                let status = block.withUnsafeMutableBytes {
                    target in
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = block.count - Int(stream.avail_out)
                // 只有完整容量成立才保留本块，压缩炸弹不能先分配超限的最终输出。
                guard count <= maximumBytes - output.count else {
                    throw NateError.message("SAML 解压输出超过 64 MiB，原内容保持不变。")
                }
                output.append(contentsOf: block.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else {
                        throw MIMEDeflateFailure.invalidStream
                    }
                    try budget.check(output: output.count)
                    return output
                }
                guard status == Z_OK, count > 0 || stream.total_in > before else {
                    throw MIMEDeflateFailure.invalidStream
                }
            }
        }
    }

    /// 业务作用：仅验证 XML 结构，外部实体与文档类型在解析前拒绝，解码不会变成资源加载。
    /// 参数说明:
    /// - data: 完整未压缩 XML 字节，保留其 BOM 与编码声明。
    /// - budget: 整次传输的原预算。
    /// 返回：格式良好的有界 XML；声明、编码、深度或解析失败时拒绝全部结果。
    static func validateSAMLXML(_ data: Data, budget: MIMEBudget) throws {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = try TextEncoding.detect(data).0
        }
        else {
            text = try TextEncoding.utf8.decode(data)
        }
        try budget.check(output: text.utf8.count)
        // 禁止内部实体同样必要，否则关闭网络仍不能限制声明导致的递归文本膨胀。
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw NateError.message("SAML 解码不接受 DTD 或实体声明。")
        }
        let delegate = SAMLXMLValidation(budget: budget)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let valid = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        try budget.check()
        guard valid, delegate.roots == 1, delegate.depth == 0 else {
            throw NateError.message("SAML 解码结果不是完整合法 XML。")
        }
    }
}

private final class SAMLXMLValidation: NSObject, XMLParserDelegate {
    let budget: MIMEBudget
    var failure: Error?
    var depth = 0, roots = 0, nodes = 0

    /// 业务作用：XML 结构检查沿用传输动作的取消资格。
    /// 参数说明:
    /// - budget: 调用方不可延长的原预算。
    /// 返回：尚未消费任何元素的解析状态。
    init(budget: MIMEBudget) {
        self.budget = budget
    }

    /// 业务作用：解析回调内复验预算，不能把取消等同于异步任务结束而继续同步解析。
    /// 参数说明:
    /// - parser: 当前系统解析器。
    /// 返回：失效时立即终止解析，并保存实际失败原因。
    func check(_ parser: XMLParser) {
        do {
            try budget.check()
        }
        catch {
            failure = error
            parser.abortParsing()
        }
    }

    /// 业务作用：限制 XML 深度与元素总数，不建立 DOM 或加载任何样式。
    /// 参数说明:
    /// - parser: 当前系统解析器。
    /// - elementName: 系统已解析的元素名。
    /// - namespaceURI: 系统提供的命名空间。
    /// - qName: 系统提供的限定名。
    /// - attributeDict: 当前元素属性，不作为身份验证证据。
    /// 返回：记录结构或在超过二百五十六层、一百万元素时中止。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        check(parser)
        if depth == 0 {
            roots += 1
        }
        depth += 1
        nodes += 1
        if depth > 256 || nodes > 1_000_000 {
            failure = NateError.message("SAML XML 结构超过深度或元素数量限制。")
            parser.abortParsing()
        }
    }

    /// 业务作用：跟踪系统确认的闭合结构，结束元素不改变源消息字节。
    /// 参数说明:
    /// - parser: 当前系统解析器。
    /// - elementName: 当前闭合的元素名。
    /// - namespaceURI: 系统提供的命名空间。
    /// - qName: 系统提供的限定名。
    /// 返回：减少当前深度并继续确认原取消资格。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
        check(parser)
    }

    /// 业务作用：长文本内容也必须经过同步解析中的取消检查，不累积第二份正文。
    /// 参数说明:
    /// - parser: 当前系统解析器。
    /// - string: 系统本次交付的内容片段，不保留。
    /// 返回：预算失效时中止，其余内容只由原字节持有。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        check(parser)
    }
}
