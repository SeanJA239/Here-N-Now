import Foundation

// MARK: Recurring events

/// A weekly plan such as “小雨每周六下午 3 点来”. Each day it applies becomes an ordinary event,
/// so every P0 rule (display window, ties, stale recordings, retirement) applies unchanged.
public struct RecurringEvent: Codable, Equatable, Sendable, Identifiable {
    public enum ShowFrom: String, Codable, Sendable, CaseIterable { case sameDay, dayBefore }

    public var id: String
    public var personName: String
    public var line: String
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday, in the patient's time zone.
    public var weekdays: [Int]
    public var startMinute: Int
    /// How long after the start the occurrence keeps showing; the caregiver chooses it explicitly.
    public var showForMinutes: Int
    public var showFrom: ShowFrom
    /// First and last day (yyyy-MM-dd, patient time zone). `lastDay` nil means no end.
    public var firstDay: String
    public var lastDay: String?
    /// Single days the caregiver cancelled (yyyy-MM-dd).
    public var skippedDays: [String]
    public var photoAssetID: String?
    public var recording: Recording?
    public var isCancelled: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, personName: String, line: String, weekdays: [Int], startMinute: Int,
                showForMinutes: Int, showFrom: ShowFrom = .sameDay, firstDay: String, lastDay: String? = nil,
                skippedDays: [String] = [], photoAssetID: String? = nil, recording: Recording? = nil,
                isCancelled: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.personName = personName
        self.line = line
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.showForMinutes = showForMinutes
        self.showFrom = showFrom
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.skippedDays = skippedDays
        self.photoAssetID = photoAssetID
        self.recording = recording
        self.isCancelled = isCancelled
        self.updatedAt = updatedAt
    }

    /// What a recording of the plan must still match: who, what is said, and when in the week.
    public var fingerprint: String {
        Fingerprint.of(["recurring", personName, line, String(startMinute), weekdays.sorted().map(String.init).joined(separator: ",")])
    }

    public var recordingIsCurrent: Bool { recording?.confirmedFingerprint == fingerprint }

    /// Occurrences whose display window overlaps [from, to].
    public func occurrences(from: Date, to: Date, in zone: TimeZone) -> [ScheduleEvent] {
        guard !isCancelled, !weekdays.isEmpty, showForMinutes > 0 else { return [] }
        let calendar = DayKey.calendar(zone)
        guard var day = DayKey.date(firstDay, zone: zone) else { return [] }
        let last = lastDay.flatMap { DayKey.date($0, zone: zone) }
        let scanStart = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: from))!
        if day < scanStart { day = scanStart }
        var result: [ScheduleEvent] = []
        while day <= to {
            if let last, day > last { break }
            let key = DayKey.string(day, zone: zone)
            if weekdays.contains(calendar.component(.weekday, from: day)), !skippedDays.contains(key),
               let start = calendar.date(byAdding: .minute, value: startMinute, to: day) {
                let until = start.addingTimeInterval(TimeInterval(showForMinutes * 60))
                let visibleFrom = showFrom == .sameDay ? day : calendar.date(byAdding: .day, value: -1, to: day)!
                if until > from, visibleFrom <= to {
                    var occurrence = ScheduleEvent(id: "\(id)@\(key)", personName: personName, line: line, start: start,
                                                   showFrom: visibleFrom, showUntil: until, photoAssetID: photoAssetID,
                                                   updatedAt: updatedAt)
                    if var recording {
                        recording.confirmedFingerprint = recordingIsCurrent ? occurrence.fingerprint : "stale"
                        occurrence.recording = recording
                    }
                    result.append(occurrence)
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    public static func weekdayNames(_ days: [Int]) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        if Set(days) == Set(1...7) { return "每天" }
        return "每周" + days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }.joined(separator: "、")
    }
}

public enum DayKey {
    public static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    public static func string(_ date: Date, zone: TimeZone) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func date(_ key: String, zone: TimeZone) -> Date? {
        let bits = key.split(separator: "-").compactMap { Int($0) }
        guard bits.count == 3 else { return nil }
        return calendar(zone).date(from: DateComponents(year: bits[0], month: bits[1], day: bits[2]))
    }
}

