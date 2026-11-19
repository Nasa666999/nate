import Foundation
import NateCore

public enum MIMEOperation: String, Sendable, CaseIterable {
    case base64Encode
    case base64EncodeUnpadded
    case base64EncodeWrapped
    case base64EncodeByLine
    case base64Decode
    case base64DecodeSegments
    case base64DecodeByLine
    case quotedPrintableEncode
    case quotedPrintableDecode
    case urlEncode
    case urlEncodeRFC1738
    case urlEncodeExtended
    case urlEncodeFull
    case urlEncodeRFC1738ByLine
    case urlEncodeExtendedByLine
    case urlEncodeFullByLine
    case urlDecode
    case samlDecode
}

public enum MIMECodec {
    public static let maximumBytes = 64 * 1024 * 1024

    /// 业务作用：按明确传输格式转换完整字节，不把任意解码结果误当成可写正文。
    /// 参数说明:
    /// - operation: 编解码格式及分行、填充规则。
    /// - data: 固定输入原字节，包括 NUL 与原始换行。
    /// - deadline: 可选外部截止时间，不能放宽内部五秒预算。
    /// - permit: 原动作仍有效时为真。
    /// 返回：完整字节结果；非法输入、超限或取消均失败，不返回截断内容。
    public static func transform(
        _ operation: MIMEOperation,
        data: Data,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = MIMEBudget(
            deadline: deadline,
            permit: permit
        )
        try budget.check()
        guard data.count <= maximumBytes else {
            throw NateError.message("MIME 输入超过 64 MiB，原内容保持不变。")
        }
        let bytes = [UInt8](data)
        let result: [UInt8]
        switch operation {
        case .base64Encode, .base64EncodeUnpadded, .base64EncodeWrapped, .base64EncodeByLine:
            result = try encodeBase64(bytes, operation: operation, budget: budget)
        case .base64Decode, .base64DecodeSegments, .base64DecodeByLine:
            result = try decodeBase64(bytes, operation: operation, budget: budget)
        case .quotedPrintableEncode:
            result = try encodeQuotedPrintable(bytes, budget: budget)
        case .quotedPrintableDecode:
            result = try decodeQuotedPrintable(bytes, budget: budget)
        case .urlEncode, .urlEncodeRFC1738, .urlEncodeExtended, .urlEncodeFull,
            .urlEncodeRFC1738ByLine, .urlEncodeExtendedByLine, .urlEncodeFullByLine:
            result = try encodeURL(bytes, operation: operation, budget: budget)
        case .urlDecode:
            result = try decodeURL(bytes, budget: budget)
        case .samlDecode:
            result = try decodeSAML(bytes, budget: budget)
        }
        try budget.check(output: result.count)
        return Data(result)
    }
}

struct MIMEBudget: Sendable {
    let deadline: ContinuousClock.Instant
    let permit: @Sendable () -> Bool

    /// 业务作用：一次编解码的全部阶段共用截止时间，解压和 XML 校验不能重新获得执行预算。
    /// 参数说明:
    /// - deadline: 调用方更早的截止时间。
    /// - permit: 当前动作的取消资格。
    /// 返回：最多五秒的不可延长预算。
    init(deadline: ContinuousClock.Instant?, permit: @escaping @Sendable () -> Bool) {
        self.deadline = min(deadline ?? .now.advanced(by: .seconds(5)), .now.advanced(by: .seconds(5)))
        self.permit = permit
    }

    /// 业务作用：有界步长确认取消和完整输出容量，任何超限都不能发布已有前缀。
    /// 参数说明:
    /// - output: 已准备的输出字节数。
    /// 返回：仍可继续时正常返回；失效、超时或超过 64 MiB 时失败。
    func check(output: Int = 0) throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("MIME 转换超过五秒预算，原内容保持不变。")
        }
        guard output <= MIMECodec.maximumBytes else {
            throw NateError.message("MIME 完整输出超过 64 MiB，未发布部分内容。")
        }
    }
}
