import Foundation
import HereNowCore
import Observation

struct ContentDraft: Codable, Equatable {
    var baseVersion: Int
    var baseSnapshot: FamilySnapshot?
    var snapshot: FamilySnapshot
    var mergeNotes: [String] = []
}

struct PendingPublish: Codable, Equatable {
    var publishID: String
    var baseVersion: Int
    var baseSnapshot: FamilySnapshot?
    var snapshot: FamilySnapshot
    var createdAt: Date
    var lastError: String?
}

private struct CaregiverLocalState: Codable {
    var family: FamilyState?
    var draft: ContentDraft?
    var outbox: PendingPublish?
    var lastFetchAt: Date?
}

/// Delivery status shown to the caregiver. Never says the patient “knows” anything; only what software applied.
enum DeliveryStatus: Equatable {
    case nothingPublished
    case savedLocally(error: String?)
    case awaitingDevice(version: Int, devices: [String])
    case applied(version: Int)
    case noDisplay(version: Int)
}

@MainActor
@Observable
final class CaregiverStore {
    private(set) var credential: CaregiverCredential
    private(set) var family: FamilyState?
    private(set) var draft: ContentDraft?
    private(set) var outbox: PendingPublish?
    private(set) var online = false
    private(set) var connectionProblem: String?
    private(set) var lastFetchAt: Date?
    private(set) var actionError: String?
    var onSignedOut: ((String) -> Void)?

    @ObservationIgnored let assets = AssetStore(name: "CaregiverAssets")
    @ObservationIgnored let api: CaregiverSyncing
    @ObservationIgnored private let stateURL = LocalFiles.directory("Caregiver").appendingPathComponent("state.json")
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var flushing = false

    init(credential: CaregiverCredential, api: CaregiverSyncing, initialDraft: FamilySnapshot? = nil) {
        self.credential = credential
        self.api = api
        let local = LocalFiles.read(CaregiverLocalState.self, from: stateURL)
        family = local?.family
        draft = local?.draft
        outbox = local?.outbox
        lastFetchAt = local?.lastFetchAt
        if let initialDraft, draft == nil, family?.snapshot == nil {
            draft = ContentDraft(baseVersion: 0, baseSnapshot: nil, snapshot: initialDraft)
            persist()
        }
    }

    // MARK: Reading

    var publishedSnapshot: FamilySnapshot? { family?.snapshot }
    var currentVersion: Int { family?.currentVersion ?? 0 }
    var patientTimeZone: TimeZone { (draft?.snapshot ?? publishedSnapshot)?.timeZone ?? .current }

    /// The snapshot the editor works on; drafts are never visible to the patient until published.
    var workingSnapshot: FamilySnapshot {
        draft?.snapshot ?? publishedSnapshot ?? FamilySnapshot(profile: .init(callName: "", timeZoneID: TimeZone.current.identifier))
    }

    var deliveryStatus: DeliveryStatus {
        if let outbox { return .savedLocally(error: outbox.lastError) }
        guard let family, family.currentVersion > 0 else { return .nothingPublished }
        let displays = family.activeDisplays
        if displays.isEmpty { return .noDisplay(version: family.currentVersion) }
        let behind = displays.filter { ($0.appliedVersion ?? 0) < family.currentVersion }
        if behind.isEmpty { return .applied(version: family.currentVersion) }
        return .awaitingDevice(version: family.currentVersion, devices: behind.map(\.name))
    }

    /// Text widths reported by the paired patient screens; the narrowest one decides whether a sentence fits.
    var displayTextWidths: PatientLayout.Widths {
        let reports = family?.activeDisplays.compactMap(\.report) ?? []
        guard !reports.isEmpty else { return PatientLayout.fallbackWidths }
        return PatientLayout.Widths(withPhoto: reports.map(\.textWidthWithPhoto).min()!,
                                    withoutPhoto: reports.map(\.textWidthWithoutPhoto).min()!)
    }

    func fits(_ line: String, hasPhoto: Bool, scale: TextScale) -> Bool {
        let widths = displayTextWidths
        return TextFit.fits(line, scale: scale, width: hasPhoto ? widths.withPhoto : widths.withoutPhoto)
    }

    func validate(_ snapshot: FamilySnapshot) -> [ValidationIssue] {
        PublishValidator.validate(snapshot, now: Date()) { [self] line, hasPhoto in
            fits(line, hasPhoto: hasPhoto, scale: snapshot.display.textScale)
        }
    }

    // MARK: Sync loop

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refreshNow() async {
        do {
            apply(try await api.familyState(token: credential.token, waitRev: nil))
        } catch {
            handle(error)
        }
    }