extension FamilySnapshot {
    /// One-off events plus recurring occurrences near `now`; the resolver and validator both use this list.
    public func effectiveEvents(around now: Date) -> [ScheduleEvent] {
        let from = now.addingTimeInterval(-86_400)
        let to = now.addingTimeInterval(8 * 86_400)
        return events + recurring.flatMap { $0.occurrences(from: from, to: to, in: timeZone) }
    }
}

// MARK: Comfort content

/// A soothing recording or photo the caregiver chose for this person. Started by hand; never on a timer in this version.
public struct ComfortItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Caregiver-facing name, e.g. “小雨唱的歌”.
    public var title: String
    /// Optional one sentence shown to the patient while it plays.
    public var line: String
    public var photoAssetID: String?
    public var recording: Recording?
    public var enabled: Bool

    public init(id: String = UUID().uuidString, title: String, line: String = "", photoAssetID: String? = nil,
                recording: Recording? = nil, enabled: Bool = true) {
        self.id = id
        self.title = title
        self.line = line
        self.photoAssetID = photoAssetID
        self.recording = recording
        self.enabled = enabled
    }

    public static let fingerprint = Fingerprint.of(["comfort"])
}

// MARK: Scheduled greetings

public struct AutoPlaySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Greet once before each event, this many minutes ahead of its start.
    public var greetBeforeEvents: Bool
    public var leadMinutes: Int
    /// Greet once when each of these segments begins.
    public var segmentIDs: [String]
    public var quietStartMinute: Int
    public var quietEndMinute: Int
    public var dailyLimit: Int
    public var minIntervalMinutes: Int

    public init(enabled: Bool = false, greetBeforeEvents: Bool = true, leadMinutes: Int = 30, segmentIDs: [String] = [],
                quietStartMinute: Int = 21 * 60, quietEndMinute: Int = 8 * 60, dailyLimit: Int = 3, minIntervalMinutes: Int = 60) {
        self.enabled = enabled
        self.greetBeforeEvents = greetBeforeEvents
        self.leadMinutes = leadMinutes
        self.segmentIDs = segmentIDs
        self.quietStartMinute = quietStartMinute
        self.quietEndMinute = quietEndMinute
        self.dailyLimit = dailyLimit
        self.minIntervalMinutes = minIntervalMinutes
    }
}

/// What has already been auto-played on this device. Kept locally; never uploaded.
public struct AutoPlayLedger: Codable, Equatable, Sendable {
    public var usedTriggers: [String: Date] = [:]
    public var lastPlayedAt: Date?

    public init() {}

    public mutating func record(_ trigger: String, at date: Date) {
        usedTriggers[trigger] = date
        lastPlayedAt = date
        usedTriggers = usedTriggers.filter { date.timeIntervalSince($0.value) < 3 * 86_400 }
    }

    func plays(onDayOf date: Date, zone: TimeZone) -> Int {
        let day = DayKey.string(date, zone: zone)
        return usedTriggers.values.filter { DayKey.string($0, zone: zone) == day }.count
    }
}

public enum AutoPlayPlanner {
    /// A trigger fires only if it happened in the last two minutes while the app was in the foreground,
    /// so nothing missed offline, in the background, or before a clock jump is ever played late.
    public static let freshness: TimeInterval = 120

    public struct Context: Sendable {
        public var snapshot: FamilySnapshot
        public var moment: Moment
        public var controls: DeviceControls
        public var now: Date
        public var foregroundSince: Date
        public var isPlaying: Bool
        public var clockSuspect: Bool
        public var ledger: AutoPlayLedger

        public init(snapshot: FamilySnapshot, moment: Moment, controls: DeviceControls, now: Date, foregroundSince: Date,
                    isPlaying: Bool, clockSuspect: Bool, ledger: AutoPlayLedger) {
            self.snapshot = snapshot
            self.moment = moment
            self.controls = controls
            self.now = now
            self.foregroundSince = foregroundSince
            self.isPlaying = isPlaying
            self.clockSuspect = clockSuspect
            self.ledger = ledger
        }
    }

