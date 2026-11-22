import Foundation

/// What the patient screen shows at one instant.
public struct Moment: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Personal content from a valid, applied version.
        case content
        /// No family content may be shown; only time. The reason is for the management screen, never the patient.
        case neutral(NeutralReason)
    }

    public enum NeutralReason: String, Equatable, Sendable {
        case notConfigured, paused, leaseExpired, clockSuspect
    }

    public enum Palette: String, Equatable, Sendable { case day, evening, night }

    public var mode: Mode
    public var segmentName: String
    public var dateLine: String?
    public var palette: Palette
    public var card: Card?
    public var audio: AudioSource?
    public var textScale: TextScale

    public var isNight: Bool { palette == .night }
}

public struct Card: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case event(id: String)
        case place
        case neutralLine
        case comfort(id: String)
    }

    public var kind: Kind
    public var line: String
    public var photoAssetID: String?
    /// Changes whenever the facts on the card change; playback of an older identity must stop.
    public var identity: String

    public init(kind: Kind, line: String, photoAssetID: String?, identity: String) {
        self.kind = kind
        self.line = line
        self.photoAssetID = photoAssetID
        self.identity = identity
    }
}

public enum AudioSource: Equatable, Sendable {
    case recording(assetID: String, speakerLabel: String)
    case speech(text: String, languageCode: String)

    public var identity: String {
        switch self {
        case let .recording(assetID, _): "rec:\(assetID)"
        case let .speech(text, _): "tts:\(Fingerprint.of([text]))"
        }
    }
}

public struct MomentInput: Sendable {
    public var snapshot: FamilySnapshot?
    public var controls: DeviceControls
    public var now: Date
    public var leaseExpiresAt: Date?
    public var clockSuspect: Bool
    /// Assets present and verified on this device.
    public var availableAssets: Set<String>
    /// Assets that failed to decode on this device.
    public var brokenAssets: Set<String>
    public var speechAvailable: Bool
    /// Events this device has already seen expire; they never come back even if the clock jumps backwards.
    public var retiredEventIDs: Set<String>
    /// A comfort item a caregiver started by hand; shown instead of the usual card until it ends.
    public var activeComfort: ComfortItem?

    public init(
        snapshot: FamilySnapshot?,
        controls: DeviceControls = .init(),
        now: Date,
        leaseExpiresAt: Date? = nil,
        clockSuspect: Bool = false,
        availableAssets: Set<String> = [],
        brokenAssets: Set<String> = [],
        speechAvailable: Bool = true,
        retiredEventIDs: Set<String> = [],
        activeComfort: ComfortItem? = nil
    ) {
        self.snapshot = snapshot
        self.controls = controls
        self.now = now
        self.leaseExpiresAt = leaseExpiresAt
        self.clockSuspect = clockSuspect
        self.availableAssets = availableAssets
        self.brokenAssets = brokenAssets
        self.speechAvailable = speechAvailable
        self.retiredEventIDs = retiredEventIDs
        self.activeComfort = activeComfort
    }
}

