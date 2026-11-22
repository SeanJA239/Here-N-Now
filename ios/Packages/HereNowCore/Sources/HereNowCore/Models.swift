import Foundation

/// One confirmed, publishable version of everything the patient screen may show.
public struct FamilySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profile: PatientProfile
    public var segments: [DaySegment]
    public var night: NightSettings
    public var display: DisplayPreferences
    public var voice: VoicePreferences
    public var place: PlacePrompt
    public var events: [ScheduleEvent]
    /// Content-addressed assets (SHA-256) the version references; the server refuses a version whose assets are missing.
    public var assetRefs: [String]

    public init(
        profile: PatientProfile,
        segments: [DaySegment] = DaySegment.defaults,
        night: NightSettings = .init(),
        display: DisplayPreferences = .init(),
        voice: VoicePreferences = .init(),
        place: PlacePrompt = .init(),
        events: [ScheduleEvent] = []
    ) {
        self.schemaVersion = 1
        self.profile = profile
        self.segments = segments
        self.night = night
        self.display = display
        self.voice = voice
        self.place = place
        self.events = events
        self.assetRefs = []
    }

    public var timeZone: TimeZone { TimeZone(identifier: profile.timeZoneID) ?? .current }

    /// Every asset the content refers to, recomputed right before publishing.
    public var referencedAssets: [String] {
        var refs: [String] = []
        func add(_ value: String?) { if let value, !refs.contains(value) { refs.append(value) } }
        add(place.photoAssetID)
        add(place.recording?.assetID)
        for event in events where !event.isCancelled {
            add(event.photoAssetID)
            add(event.recording?.assetID)
        }
        return refs
    }

    public func preparedForPublish(now: Date) -> FamilySnapshot {
        var copy = self
        copy.events = events
            .filter { $0.showUntil.addingTimeInterval(Retention.expiredEventDays * 86_400) > now }
            .sorted { $0.start < $1.start }
        copy.segments = segments.sorted { $0.startMinute < $1.startMinute }
        copy.assetRefs = copy.referencedAssets
        return copy
    }
}

public enum Retention {
    /// PRD section 9: expired events are deleted 30 days after they stop showing.
    public static let expiredEventDays: Double = 30
    public static let offlineLeaseDays: Double = 7
    public static let maxRecordingSeconds: Double = 30
}

public struct PatientProfile: Codable, Equatable, Sendable {
    /// How family members address the patient, e.g. 妈妈.
    public var callName: String
    public var timeZoneID: String
    public var languageCode: String

    public init(callName: String, timeZoneID: String, languageCode: String = "zh-CN") {
        self.callName = callName
        self.timeZoneID = timeZoneID
        self.languageCode = languageCode
    }
}

public struct DaySegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Minutes after local midnight in the patient's time zone.
    public var startMinute: Int

    public init(id: String = UUID().uuidString, name: String, startMinute: Int) {
        self.id = id
        self.name = name
        self.startMinute = startMinute
    }

    public static let defaults: [DaySegment] = [
        .init(id: "early", name: "清晨", startMinute: 5 * 60),
        .init(id: "morning", name: "上午", startMinute: 8 * 60),
        .init(id: "noon", name: "中午", startMinute: 11 * 60 + 30),
        .init(id: "afternoon", name: "下午", startMinute: 13 * 60 + 30),
        .init(id: "dusk", name: "傍晚", startMinute: 17 * 60 + 30),
        .init(id: "evening", name: "晚上", startMinute: 19 * 60),
        .init(id: "night", name: "夜里", startMinute: 22 * 60),
    ]
}

