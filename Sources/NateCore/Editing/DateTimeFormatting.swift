import Foundation

extension DateTimeSettings {
    /// 业务作用：将一次固定时刻格式化为普通输入，全部光标使用同一瞬间和区域上下文。
    /// 参数说明:
    /// - date: 本次插入或预览固定的绝对时刻。
    /// - mode: 短日期、长日期或自定义字段次序。
    /// - locale: 月名、星期、纪元及上午下午的区域来源。
    /// - timeZone: 本次固定的本地时区。
    /// - calendar: 年月日采用的日历来源。
    /// 返回：最多 16 KiB 的完整非空文本；时刻、日历或输出无效时失败，不生成可删除原选择的空串。
    public func formatted(
        date: Date,
        mode: DateTimeInsertionMode,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) throws -> String {
        guard date.timeIntervalSince1970.isFinite,
            (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
        else {
            throw NateError.message("日期时间必须位于公历 1 年至 9999 年的有限绝对时间范围。")
        }
        var calendar = calendar
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = components.year, (1...99_999).contains(year),
            let month = components.month, let day = components.day,
            let hour = components.hour, let minute = components.minute, let second = components.second
        else {
            throw NateError.message("日期时间超出当前日历可表示的年月日范围。")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        let result: String
        if mode == .custom {
            let numericDay = fields.contains {
                if case .field(.day, let width) = $0 {
                    return width <= 2
                }
                return false
            }
            var output = ""
            var localized: [String: String] = [:]
            for field in fields {
                let piece: String
                switch field {
                case .literal(let value):
                    piece = value
                case .field(let kind, let width):
                    switch kind {
                    case .year:
                        piece = Self.decimal(width <= 2 ? year % 100 : year, width: width <= 2 ? 2 : 4)
                    case .month where width <= 2:
                        piece = Self.decimal(month, width: width)
                    case .day where width <= 2:
                        piece = Self.decimal(day, width: width)
                    case .hour12:
                        piece = Self.decimal(hour % 12 == 0 ? 12 : hour % 12, width: min(width, 2))
                    case .hour24:
                        piece = Self.decimal(hour, width: min(width, 2))
                    case .minute:
                        piece = Self.decimal(minute, width: min(width, 2))
                    case .second:
                        piece = Self.decimal(second, width: min(width, 2))
                    case .period:
                        let marker = hour < 12 ? formatter.amSymbol ?? "" : formatter.pmSymbol ?? ""
                        piece = width == 1 ? String(marker.prefix(1)) : marker
                    case .month, .day, .era:
                        let pattern: String
                        if kind == .month {
                            pattern =
                                numericDay ? (width == 3 ? "MMM" : "MMMM") : (width == 3 ? "LLL" : "LLLL")
                        }
                        else {
                            pattern = kind == .day ? (width == 3 ? "EEE" : "EEEE") : "G"
                        }
                        if let cached = localized[pattern] {
                            piece = cached
                        }
                        else {
                            formatter.dateFormat = pattern
                            piece = formatter.string(from: date)
                            localized[pattern] = piece
                        }
                    }
                }
                // 地区数据也参与输出预算，超限不得先插入已有前缀。
                guard piece.utf8.count <= 16_384 - output.utf8.count else {
                    throw NateError.message("日期时间完整输出超过 16 KiB，原正文保持不变。")
                }
                output += piece
            }
            result = output
        }
        else {
            formatter.dateStyle = mode == .short ? .short : .full
            formatter.timeStyle = .none
            let dateText = formatter.string(from: date)
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let timeText = formatter.string(from: date)
            result = dateFirst ? dateText + " " + timeText : timeText + " " + dateText
        }
        guard !result.isEmpty, result.utf8.count <= 16_384,
            !result.unicodeScalars.contains(where: {
                $0.value == 0 || [10, 13, 0x85, 0x2028, 0x2029].contains($0.value)
            })
        else {
            throw NateError.message("日期时间没有完整有效的单行输出，原正文保持不变。")
        }
        return result
    }

    /// 业务作用：数字字段采用明确的 ASCII 数值与前导零，不受系统十二小时显示偏好改写。
    /// 参数说明:
    /// - value: 已从固定日历取得的非负字段。
    /// - width: 至少需要的十进制位数。
    /// 返回：完整数值，位数较长时不截断。
    private static func decimal(_ value: Int, width: Int) -> String {
        let value = String(value)
        return String(repeating: "0", count: max(0, width - value.count)) + value
    }
}
