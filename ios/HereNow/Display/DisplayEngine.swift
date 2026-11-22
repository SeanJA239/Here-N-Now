import AVFoundation
import Foundation
import HereNowCore
import Observation
import UIKit

struct AppliedState: Codable, Equatable {
    var version = 0
    var snapshot: FamilySnapshot?
    var controls = DeviceControls()
    var controlsRev = 0
    var localControls = DeviceControls()
    var rev: Int?
    var leaseExpiresAt: Date?
    var appliedAt: Date?
    var lastSyncAt: Date?
    var missingAssets: [String] = []
    var brokenAssets: [String] = []
    var retiredEventIDs: [String] = []
    var clock = ClockGuard()
    var blockedVersion: Int?
    var lastProblem: String?
    var autoPlayLedger = AutoPlayLedger()
    var handledComfortRequestID: String?
    var playLogBuffer: [PlayLogEntry] = []
    var coverageBuffer: [CoverageSpan] = []
    /// When this device started logging; coverage never reaches back before it.
    var playLogEnabledAt: Date?

    init() {}

    /// Older local state files lack the P1 fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        snapshot = try c.decodeIfPresent(FamilySnapshot.self, forKey: .snapshot)
        controls = try c.decode(DeviceControls.self, forKey: .controls)
        controlsRev = try c.decode(Int.self, forKey: .controlsRev)
        localControls = try c.decode(DeviceControls.self, forKey: .localControls)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
        leaseExpiresAt = try c.decodeIfPresent(Date.self, forKey: .leaseExpiresAt)
        appliedAt = try c.decodeIfPresent(Date.self, forKey: .appliedAt)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        missingAssets = try c.decode([String].self, forKey: .missingAssets)
        brokenAssets = try c.decode([String].self, forKey: .brokenAssets)
        retiredEventIDs = try c.decode([String].self, forKey: .retiredEventIDs)
        clock = try c.decode(ClockGuard.self, forKey: .clock)
        blockedVersion = try c.decodeIfPresent(Int.self, forKey: .blockedVersion)
        lastProblem = try c.decodeIfPresent(String.self, forKey: .lastProblem)
        autoPlayLedger = try c.decodeIfPresent(AutoPlayLedger.self, forKey: .autoPlayLedger) ?? AutoPlayLedger()
        handledComfortRequestID = try c.decodeIfPresent(String.self, forKey: .handledComfortRequestID)
        playLogBuffer = try c.decodeIfPresent([PlayLogEntry].self, forKey: .playLogBuffer) ?? []
        coverageBuffer = try c.decodeIfPresent([CoverageSpan].self, forKey: .coverageBuffer) ?? []
        playLogEnabledAt = try c.decodeIfPresent(Date.self, forKey: .playLogEnabledAt)
    }
}

/// Runs the patient device: keeps the last complete version, applies new ones atomically, and reports what it applied.
@MainActor
@Observable
final class DisplayEngine {
    private(set) var credential: DisplayCredential
    private(set) var state: AppliedState
    private(set) var moment: Moment
    private(set) var online = false
    private(set) var connectionProblem: String?
    /// A comfort item a caregiver started; it ends when its recording finishes or anyone stops it.
    private(set) var activeComfort: ComfortItem?
    let playback = PlaybackController()
    var onWiped: (() -> Void)?

    @ObservationIgnored let assets = AssetStore(name: "DisplayAssets")
    @ObservationIgnored private let api: DisplaySyncing
    @ObservationIgnored private let stateURL = LocalFiles.directory("Display").appendingPathComponent("applied.json")
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastReceipt: (version: Int, controlsRev: Int, report: DeviceReport)?
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var foregroundSince = Date()
    @ObservationIgnored private var pendingTrigger: PlayLogEntry.Trigger = .button
    @ObservationIgnored private var lastLogFlush = Date.distantPast
    @ObservationIgnored var layoutWidths = PatientLayout.reportedWidths(for: CGSize(width: 744, height: 1133), scale: .standard)

    init(credential: DisplayCredential, api: DisplaySyncing) {
        self.credential = credential
        self.api = api
        let loaded = LocalFiles.read(AppliedState.self, from: stateURL) ?? AppliedState()
        state = loaded
        moment = MomentResolver.resolve(MomentInput(snapshot: nil, now: Date()))
        playback.onBrokenAsset = { [weak self] asset in self?.markBroken(asset) }
        playback.onStart = { [weak self] audio in self?.logPlay(.started, audio: audio) }
        playback.onEnd = { [weak self] finished in self?.playbackEnded(finished: finished) }
        tick()
    }

