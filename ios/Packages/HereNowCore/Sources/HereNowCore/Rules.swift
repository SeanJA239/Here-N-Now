import Foundation

public struct ValidationIssue: Equatable, Sendable, Identifiable {
    public enum Severity: Equatable, Sendable { case blocking, warning }

    public var id: String
    public var severity: Severity
    public var message: String
    public var eventID: String?

    public init(id: String, severity: Severity, message: String, eventID: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.eventID = eventID
    }
}

public enum PublishValidator {
    /// `fits(line, hasPhoto)` answers whether the sentence fits in two lines on the patient screen at the chosen text size.
    public static func validate(_ snapshot: FamilySnapshot, now: Date, fits: (String, Bool) -> Bool) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func block(_ id: String, _ message: String, _ event: String? = nil) {
            issues.append(.init(id: id, severity: .blocking, message: message, eventID: event))
        }
        func warn(_ id: String, _ message: String, _ event: String? = nil) {
            issues.append(.init(id: id, severity: .warning, message: message, eventID: event))
        }

        if snapshot.profile.callName.trimmingCharacters(in: .whitespaces).isEmpty {
            block("profile.name", "请填写患者的称呼")
        }
        if TimeZone(identifier: snapshot.profile.timeZoneID) == nil {
            block("profile.tz", "患者所在地时区无效")
        }
        let starts = snapshot.segments.map(\.startMinute)
        if snapshot.segments.count < 2 || Set(starts).count != starts.count
            || snapshot.segments.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            block("segments", "时段至少两个，名称不能为空，开始时间不能重复")
        }

        let place = snapshot.place
        if place.enabled {
            if place.line.trimmingCharacters(in: .whitespaces).isEmpty {
                block("place.line", "地点提示已开启，请填写一句地点短话")
            } else if !fits(place.line, place.photoAssetID != nil) {
                block("place.fit", "地点短话在患者屏幕上超过两行，请改短")
            }
            if let reviewBy = place.reviewBy {
                if reviewBy <= now { warn("place.review", "地点提示已过复核期限，患者端不会显示，请重新确认") }
            } else {
                block("place.review.missing", "请为地点提示设置复核期限")
            }
            if place.recording != nil, !place.recordingIsCurrent {
                warn("place.recording", "地点短话已修改，旧录音待复核；复核前患者端不会播放它")
            }
        }

        let active = snapshot.events.filter { !$0.isCancelled }
        for event in active {
            let name = event.personName.isEmpty ? "未命名安排" : event.personName
            if event.personName.trimmingCharacters(in: .whitespaces).isEmpty {
                block("event.person.\(event.id)", "请填写这项安排涉及的人物", event.id)
            }
            if event.line.trimmingCharacters(in: .whitespaces).isEmpty {
                block("event.line.\(event.id)", "「\(name)」缺少给患者看的短句", event.id)
            } else if !fits(event.line, event.photoAssetID != nil) {
                block("event.fit.\(event.id)", "「\(name)」的短句在患者屏幕上超过两行，请改短", event.id)
            }
            if event.showUntil < event.start {
                block("event.until.\(event.id)", "「\(name)」的“显示至”不能早于开始时间", event.id)
            }
            if event.showFrom > event.start {
                block("event.from.\(event.id)", "「\(name)」的开始显示时间不能晚于开始时间", event.id)
            }
            if event.showUntil <= now {
                warn("event.expired.\(event.id)", "「\(name)」已过“显示至”时间，患者端不会显示", event.id)
            }
            if event.recording != nil, !event.recordingIsCurrent {
                warn("event.recording.\(event.id)", "「\(name)」的时间、人物或短句已修改，旧录音待复核；复核或重录前患者端不会播放它", event.id)
            }
        }

        for plan in snapshot.recurring where !plan.isCancelled {
            let name = plan.personName.isEmpty ? "未命名重复安排" : plan.personName
            if plan.personName.trimmingCharacters(in: .whitespaces).isEmpty || plan.line.trimmingCharacters(in: .whitespaces).isEmpty {
                block("recurring.text.\(plan.id)", "重复安排「\(name)」需要人物和短句")
            } else if !fits(plan.line, plan.photoAssetID != nil) {
                block("recurring.fit.\(plan.id)", "重复安排「\(name)」的短句在患者屏幕上超过两行，请改短")
            }
            if plan.weekdays.isEmpty { block("recurring.days.\(plan.id)", "重复安排「\(name)」至少要选一天") }
            if plan.showForMinutes <= 0 { block("recurring.until.\(plan.id)", "重复安排「\(name)」需要选择每次显示多久") }
            if plan.recording != nil, !plan.recordingIsCurrent {
                warn("recurring.recording.\(plan.id)", "重复安排「\(name)」已修改，旧录音待复核；复核前不会播放")
            }
        }
        for item in snapshot.comfortItems where item.recording == nil {
            block("comfort.recording.\(item.id)", "安抚内容「\(item.title)」需要一段录音")
        }
        if snapshot.autoPlay.enabled, snapshot.autoPlay.dailyLimit < 1 {
            block("autoplay.limit", "自动问候已开启，每日上限至少为 1 次")
        }

        let upcoming = snapshot.effectiveEvents(around: now).filter { !$0.isCancelled && $0.showUntil > now }
        let groups = Dictionary(grouping: upcoming) { Int($0.start.timeIntervalSince1970 / 60) }
        for (minute, group) in groups where group.count > 1 {
            if group.filter(\.preferredOnTie).count != 1 {
                block("event.tie.\(minute)", "有 \(group.count) 项安排开始时间相同（含重复安排），请合并，或在单次安排中选择患者端显示哪一项", group.first?.id)
            }
        }
        return issues
    }

    public static func hasBlocking(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .blocking }
    }
}

