import Foundation

/// Turns a spoken sentence such as “小雨明天下午三点来” into draft fields. It never publishes and never
/// guesses silently: anything vague (“晚一点”, “她来”, 3 点 without 上午/下午) becomes an issue the caregiver must fix.
public struct VoiceDraft: Equatable, Sendable {
    public var transcript: String
    public var personName: String?
    public var start: Date?
    public var issues: [String]
}

public enum VoiceDraftParser {
    private static let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]

    /// Parses 0–59 written as Arabic digits or Chinese numerals (三, 十二, 二十三, 四十五).
    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        guard !text.isEmpty else { return nil }
        if text == "十" { return 10 }
        let chars = Array(text)
        if let ten = chars.firstIndex(of: "十") {
            let tens = ten == 0 ? 1 : (digits[chars[0]] ?? -100)
            let ones = ten == chars.count - 1 ? 0 : (digits[chars[ten + 1]] ?? -100)
            let value = tens * 10 + ones
            return value >= 0 ? value : nil
        }
        guard chars.count == 1 else { return nil }
        return digits[chars[0]]
    }

    private static func match(_ pattern: String, in text: String) -> (range: Range<String.Index>, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text) else { return nil }
        let groups = (1..<result.numberOfRanges).map { index -> String in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        return (range, groups)
    }

    public static func parse(_ transcript: String, now: Date, zone: TimeZone) -> VoiceDraft {
        var text = transcript.replacingOccurrences(of: "[\\s，。,.!！?？]", with: "", options: .regularExpression)
        var issues: [String] = []
        let calendar = DayKey.calendar(zone)
        let today = calendar.startOfDay(for: now)
        var day: Date?
        var dayIsExplicit = false

        let numeral = "[0-9零一二两三四五六七八九十]+"
        if let m = match("(\(numeral))月(\(numeral))[日号]", in: text), let month = number(m.groups[0]), let dom = number(m.groups[1]) {
            let year = calendar.component(.year, from: now)
            if var date = calendar.date(from: DateComponents(year: year, month: month, day: dom)) {
                if date < today { date = calendar.date(byAdding: .year, value: 1, to: date)! }
                day = date
                dayIsExplicit = true
            }
            text.removeSubrange(m.range)
        } else if let m = match("(大后天|后天|明天|明日|今天|今日)", in: text) {
            let offset = ["今天": 0, "今日": 0, "明天": 1, "明日": 1, "后天": 2, "大后天": 3][m.groups[0]] ?? 0
            day = calendar.date(byAdding: .day, value: offset, to: today)
            dayIsExplicit = true
            text.removeSubrange(m.range)
        } else if let m = match("(下个?|这个?|本)?(周|星期|礼拜)([一二三四五六日天])", in: text) {
            let target = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7][m.groups[2]] ?? 1
            let current = calendar.component(.weekday, from: today)
            var ahead = (target - current + 7) % 7
            if m.groups[0].hasPrefix("下") { ahead += 7 }
            day = calendar.date(byAdding: .day, value: ahead, to: today)
            dayIsExplicit = true
            text.removeSubrange(m.range)
        }

        // Before reading clock times: “晚一点” must not be read as 1 o'clock.
        if let vague = match("(晚一点|晚点|待会儿?|一会儿?|过几天|改天|回头|有空)", in: text) {
            issues.append("“\(vague.groups[0])”不够具体，请改成确切的时间")
            text.removeSubrange(vague.range)
        }

        var part: String?
        if let m = match("(凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里)", in: text) {
            part = m.groups[0]
            text.removeSubrange(m.range)
        }

        var minuteOfDay: Int?
        if let m = match("(\(numeral))(?:点|:|：)(半|一刻|三刻|\(numeral))?分?", in: text), let rawHour = number(m.groups[0]), rawHour <= 24 {
            var minutes = 0
            switch m.groups[1] {
            case "": minutes = 0
            case "半": minutes = 30
            case "一刻": minutes = 15
            case "三刻": minutes = 45
            default: minutes = number(m.groups[1]) ?? 0
            }
            var hour = rawHour
            switch part {
            case "下午", "傍晚", "晚上": if hour < 12 { hour += 12 }
            case "中午": if hour < 3 { hour += 12 }
            case "夜里": if hour >= 6, hour < 12 { hour += 12 }
            case nil:
                if hour >= 1, hour <= 11 {
                    issues.append("只听到“\(rawHour) 点”，请确认是上午还是下午")
                    if hour <= 6 { hour += 12 }
                }
            default: break
            }
            minuteOfDay = (hour % 24) * 60 + min(minutes, 59)
            text.removeSubrange(m.range)
        } else {
            issues.append("没有听出具体时间，请手动选择")
        }

        var start: Date?
        if let minuteOfDay {
            let base = day ?? today
            start = calendar.date(byAdding: .minute, value: minuteOfDay, to: base)
            if !dayIsExplicit, let candidate = start, candidate < now {
                issues.append("今天这个时间已经过了，是不是指明天？请确认日期")
            }
        }

        var person: String?
        text = text.replacingOccurrences(of: "^(说|计划|打算)", with: "", options: .regularExpression)
        if let m = match("^(.+?)(?:计划|打算|会|要|应该)?(?:过来|回来|来看|来|到)", in: text) {
            let name = m.groups[0].replacingOccurrences(of: "(计划|打算|会|要|应该)$", with: "", options: .regularExpression)
            if !name.isEmpty { person = name }
        }
        if let name = person, ["她", "他", "他们", "她们", "TA", "ta"].contains(name) {
            issues.append("“\(name)”是谁？请填写具体的人物")
            person = nil
        } else if person == nil {
            issues.append("没有听出是谁，请填写人物")
        }
        return VoiceDraft(transcript: transcript, personName: person, start: start, issues: issues)
    }
}