    private func runLoop() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                let state = try await api.familyState(token: credential.token, waitRev: family?.rev)
                apply(state)
                backoff = 1
                await flushOutbox()
            } catch {
                handle(error)
                if case SyncError.server(410, _) = error { return }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 20)
            }
        }
    }

    private func apply(_ state: FamilyState) {
        online = true
        connectionProblem = nil
        family = state
        lastFetchAt = Date()
        if credential.familyName != state.family.name {
            credential.familyName = state.family.name
            Keychain.save(credential, key: "caregiver")
        }
        persist()
    }

    private func handle(_ error: Error) {
        if case let SyncError.server(410, code) = error {
            signOutLocally(reason: SyncError.message(for: code))
            return
        }
        online = false
        connectionProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Drafts and publishing

    func edit(_ mutate: (inout FamilySnapshot) -> Void) {
        var current = draft ?? ContentDraft(baseVersion: currentVersion, baseSnapshot: publishedSnapshot, snapshot: workingSnapshot)
        mutate(&current.snapshot)
        draft = current
        persist()
    }

    func discardDraft() {
        draft = nil
        persist()
    }

    var hasUnpublishedChanges: Bool {
        guard let draft else { return false }
        return draft.snapshot != publishedSnapshot || draft.baseVersion != currentVersion
    }

    /// Saves the confirmed version locally first, so a network failure never loses it, then sends it.
    func publishDraft() async {
        guard let draft else { return }
        outbox = PendingPublish(publishID: UUID().uuidString, baseVersion: draft.baseVersion, baseSnapshot: draft.baseSnapshot,
                                snapshot: draft.snapshot.preparedForPublish(now: Date()), createdAt: Date())
        self.draft = nil
        persist()
        await flushOutbox()
    }

    func flushOutbox() async {
        guard var pending = outbox, !flushing else { return }
        flushing = true
        defer { flushing = false }
        do {
            for sha in pending.snapshot.assetRefs {
                guard let data = assets.data(for: sha) else {
                    pending.lastError = "本机找不到一个照片或录音文件，请在编辑中替换后重新发布"
                    outbox = pending
                    persist()
                    return
                }
                try await api.uploadAsset(token: credential.token, sha256: sha, data: data, mime: Self.mime(of: data))
            }
            switch try await api.publish(token: credential.token, baseVersion: pending.baseVersion, publishID: pending.publishID,
                                         snapshot: pending.snapshot) {
            case .published:
                outbox = nil
                await refreshNow()
            case let .conflict(version, theirs):
                let merged = theirs.map { SnapshotMerger.merge(base: pending.baseSnapshot, mine: pending.snapshot, theirs: $0) }
                draft = ContentDraft(baseVersion: version, baseSnapshot: theirs, snapshot: merged?.snapshot ?? pending.snapshot,
                                     mergeNotes: ["其他设备已发布了较新的第 \(version) 版。你的修改已合并为草稿，请检查后重新发布。"]
                                         + (merged?.notes ?? []))
                outbox = nil
            case .missingAssets:
                pending.lastError = "同步服务没有收到全部素材，将自动重试"
                outbox = pending
            }
        } catch {
            if case SyncError.server(410, _) = error { handle(error); return }
            pending.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            outbox = pending
        }
        persist()
    }

    static func mime(of data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.count >= 8, String(bytes: head[4..<8], encoding: .ascii) == "ftyp" { return "audio/mp4" }
        return "application/octet-stream"
    }

    // MARK: Devices and controls

    func setControls(_ controls: DeviceControls) async {
        await run { try await self.api.setControls(token: self.credential.token, controls: controls) }
    }

    func createPairingCode() async -> PairingCode? {
        actionError = nil
        do {
            return try await api.createPairingCode(token: credential.token)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    func resolve(claim: FamilyState.Claim, approve: Bool) async {
        await run { try await self.api.resolveClaim(token: self.credential.token, claimID: claim.claimId, approve: approve) }
    }

    func revoke(_ device: FamilyState.Device) async {
        await run { try await self.api.revokeDevice(token: self.credential.token, deviceID: device.id) }
    }

    func forget(_ device: FamilyState.Device) async {
        await run { try await self.api.forgetDevice(token: self.credential.token, deviceID: device.id) }
    }

    func registerThisDeviceAsDisplay(name: String) async -> DisplayCredential? {
        do {
            let result = try await api.registerOwnDisplay(token: credential.token, deviceName: name)
            await refreshNow()
            return DisplayCredential(familyID: credential.familyID, deviceID: result.deviceID, token: result.token,
                                     familyName: credential.familyName, deviceName: name)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        actionError = nil
        do {
            try await body()
            await refreshNow()
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Export, delete, sign out

    struct ExportFile: Encodable {
        var format = "here-now-export/1"
        var exportedAt: Date
        var familyName: String
        var publishedVersion: Int
        var published: FamilySnapshot?
        var unpublishedDraft: FamilySnapshot?
        /// Photos and recordings, base64-encoded, keyed by SHA-256. Access credentials are never included.
        var assets: [String: String]
    }

    func exportFile() throws -> URL {
        var shas = Set(publishedSnapshot?.referencedAssets ?? [])
        shas.formUnion(draft?.snapshot.referencedAssets ?? [])
        var encoded: [String: String] = [:]
        for sha in shas { if let data = assets.data(for: sha) { encoded[sha] = data.base64EncodedString() } }
        let file = ExportFile(exportedAt: Date(), familyName: credential.familyName, publishedVersion: currentVersion,
                              published: publishedSnapshot, unpublishedDraft: draft?.snapshot, assets: encoded)
        let encoder = JSONEncoder.hereNow
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("此刻锚点导出-\(Date().formatted(in: .current, "yyyyMMdd-HHmm")).json")
        try encoder.encode(file).write(to: url, options: .atomic)
        return url
    }

    func deleteFamily() async throws -> DeletionStatus {
        stop()
        return try await api.deleteFamily(token: credential.token)
    }

    func deletionStatus() async throws -> DeletionStatus {
        try await api.deletionStatus(token: credential.token)
    }

    func signOutThisDevice() async -> Bool {
        do {
            try await api.revokeDevice(token: credential.token, deviceID: credential.deviceID)
            signOutLocally(reason: "已退出这台设备的管理权")
            return true
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription
            return false
        }
    }

    func signOutLocally(reason: String) {
        stop()
        assets.wipe()
        try? FileManager.default.removeItem(at: stateURL)
        Keychain.delete("caregiver")
        family = nil
        draft = nil
        outbox = nil
        onSignedOut?(reason)
    }

    private func persist() {
        try? LocalFiles.write(CaregiverLocalState(family: family, draft: draft, outbox: outbox, lastFetchAt: lastFetchAt), to: stateURL)
    }
}