public enum MomentResolver {
    public static func resolve(_ input: MomentInput) -> Moment {
        guard let snapshot = input.snapshot else {
            return neutral(.notConfigured, now: input.now, segments: DaySegment.defaults, night: NightSettings(),
                           timeZone: .current, showDate: true, scale: .standard)
        }
        let zone = snapshot.timeZone
        let minute = minuteOfDay(input.now, in: zone)
        let showDate = snapshot.display.showDate
        if input.controls.displayPaused {
            return neutral(.paused, now: input.now, segments: snapshot.segments, night: snapshot.night, timeZone: zone,
                           showDate: showDate, scale: snapshot.display.textScale)
        }
        if let lease = input.leaseExpiresAt, input.now >= lease {
            return neutral(.leaseExpired, now: input.now, segments: snapshot.segments, night: snapshot.night, timeZone: zone,
                           showDate: true, scale: snapshot.display.textScale)
        }

        let palette = palette(minute: minute, night: snapshot.night)
        let usable = { (asset: String?) -> String? in
            guard let asset, input.availableAssets.contains(asset), !input.brokenAssets.contains(asset) else { return nil }
            return asset
        }
        let hidePhoto = palette == .night && snapshot.night.hidePhoto

        var card: Card?
        var recording: Recording?
        if let comfort = input.activeComfort {
            let fallback = comfort.recording.map { "\($0.speakerLabel)的声音" } ?? ""
            card = Card(kind: .comfort(id: comfort.id), line: comfort.line.isEmpty ? fallback : comfort.line,
                        photoAssetID: hidePhoto ? nil : usable(comfort.photoAssetID), identity: "comfort:\(comfort.id)")
            recording = comfort.recording
        } else if snapshot.display.focus == .automatic, !input.clockSuspect,
           let event = currentEvent(in: snapshot, now: input.now, retired: input.retiredEventIDs) {
            card = Card(kind: .event(id: event.id), line: event.line,
                        photoAssetID: hidePhoto ? nil : usable(event.photoAssetID),
                        identity: "event:\(event.id):\(event.fingerprint)")
            recording = event.recordingIsCurrent ? event.recording : nil
        } else if placeIsValid(snapshot.place, now: input.now, clockSuspect: input.clockSuspect) {
            let place = snapshot.place
            card = Card(kind: .place, line: place.line, photoAssetID: hidePhoto ? nil : usable(place.photoAssetID),
                        identity: "place:\(place.fingerprint)")
            recording = place.recordingIsCurrent ? place.recording : nil
        } else if !snapshot.display.neutralLine.trimmingCharacters(in: .whitespaces).isEmpty {
            let line = snapshot.display.neutralLine
            card = Card(kind: .neutralLine, line: line, photoAssetID: nil, identity: "neutral:\(Fingerprint.of([line]))")
        }

        var audio: AudioSource?
        if let card, !input.controls.soundPaused {
            if let recording, usable(recording.assetID) != nil {
                audio = .recording(assetID: recording.assetID, speakerLabel: recording.speakerLabel)
            } else if input.activeComfort == nil, snapshot.voice.systemSpeechFallback, input.speechAvailable {
                audio = .speech(text: spokenText(card.line, snapshot: snapshot), languageCode: snapshot.profile.languageCode)
            }
        }

        let mode: Moment.Mode = input.clockSuspect && card == nil ? .neutral(.clockSuspect) : .content
        return Moment(
            mode: mode,
            segmentName: segmentName(minute: minute, segments: snapshot.segments),
            dateLine: showDate ? dateLine(input.now, in: zone) : nil,
            palette: palette,
            card: card,
            audio: audio,
            textScale: snapshot.display.textScale
        )
    }

    /// The single event the patient should see: valid, not cancelled, inside its display window, earliest start first.
    public static func currentEvent(in snapshot: FamilySnapshot, now: Date, retired: Set<String> = []) -> ScheduleEvent? {
        let live = snapshot.effectiveEvents(around: now).filter {
            !$0.isCancelled && !retired.contains($0.id) && $0.showFrom <= now && now < $0.showUntil
        }
        guard let earliest = live.map(\.start).min() else { return nil }
        let tied = live.filter { sameMinute($0.start, earliest) }
        return tied.first(where: \.preferredOnTie) ?? tied.min { $0.id < $1.id }
    }

    /// Event IDs whose display window has closed at `now`; the caller persists them so a clock jump cannot revive them.
    public static func expiredEventIDs(in snapshot: FamilySnapshot, now: Date) -> Set<String> {
        Set(snapshot.effectiveEvents(around: now).filter { now >= $0.showUntil }.map(\.id))
    }

    public static func placeIsValid(_ place: PlacePrompt, now: Date, clockSuspect: Bool) -> Bool {
        guard !clockSuspect, place.enabled, !place.line.trimmingCharacters(in: .whitespaces).isEmpty,
              let reviewBy = place.reviewBy else { return false }
        return now < reviewBy
    }

    public static func spokenText(_ line: String, snapshot: FamilySnapshot) -> String {
        let name = snapshot.profile.callName.trimmingCharacters(in: .whitespaces)
        guard snapshot.voice.addressByName, !name.isEmpty else { return line }
        return "\(name)，\(line)"
    }

    public static func segmentName(minute: Int, segments: [DaySegment]) -> String {
        let sorted = segments.sorted { $0.startMinute < $1.startMinute }
        guard let last = sorted.last else { return "" }
        return sorted.last(where: { $0.startMinute <= minute })?.name ?? last.name
    }

    public static func palette(minute: Int, night: NightSettings) -> Moment.Palette {
        if night.contains(minute: minute) { return .night }
        return minute >= 17 * 60 || minute < 5 * 60 ? .evening : .day
    }

    public static func minuteOfDay(_ date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    public static func dateLine(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    static func sameMinute(_ a: Date, _ b: Date) -> Bool {
        Int(a.timeIntervalSince1970 / 60) == Int(b.timeIntervalSince1970 / 60)
    }

    private static func neutral(_ reason: Moment.NeutralReason, now: Date, segments: [DaySegment], night: NightSettings,
                                timeZone: TimeZone, showDate: Bool, scale: TextScale) -> Moment {
        let minute = minuteOfDay(now, in: timeZone)
        return Moment(
            mode: .neutral(reason),
            segmentName: segmentName(minute: minute, segments: segments),
            dateLine: showDate ? dateLine(now, in: timeZone) : nil,
            palette: palette(minute: minute, night: night),
            card: nil,
            audio: nil,
            textScale: scale
        )
    }
}