public enum EventWording {
    /// A plain suggestion such as “小雨计划下午 3 点来”. The caregiver can always edit it.
    public static func suggestedLine(person: String, start: Date, showFrom: Date, snapshot: FamilySnapshot) -> String {
        let zone = snapshot.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let minute = MomentResolver.minuteOfDay(start, in: zone)
        let segment = MomentResolver.segmentName(minute: minute, segments: snapshot.segments)
        let hour = minute / 60
        let minutes = minute % 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let clock: String
        switch minutes {
        case 0: clock = "\(hour12) 点"
        case 30: clock = "\(hour12) 点半"
        default: clock = "\(hour12):\(String(format: "%02d", minutes))"
        }
        var day = ""
        if !calendar.isDate(showFrom, inSameDayAs: start) {
            let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            day = weekdays[calendar.component(.weekday, from: start) - 1]
        }
        let who = person.trimmingCharacters(in: .whitespaces)
        return "\(who)计划\(day)\(segment) \(clock)来"
    }
}

public struct ClockGuard: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var wall: Date
        public var uptime: TimeInterval
    }

    public static let jumpTolerance: TimeInterval = 120
    public static let serverTolerance: TimeInterval = 300

    public private(set) var last: Sample?
    public private(set) var latestWall: Date?
    public private(set) var suspect = false
    public private(set) var detail: String?

    public init() {}

    /// Compares wall-clock progress with monotonic uptime; a mismatch means the device clock was changed.
    public mutating func observe(wall: Date, uptime: TimeInterval) {
        defer {
            last = Sample(wall: wall, uptime: uptime)
            latestWall = max(latestWall ?? wall, wall)
        }
        guard let last else { return }
        if uptime >= last.uptime {
            let expected = last.wall.addingTimeInterval(uptime - last.uptime)
            let drift = wall.timeIntervalSince(expected)
            if abs(drift) > Self.jumpTolerance {
                suspect = true
                detail = drift < 0 ? "设备时间被向前调整了约 \(Int(-drift / 60)) 分钟" : "设备时间突然向后跳了约 \(Int(drift / 60)) 分钟"
            }
        } else if let latestWall, wall < latestWall.addingTimeInterval(-Self.serverTolerance) {
            suspect = true
            detail = "设备重启后时间早于此前记录"
        }
    }

    /// Server time is the independent reference available while online.
    public mutating func compare(serverTime: Date, deviceTime: Date, uptime: TimeInterval) {
        let skew = deviceTime.timeIntervalSince(serverTime)
        if abs(skew) > Self.serverTolerance {
            suspect = true
            detail = "设备时间与服务器相差约 \(Int(abs(skew) / 60)) 分钟"
        } else {
            suspect = false
            detail = nil
            latestWall = deviceTime
            last = Sample(wall: deviceTime, uptime: uptime)
        }
    }

    /// A caregiver checked the device clock in person.
    public mutating func caregiverConfirmed(wall: Date, uptime: TimeInterval) {
        suspect = false
        detail = nil
        latestWall = wall
        last = Sample(wall: wall, uptime: uptime)
    }
}

public struct MergeResult: Equatable, Sendable {
    public var snapshot: FamilySnapshot
    public var notes: [String]
}