public struct NightSettings: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public var hidePhoto: Bool

    public init(startMinute: Int = 21 * 60 + 30, endMinute: Int = 6 * 60, hidePhoto: Bool = true) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.hidePhoto = hidePhoto
    }

    public func contains(minute: Int) -> Bool {
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

public enum CardFocus: String, Codable, Sendable, CaseIterable {
    /// Show the next valid event; fall back to the place prompt.
    case automatic
    /// Always show the place prompt; events are not shown to the patient.
    case placeOnly
}

public enum TextScale: String, Codable, Sendable, CaseIterable {
    case standard, large, extraLarge

    /// Point size of the patient card sentence. PRD section 8 uses 34 pt as the starting floor.
    public var cardPointSize: Double {
        switch self {
        case .standard: 44
        case .large: 52
        case .extraLarge: 60
        }
    }

    public var segmentPointSize: Double { cardPointSize * 1.9 }
    public var datePointSize: Double { max(34, cardPointSize * 0.72) }
    public var buttonPointSize: Double { max(34, cardPointSize * 0.8) }

    public var label: String {
        switch self {
        case .standard: "标准"
        case .large: "大"
        case .extraLarge: "特大"
        }
    }
}

public struct DisplayPreferences: Codable, Equatable, Sendable {
    public var showDate: Bool
    public var focus: CardFocus
    public var textScale: TextScale
    /// Optional caregiver-approved sentence when neither an event nor a place prompt applies.
    public var neutralLine: String

    public init(showDate: Bool = false, focus: CardFocus = .automatic, textScale: TextScale = .standard, neutralLine: String = "") {
        self.showDate = showDate
        self.focus = focus
        self.textScale = textScale
        self.neutralLine = neutralLine
    }
}

public struct VoicePreferences: Codable, Equatable, Sendable {
    /// Read the current sentence with a system voice when no valid family recording exists. Off until a caregiver previews it.
    public var systemSpeechFallback: Bool
    /// Prefix spoken sentences with the patient's call name.
    public var addressByName: Bool

    public init(systemSpeechFallback: Bool = false, addressByName: Bool = true) {
        self.systemSpeechFallback = systemSpeechFallback
        self.addressByName = addressByName
    }
}

/// A family recording bound to the content it explains.
public struct Recording: Codable, Equatable, Sendable {
    public var assetID: String
    public var speakerLabel: String
    public var recordedAt: Date
    public var durationSeconds: Double
    /// Fingerprint of the content when the recording was made or last confirmed to still match.
    public var confirmedFingerprint: String

    public init(assetID: String, speakerLabel: String, recordedAt: Date, durationSeconds: Double, confirmedFingerprint: String) {
        self.assetID = assetID
        self.speakerLabel = speakerLabel
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.confirmedFingerprint = confirmedFingerprint
    }
}

public struct PlacePrompt: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var line: String
    public var photoAssetID: String?
    public var recording: Recording?
    /// After this time the place assertion is hidden until a caregiver confirms it again.
    public var reviewBy: Date?

    public init(enabled: Bool = false, line: String = "", photoAssetID: String? = nil, recording: Recording? = nil, reviewBy: Date? = nil) {
        self.enabled = enabled
        self.line = line
        self.photoAssetID = photoAssetID
        self.recording = recording
        self.reviewBy = reviewBy
    }

    public var fingerprint: String { Fingerprint.of(["place", line]) }

    public var recordingIsCurrent: Bool { recording?.confirmedFingerprint == fingerprint }
}

public struct ScheduleEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var personName: String
    /// The single sentence the patient sees, e.g. 小雨计划下午 3 点来.
    public var line: String
    public var lineIsSuggested: Bool
    public var start: Date
    public var showFrom: Date
    public var showUntil: Date
    public var photoAssetID: String?
    public var recording: Recording?
    public var isCancelled: Bool
    /// When several events share a start time, the caregiver picks the one the patient sees.
    public var preferredOnTie: Bool
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        personName: String,
        line: String,
        lineIsSuggested: Bool = false,
        start: Date,
        showFrom: Date,
        showUntil: Date,
        photoAssetID: String? = nil,
        recording: Recording? = nil,
        isCancelled: Bool = false,
        preferredOnTie: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.personName = personName
        self.line = line
        self.lineIsSuggested = lineIsSuggested
        self.start = start
        self.showFrom = showFrom
        self.showUntil = showUntil
        self.photoAssetID = photoAssetID
        self.recording = recording
        self.isCancelled = isCancelled
        self.preferredOnTie = preferredOnTie
        self.updatedAt = updatedAt
    }

    /// The facts a recording must still match: who, what is said, and when.
    public var fingerprint: String {
        Fingerprint.of(["event", personName, line, String(Int(start.timeIntervalSince1970 / 60))])
    }

    public var recordingIsCurrent: Bool { recording?.confirmedFingerprint == fingerprint }
}

public struct DeviceControls: Codable, Equatable, Sendable {
    public var soundPaused: Bool
    public var displayPaused: Bool

    public init(soundPaused: Bool = false, displayPaused: Bool = false) {
        self.soundPaused = soundPaused
        self.displayPaused = displayPaused
    }
}

public enum Fingerprint {
    /// Stable, dependency-free FNV-1a hash; only used to detect content changes, not for security.
    public static func of(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