    var effectiveControls: DeviceControls {
        DeviceControls(soundPaused: state.controls.soundPaused || state.localControls.soundPaused,
                       displayPaused: state.controls.displayPaused || state.localControls.displayPaused)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.foregroundSince = Date() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCoverage() }
        })
        for name in [UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange,
                     UIApplication.didBecomeActiveNotification, AVAudioSession.routeChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                    Task { await self?.sendReceiptIfNeeded() }
                }
            })
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        ticker?.invalidate()
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        playback.stop()
    }

    func assetURL(_ sha: String) -> URL { assets.url(for: sha) }

    // MARK: Time

    /// Re-evaluates what to show now. Runs every 10 s, on clock or time zone changes, and when returning to the foreground.
    func tick(now: Date = Date()) {
        state.clock.observe(wall: now, uptime: ProcessInfo.processInfo.systemUptime)
        if let snapshot = state.snapshot, !state.clock.suspect {
            let expired = MomentResolver.expiredEventIDs(in: snapshot, now: now)
            if !expired.isSubset(of: Set(state.retiredEventIDs)) {
                state.retiredEventIDs = Array(Set(state.retiredEventIDs).union(expired)).sorted()
                persist(force: true)
            }
        }
        recompute(now: now)
        considerGreeting(now: now)
        extendCoverage(now: now)
        persist()
    }

    private func recompute(now: Date = Date()) {
        let language = state.snapshot?.profile.languageCode ?? "zh-CN"
        let next = MomentResolver.resolve(MomentInput(
            snapshot: state.snapshot,
            controls: effectiveControls,
            now: now,
            leaseExpiresAt: state.leaseExpiresAt,
            clockSuspect: state.clock.suspect,
            availableAssets: assets.all,
            brokenAssets: Set(state.brokenAssets),
            speechAvailable: AudioEnvironment.speechAvailable(language: language),
            retiredEventIDs: Set(state.retiredEventIDs),
            activeComfort: activeComfort
        ))
        if next != moment { moment = next }
        playback.contentChanged(to: next)
    }

    func toggleSound() {
        guard let audio = moment.audio, let card = moment.card else { return }
        pendingTrigger = activeComfort == nil ? .button : .comfort
        playback.toggle(audio: audio, card: card, assetURL: assetURL)
    }

    // MARK: Greetings, comfort, and play log (P1)

    private func considerGreeting(now: Date) {
        guard let snapshot = state.snapshot, activeComfort == nil else { return }
        let context = AutoPlayPlanner.Context(snapshot: snapshot, moment: moment, controls: effectiveControls, now: now,
                                              foregroundSince: foregroundSince, isPlaying: playback.isPlaying,
                                              clockSuspect: state.clock.suspect, ledger: state.autoPlayLedger)
        guard let trigger = AutoPlayPlanner.trigger(context), let audio = moment.audio, let card = moment.card else { return }
        state.autoPlayLedger.record(trigger, at: now)
        persist(force: true)
        pendingTrigger = .greeting
        playback.play(audio: audio, card: card, assetURL: assetURL)
    }

    /// Starts comfort content only for a fresh request; a request that waited while the device was offline is ignored.
    private func applyComfortCommand(serverTime: Date) {
        let controls = state.controls
        guard let requestID = controls.comfortRequestID, let itemID = controls.comfortItemID else {
            if activeComfort != nil { endComfort() }
            return
        }
        guard requestID != state.handledComfortRequestID else { return }
        state.handledComfortRequestID = requestID
        guard let requestedAt = controls.comfortRequestedAt, serverTime.timeIntervalSince(requestedAt) < 120,
              let item = state.snapshot?.comfortItems.first(where: { $0.id == itemID && $0.enabled }),
              !effectiveControls.displayPaused else { return }
        playback.stop()
        activeComfort = item
        recompute()
        guard let audio = moment.audio, let card = moment.card else {
            endComfort()
            return
        }
        pendingTrigger = .comfort
        playback.play(audio: audio, card: card, assetURL: assetURL)
    }

    private func endComfort() {
        activeComfort = nil
        recompute()
    }

    private func playbackEnded(finished: Bool) {
        logPlay(finished ? .finished : .stopped, audio: nil)
        if activeComfort != nil { endComfort() }
    }

    private func logPlay(_ kind: PlayLogEntry.Kind, audio: AudioSource?) {
        guard state.snapshot?.playLog.enabled == true else { return }
        let source: String
        switch audio {
        case .recording?: source = "recording"
        case .speech?: source = "speech"
        case nil: source = state.playLogBuffer.last?.source ?? ""
        }
        state.playLogBuffer.append(PlayLogEntry(at: Date(), kind: kind, trigger: pendingTrigger, source: source))
        if kind != .started { pendingTrigger = .button }
        persist(force: true)
    }

    private func extendCoverage(now: Date) {
        guard state.snapshot?.playLog.enabled == true else {
            state.playLogBuffer = []
            state.coverageBuffer = []
            state.playLogEnabledAt = nil
            return
        }
        let enabledAt = state.playLogEnabledAt ?? now
        state.playLogEnabledAt = enabledAt
        guard UIApplication.shared.applicationState == .active else { return }
        let start = max(foregroundSince, enabledAt)
        if let last = state.coverageBuffer.last, last.start == start {
            state.coverageBuffer[state.coverageBuffer.count - 1].end = now
        } else {
            state.coverageBuffer.append(CoverageSpan(start: start, end: now))
        }
    }

    private func closeCoverage() {
        extendCoverage(now: Date())
        persist(force: true)
    }

    private func flushPlayLog() async {
        guard state.snapshot?.playLog.enabled == true, Date().timeIntervalSince(lastLogFlush) > 60,
              !state.playLogBuffer.isEmpty || !state.coverageBuffer.isEmpty else { return }
        let entries = state.playLogBuffer
        let coverage = state.coverageBuffer
        do {
            try await api.appendPlayLog(token: credential.token, entries: entries, coverage: coverage)
            lastLogFlush = Date()
            state.playLogBuffer.removeFirst(min(entries.count, state.playLogBuffer.count))
            // Keep the open span so it can keep growing; the server merges spans by start time.
            state.coverageBuffer = state.coverageBuffer.suffix(1)
            persist(force: true)
        } catch {}
    }

    func setLocalControls(_ controls: DeviceControls) {
        state.localControls = controls
        persist(force: true)
        recompute()
    }

    func confirmClockInPerson() {
        state.clock.caregiverConfirmed(wall: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist(force: true)
        recompute()
        Task { await sendReceiptIfNeeded() }
    }

    func updateLayout(size: CGSize) {
        let scale = state.snapshot?.display.textScale ?? .standard
        let widths = PatientLayout.reportedWidths(for: size, scale: scale)
        guard widths != layoutWidths else { return }
        layoutWidths = widths
        Task { await sendReceiptIfNeeded() }
    }

    private func markBroken(_ asset: String) {
        guard !state.brokenAssets.contains(asset) else { return }
        state.brokenAssets.append(asset)
        state.lastProblem = "有一段录音无法播放（文件可能损坏），已改用文字"
        persist(force: true)
        recompute()
        Task { await sendReceiptIfNeeded() }
    }

    // MARK: Sync

    private func runLoop() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                let response = try await api.sync(token: credential.token, knownRev: state.rev, knownVersion: state.version, wait: 25)
                online = true
                connectionProblem = nil
                backoff = 1
                if try await handle(response) == false { return }
            } catch {
                online = false
                connectionProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Returns false when the device was revoked and wiped.
    private func handle(_ response: DisplaySyncResponse) async throws -> Bool {
        guard response.status == "active" else {
            await wipe()
            return false
        }
        let now = Date()
        state.lastSyncAt = now
        state.leaseExpiresAt = response.leaseExpiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        state.clock.compare(serverTime: Date(timeIntervalSince1970: response.serverTime / 1000), deviceTime: now,
                            uptime: ProcessInfo.processInfo.systemUptime)
        if let familyName = response.familyName, familyName != credential.familyName {
            credential.familyName = familyName
            Keychain.save(credential, key: "display")
        }
        if let controls = response.controls, let rev = response.controlsRev, rev != state.controlsRev {
            state.controls = controls
            state.controlsRev = rev
            applyComfortCommand(serverTime: Date(timeIntervalSince1970: response.serverTime / 1000))
        }
        if let version = response.version, version != state.version, let snapshot = response.snapshot {
            await apply(snapshot, version: version)
        } else if !state.missingAssets.isEmpty, let snapshot = state.snapshot {
            await apply(snapshot, version: state.version)
        }
        state.rev = response.rev
        persist(force: true)
        recompute()
        await sendReceiptIfNeeded()
        await flushPlayLog()
        return true
    }

    /// Downloads and verifies every asset first; the visible version only switches once the new one is complete.
    private func apply(_ snapshot: FamilySnapshot, version: Int) async {
        var missing: [String] = []
        for sha in snapshot.assetRefs where !assets.contains(sha) {
            do {
                let data = try await api.downloadAsset(token: credential.token, sha256: sha)
                guard AssetStore.sha256(data) == sha else { missing.append(sha); continue }
                try assets.store(data)
            } catch SyncError.storageFull {
                state.blockedVersion = version
                state.lastProblem = "存储空间不足，第 \(version) 版未应用，仍显示第 \(state.version) 版"
                return
            } catch {
                missing.append(sha)
            }
        }
        let referenced = Set(snapshot.assetRefs)
        let eventIDs = Set(snapshot.events.map(\.id) + snapshot.recurring.map(\.id))
        state.snapshot = snapshot
        if state.version != version { state.appliedAt = Date() }
        state.version = version
        state.missingAssets = missing
        state.brokenAssets = state.brokenAssets.filter(referenced.contains)
        state.retiredEventIDs = state.retiredEventIDs.filter { eventIDs.contains(String($0.split(separator: "@").first ?? "")) }
        state.blockedVersion = nil
        state.lastProblem = missing.isEmpty ? nil : "有 \(missing.count) 个照片或录音未下载，已先用文字显示"
        assets.removeAll(except: referenced)
    }

    func makeReport() -> DeviceReport {
        let language = state.snapshot?.profile.languageCode ?? "zh-CN"
        return DeviceReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            timeZoneID: TimeZone.current.identifier,
            deviceTime: Date().timeIntervalSince1970 * 1000,
            clockSuspect: state.clock.suspect,
            clockDetail: state.clock.detail,
            audioRoute: AudioEnvironment.currentRoute,
            speechAvailable: AudioEnvironment.speechAvailable(language: language),
            missingAssets: state.missingAssets,
            brokenAssets: state.brokenAssets,
            storageLow: !LocalFiles.hasRoom(for: 20_000_000),
            lastProblem: state.lastProblem,
            textWidthWithPhoto: layoutWidths.withPhoto,
            textWidthWithoutPhoto: layoutWidths.withoutPhoto,
            leaseExpiresAt: state.leaseExpiresAt.map { $0.timeIntervalSince1970 * 1000 }
        )
    }

    func sendReceiptIfNeeded() async {
        let report = makeReport()
        if let last = lastReceipt, last.version == state.version, last.controlsRev == state.controlsRev, report.sameFacts(as: last.report) {
            return
        }
        do {
            try await api.sendReceipt(token: credential.token, appliedVersion: state.version, appliedControlsRev: state.controlsRev, report: report)
            lastReceipt = (state.version, state.controlsRev, report)
        } catch {
            connectionProblem = (error as? LocalizedError)?.errorDescription
        }
    }

    // MARK: Lifecycle

    /// Removes every piece of family data from this device, then tells the service so the caregiver sees “已清除”.
    /// Wiping can start inside the sync loop, which `stop()` cancels, so the confirmation runs in its own task;
    /// if it still fails, the token is kept only for that call and retried on the next launch.
    func wipe() async {
        let token = credential.token
        stop()
        assets.wipe()
        try? FileManager.default.removeItem(at: stateURL)
        Keychain.delete("display")
        Keychain.delete("pin")
        state = AppliedState()
        recompute()
        Keychain.save(token, key: "wipeConfirmPending")
        onWiped?()
        await Self.confirmWipe(token: token, api: api)
    }

    static func confirmWipe(token: String, api: DisplaySyncing) async {
        await Task {
            for attempt in 0..<5 {
                do {
                    try await api.confirmWipe(token: token)
                    Keychain.delete("wipeConfirmPending")
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                }
            }
        }.value
    }

    private func persist(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPersist) > 60 else { return }
        lastPersist = Date()
        try? LocalFiles.write(state, to: stateURL)
    }
}

/// Patient screen geometry, shared by the screen itself and by the caregiver's line-length check.
enum PatientLayout {
    struct Widths: Equatable { var withPhoto: Double; var withoutPhoto: Double }

    static let outerMargin: CGFloat = 48
    static let cardPadding: CGFloat = 40
    static let photoSpacing: CGFloat = 32
    static let maxCardWidth: CGFloat = 980

    static func cardWidth(for size: CGSize) -> CGFloat {
        min(size.width - outerMargin * 2, maxCardWidth)
    }

    static func photoSide(cardWidth: CGFloat, scale: TextScale) -> CGFloat {
        min(240, cardWidth * 0.3)
    }

    /// The narrowest orientation decides, so a sentence that fits is never truncated after rotating the iPad.
    static func reportedWidths(for size: CGSize, scale: TextScale) -> Widths {
        let portrait = CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
        let card = cardWidth(for: portrait)
        let inner = card - cardPadding * 2
        return Widths(withPhoto: Double(inner - photoSide(cardWidth: card, scale: scale) - photoSpacing), withoutPhoto: Double(inner))
    }

    static let fallbackWidths = reportedWidths(for: CGSize(width: 744, height: 1133), scale: .standard)
}
