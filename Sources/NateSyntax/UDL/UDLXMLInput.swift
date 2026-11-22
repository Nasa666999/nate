import Foundation
import NateCore

struct UDLXMLInput {
    let data: Data
    private let markers: Set<UInt32>
    private let references: [UInt32: String]

    /// 业务作用：Foundation 的文本回调会丢弃独立 U+FEFF，解析前以无冲突字符保护并保留数值引用原形。
    /// 参数说明:
    /// - original: 已通过 UTF-8、大小及 DTD 禁用检查的原始 XML。
    /// 返回：只用于解析的有界副本及可逆映射；字符空间或工作容量不足时拒绝整份输入。
    init(_ original: Data) throws {
        try Task.checkCancellation()
        let source = String(decoding: original, as: UTF8.self)
        let bytes = Array(original)
        var needed = source.unicodeScalars.dropFirst(source.unicodeScalars.first?.value == 0xFEFF ? 1 : 0)
            .contains {
                $0.value == 0xFEFF
            }
        var used: Set<UInt32> = []
        var position = 0
        while position < bytes.count {
            if let item = Self.reference(bytes, at: position) {
                if item.value == 0xFEFF {
                    needed = true
                }
                if let scalar = UnicodeScalar(item.value) {
                    for value in String(scalar).precomposedStringWithCanonicalMapping.unicodeScalars {
                        used.insert(value.value)
                    }
                }
                position = item.end
            }
            else {
                position += 1
            }
        }
        guard needed else {
            data = original
            markers = []
            references = [:]
            return
        }
        for scalar in source.unicodeScalars {
            used.insert(scalar.value)
        }
        for scalar in source.precomposedStringWithCanonicalMapping.unicodeScalars {
            used.insert(scalar.value)
        }
        var candidate: UInt32 = 0x20000
        /// 业务作用：映射字符须同时避开原字符及规范等价字符，不能令 XML 属性身份发生合并。
        /// 参数说明: 无。
        /// 返回：合法 XML 名称字符；有限保护空间耗尽时拒绝输入。
        func allocate() throws -> UnicodeScalar {
            while candidate <= 0x2FFFD {
                let value = candidate
                candidate += 1
                guard !used.contains(value), let scalar = UnicodeScalar(value) else {
                    continue
                }
                let text = String(scalar)
                guard text.utf8.elementsEqual(text.precomposedStringWithCanonicalMapping.utf8) else {
                    continue
                }
                used.insert(value)
                return scalar
            }
            throw NateError.message("UDL XML 字符保护空间不足，完整定义未发布。")
        }
        let literal = try allocate()
        var protected: Set<UInt32> = [literal.value]
        var spellings: [String: UnicodeScalar] = [:]
        var references: [UInt32: String] = [:]
        var output: [UInt8] = []
        output.reserveCapacity(min(8_388_608, bytes.count * 2))
        position = 0
        while position < bytes.count {
            if position & 4095 == 0 {
                try Task.checkCancellation()
            }
            if position > 0, bytes[position...].starts(with: [239, 187, 191]) {
                output += String(literal).utf8
                position += 3
            }
            else if let item = Self.reference(bytes, at: position), item.value == 0xFEFF {
                let spelling = String(decoding: bytes[position..<item.end], as: UTF8.self)
                let scalar: UnicodeScalar
                if let existing = spellings[spelling] {
                    scalar = existing
                }
                else {
                    scalar = try allocate()
                    spellings[spelling] = scalar
                    protected.insert(scalar.value)
                    references[scalar.value] = spelling
                }
                // 保留引用语法，使 CDATA 中的字面引用与普通 XML 中的解码字符仍可分别恢复。
                output += ("&#x" + String(scalar.value, radix: 16) + ";").utf8
                position = item.end
            }
            else {
                output.append(bytes[position])
                position += 1
            }
            guard output.count <= 8_388_608 else {
                throw NateError.message("UDL XML 字符保护副本超过 8 MiB，完整定义未发布。")
            }
        }
        data = Data(output)
        markers = protected
        self.references = references
    }

    /// 业务作用：属性、元素名和文本回调恢复原标量，临时映射不能进入有效规则或显示名称。
    /// 参数说明:
    /// - value: XML 解析器已完成实体解码的内容。
    /// 返回：原始 U+FEFF 恢复后的精确标量序列。
    func decoded(_ value: String) -> String {
        guard !markers.isEmpty else {
            return value
        }
        var result = String.UnicodeScalarView()
        let feff: UnicodeScalar = "\u{FEFF}"
        for scalar in value.unicodeScalars {
            result.append(markers.contains(scalar.value) ? feff : scalar)
        }
        return String(result)
    }

    /// 业务作用：CDATA 中的数值引用是字面文字，恢复其原写法后再恢复实际字符，不能二次解释引用。
    /// 参数说明:
    /// - bytes: XML 解析器提供的 UTF-8 CDATA。
    /// 返回：完整原文本；编码非法时拒绝输入。
    func cdata(_ bytes: Data) throws -> String {
        guard String(data: bytes, encoding: .utf8) != nil else {
            throw NateError.message("UDL CDATA 不是完整 UTF-8，定义未发布。")
        }
        let input = Array(bytes)
        var output: [UInt8] = []
        var position = 0
        while position < input.count {
            if let item = Self.reference(input, at: position), let spelling = references[item.value] {
                output += spelling.utf8
                position = item.end
            }
            else {
                output.append(input[position])
                position += 1
            }
        }
        return decoded(String(decoding: output, as: UTF8.self))
    }

    /// 业务作用：数值引用只接受 XML 的无符号十进制或小写 x 引导的十六进制，非法语法交由解析器拒绝。
    /// 参数说明:
    /// - bytes: 原始或受保护的 XML 字节。
    /// - offset: 当前可能的引用开端。
    /// 返回：完整引用的标量值及结束位置；残缺、溢出或非法引用为空。
    private static func reference(_ bytes: [UInt8], at offset: Int) -> (value: UInt32, end: Int)? {
        guard offset + 2 < bytes.count, bytes[offset] == 38, bytes[offset + 1] == 35 else {
            return nil
        }
        var position = offset + 2
        let radix: UInt32 = bytes[position] == 120 ? 16 : 10
        if radix == 16 {
            position += 1
        }
        let start = position
        var value: UInt32 = 0
        while position < bytes.count {
            let byte = bytes[position]
            if byte == 59 {
                return position > start && value <= 0x10FFFF ? (value, position + 1) : nil
            }
            let digit: UInt32
            if (48...57).contains(byte) {
                digit = UInt32(byte - 48)
            }
            else if radix == 16, (65...70).contains(byte) || (97...102).contains(byte) {
                digit = UInt32(byte <= 70 ? byte - 55 : byte - 87)
            }
            else {
                return nil
            }
            let product = value.multipliedReportingOverflow(by: radix)
            let sum = product.partialValue.addingReportingOverflow(digit)
            guard !product.overflow, !sum.overflow else {
                return nil
            }
            value = sum.partialValue
            position += 1
        }
        return nil
    }
}