/// Three-way merge used when a publish meets a newer version. Cancellations made elsewhere always win.
public enum SnapshotMerger {
    public static func merge(base: FamilySnapshot?, mine: FamilySnapshot, theirs: FamilySnapshot) -> MergeResult {
        var notes: [String] = []
        func pick<T: Equatable>(_ b: T?, _ m: T, _ t: T, _ label: String) -> T {
            if m == t || m == b { return t }
            if t == b { return m }
            notes.append("\(label)在其他设备上也被修改，已采用较新版本；请重新检查")
            return t
        }
        var result = theirs
        result.profile = pick(base?.profile, mine.profile, theirs.profile, "患者资料")
        result.segments = pick(base?.segments, mine.segments, theirs.segments, "时段设置")
        result.night = pick(base?.night, mine.night, theirs.night, "夜间设置")
        result.display = pick(base?.display, mine.display, theirs.display, "显示偏好")
        result.voice = pick(base?.voice, mine.voice, theirs.voice, "声音偏好")
        result.place = pick(base?.place, mine.place, theirs.place, "地点提示")
        result.recurring = pick(base?.recurring, mine.recurring, theirs.recurring, "重复安排")
        result.comfortItems = pick(base?.comfortItems, mine.comfortItems, theirs.comfortItems, "安抚内容")
        result.autoPlay = pick(base?.autoPlay, mine.autoPlay, theirs.autoPlay, "自动问候设置")
        result.playLog = pick(base?.playLog, mine.playLog, theirs.playLog, "播放使用记录设置")

        let baseEvents = Dictionary((base?.events ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mineEvents = Dictionary(mine.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirEvents = Dictionary(theirs.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = theirs.events.map(\.id)
        for event in mine.events where theirEvents[event.id] == nil { ids.append(event.id) }

        var merged: [ScheduleEvent] = []
        for id in ids {
            let b = baseEvents[id], m = mineEvents[id], t = theirEvents[id]
            switch (m, t) {
            case let (m?, t?):
                let name = m.personName.isEmpty ? "一项安排" : "「\(m.personName)」"
                if t.isCancelled, b?.isCancelled != true, m != b {
                    notes.append("\(name)已在其他设备取消，你对它的修改没有恢复它")
                    merged.append(t)
                } else {
                    merged.append(pick(b, m, t, name))
                }
            case let (nil, t?):
                merged.append(t)
            case let (m?, nil):
                if b == nil { merged.append(m) }
            case (nil, nil):
                break
            }
        }
        result.events = merged
        result.assetRefs = result.referencedAssets
        return MergeResult(snapshot: result, notes: notes)
    }
}

/// WCAG 2.x contrast, used to keep the patient palettes at or above PRD section 8's 4.5:1 text and 3:1 control targets.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = a.luminance > b.luminance ? (a.luminance, b.luminance) : (b.luminance, a.luminance)
        return (hi + 0.05) / (lo + 0.05)
    }
}

/// Patient screen colors: forest-green wallpapers with light cards, in the spirit of the Home app.
public struct PatientPalette: Sendable {
    /// The wallpaper keeps this color down to `solidUntil` of the screen height, where the time text ends,
    /// then fades to transparent over `base`.
    public var backgroundTop: UInt32
    public var backgroundBottom: UInt32
    public var base: UInt32 = 0xF3F4EF
    public static let solidUntil = 0.6
    public var timeText: UInt32
    public var secondaryTimeText: UInt32
    public var card: UInt32
    public var cardText: UInt32
    public var playFill: UInt32
    public var playText: UInt32
    public var stopFill: UInt32
    public var stopText: UInt32

    public static func of(_ palette: Moment.Palette) -> PatientPalette {
        switch palette {
        case .day:
            PatientPalette(backgroundTop: 0x3F6B52, backgroundBottom: 0x3F6B52, timeText: 0xF7F4EA, secondaryTimeText: 0xE6EEE2,
                           card: 0xFFFFFF, cardText: 0x1C1C1E, playFill: 0x2E6B4F, playText: 0xFFFFFF,
                           stopFill: 0x1C1C1E, stopText: 0xFFFFFF)
        case .evening:
            PatientPalette(backgroundTop: 0x2A4A3C, backgroundBottom: 0x2A4A3C, timeText: 0xF7F4EA, secondaryTimeText: 0xE2EADF,
                           card: 0xFFFBF1, cardText: 0x1C1C1E, playFill: 0x2E6B4F, playText: 0xFFFFFF,
                           stopFill: 0x1C1C1E, stopText: 0xFFFFFF)
        case .night:
            PatientPalette(backgroundTop: 0x122019, backgroundBottom: 0x122019, base: 0x080D0A, timeText: 0xECE7DD,
                           secondaryTimeText: 0xC9C9BC, card: 0x1C2C25, cardText: 0xECE7DD, playFill: 0xE6D9A6,
                           playText: 0x1A1A10, stopFill: 0xECE7DD, stopText: 0x122019)
        }
    }
}