    /// Returns the trigger key to play now, or nil. Stopping, pausing, and quiet hours always win.
    public static func trigger(_ c: Context) -> String? {
        let settings = c.snapshot.autoPlay
        guard settings.enabled, !c.controls.soundPaused, !c.controls.displayPaused, !c.isPlaying, !c.clockSuspect,
              c.moment.mode == .content, let card = c.moment.card, c.moment.audio != nil else { return nil }
        let zone = c.snapshot.timeZone
        let minute = MomentResolver.minuteOfDay(c.now, in: zone)
        let quiet = NightSettings(startMinute: settings.quietStartMinute, endMinute: settings.quietEndMinute, hidePhoto: false)
        if quiet.contains(minute: minute) { return nil }
        if c.ledger.plays(onDayOf: c.now, zone: zone) >= settings.dailyLimit { return nil }
        if let last = c.ledger.lastPlayedAt, c.now.timeIntervalSince(last) < TimeInterval(settings.minIntervalMinutes * 60) { return nil }

        var candidates: [(key: String, at: Date)] = []
        if settings.greetBeforeEvents, case let .event(id) = card.kind,
           let event = c.snapshot.effectiveEvents(around: c.now).first(where: { $0.id == id }) {
            candidates.append(("event:\(id):\(event.fingerprint)", event.start.addingTimeInterval(TimeInterval(-settings.leadMinutes * 60))))
        }
        let calendar = DayKey.calendar(zone)
        let today = calendar.startOfDay(for: c.now)
        for segment in c.snapshot.segments where settings.segmentIDs.contains(segment.id) {
            let at = calendar.date(byAdding: .minute, value: segment.startMinute, to: today)!
            candidates.append(("segment:\(segment.id):\(DayKey.string(c.now, zone: zone))", at))
        }
        return candidates.first { candidate in
            c.ledger.usedTriggers[candidate.key] == nil
                && candidate.at <= c.now
                && c.now.timeIntervalSince(candidate.at) <= freshness
                && c.foregroundSince <= candidate.at
        }?.key
    }
}

// MARK: Playback log

public struct PlayLogSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }
    public static let retentionDays: Double = 7
}

/// Only that a sound started or stopped, from where, and when. Never audio or anything the patient said.
public struct PlayLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case started, stopped, finished }
    public enum Trigger: String, Codable, Sendable { case button, greeting, comfort }

    public var at: Date
    public var kind: Kind
    public var trigger: Trigger
    public var source: String

    public init(at: Date, kind: Kind, trigger: Trigger, source: String) {
        self.at = at
        self.kind = kind
        self.trigger = trigger
        self.source = source
    }
}

/// A span when the app was open in the foreground, so the caregiver can tell “no plays” from “no data”.
public struct CoverageSpan: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum PlayLogSummary {
    public struct Day: Equatable, Sendable {
        public var day: String
        public var buttonStarts: Int
        public var greetingStarts: Int
        public var comfortStarts: Int
        public var coveredMinutes: Int
    }

    /// Counts starts per day and the minutes the log was actually recording. Days without coverage are reported as such, never as zero use.
    public static func days(entries: [PlayLogEntry], coverage: [CoverageSpan], zone: TimeZone, endingAt now: Date, count: Int = 7) -> [Day] {
        let calendar = DayKey.calendar(zone)
        let today = calendar.startOfDay(for: now)
        return (0..<count).map { offset in
            let start = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = min(calendar.date(byAdding: .day, value: 1, to: start)!, now)
            let inDay = entries.filter { $0.kind == .started && $0.at >= start && $0.at < end }
            let covered = coverage.reduce(0.0) { total, span in
                total + max(0, min(span.end, end).timeIntervalSince(max(span.start, start)))
            }
            return Day(day: DayKey.string(start, zone: zone),
                       buttonStarts: inDay.filter { $0.trigger == .button }.count,
                       greetingStarts: inDay.filter { $0.trigger == .greeting }.count,
                       comfortStarts: inDay.filter { $0.trigger == .comfort }.count,
                       coveredMinutes: Int(covered / 60))
        }
    }
}
