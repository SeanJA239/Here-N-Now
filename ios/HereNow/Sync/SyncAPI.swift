import Foundation
import HereNowCore

// The app talks to sync only through these two protocols, so the self-hosted HTTP service can be replaced
// (for example by CloudKit once an Apple Developer team and entitlements exist) without touching the UI or rules.

protocol CaregiverSyncing: Sendable {
    func createFamily(familyName: String, installationID: String, deviceName: String) async throws -> NewCaregiverSession
    func recover(recoveryKey: String, installationID: String, deviceName: String) async throws -> NewCaregiverSession
    func familyState(token: String, waitRev: Int?) async throws -> FamilyState
    func uploadAsset(token: String, sha256: String, data: Data, mime: String) async throws
    func publish(token: String, baseVersion: Int, publishID: String, snapshot: FamilySnapshot) async throws -> PublishOutcome
    func setControls(token: String, controls: DeviceControls) async throws
    /// Starts (or with nil stops) a comfort item on the patient devices.
    func setComfort(token: String, itemID: String?) async throws
    func createPairingCode(token: String, role: DeviceRole) async throws -> PairingCode
    func resolveProposal(token: String, id: String, accept: Bool) async throws
    func playLog(token: String) async throws -> PlayLogResponse
    func clearPlayLog(token: String) async throws
    func downloadAsset(token: String, sha256: String) async throws -> Data
    func resolveClaim(token: String, claimID: String, approve: Bool) async throws
    func registerOwnDisplay(token: String, deviceName: String) async throws -> (deviceID: String, token: String)
    func revokeDevice(token: String, deviceID: String) async throws
    func forgetDevice(token: String, deviceID: String) async throws
    func deleteFamily(token: String) async throws -> DeletionStatus
    func deletionStatus(token: String) async throws -> DeletionStatus
}

protocol DisplaySyncing: Sendable {
    func previewPairing(code: String) async throws -> PairingPreview
    func claimPairing(code: String, installationID: String, deviceName: String, claimSecret: String) async throws -> PairingClaim
    func claimStatus(claimID: String, claimSecret: String) async throws -> ClaimStatus
    func sync(token: String, knownRev: Int?, knownVersion: Int, wait: Int) async throws -> DisplaySyncResponse
    func downloadAsset(token: String, sha256: String) async throws -> Data
    func sendReceipt(token: String, appliedVersion: Int, appliedControlsRev: Int, report: DeviceReport) async throws
    func confirmWipe(token: String) async throws
    func appendPlayLog(token: String, entries: [PlayLogEntry], coverage: [CoverageSpan]) async throws
}

/// Family members who can suggest recordings, photos, and plans, but never publish or read the family's content.
protocol ContributorSyncing: Sendable {
    func contributorState(token: String) async throws -> ContributorState
    func uploadAsset(token: String, sha256: String, data: Data, mime: String) async throws
    func submitProposal(token: String, kind: Proposal.Kind, payload: ProposalPayload, assetRefs: [String]) async throws
}

enum DeviceRole: String, Codable, Sendable { case caregiver, display, contributor }

struct ProposalPayload: Codable, Equatable, Sendable {
    var speakerLabel: String?
    var note: String?
    var personName: String?
    var line: String?
    var start: Date?
}

struct Proposal: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case recording, photo, event }
    var id: String
    var deviceName: String
    var kind: Kind
    var payload: ProposalPayload
    var assetRefs: [String]
    var createdAt: Double
    var state: String
}

struct ContributorState: Decodable, Sendable {
    var familyName: String
    var deviceName: String
    var proposals: [Proposal]
}

struct PlayLogResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable { var deviceId: String; var at: Date; var kind: String; var trigger: String; var source: String }
    struct Span: Decodable, Sendable { var deviceId: String; var start: Date; var end: Date }
    var entries: [Entry]
    var coverage: [Span]
}

struct NewCaregiverSession: Decodable, Sendable {
    var familyId: String
    var deviceId: String
    var token: String
    var recoveryKey: String
}

struct FamilyState: Codable, Equatable, Sendable {
    struct Family: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var createdAt: Double
    }

    struct Device: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var role: String
        var name: String
        var createdAt: Double
        var revokedAt: Double?
        var wipeState: String
        var lastSeenAt: Double?
        var appliedVersion: Int?
        var appliedControlsRev: Int?
        var appliedAt: Double?
        var leaseExpiresAt: Double?
        var report: DeviceReport?

        var isDisplay: Bool { role == "display" }
        var isActive: Bool { revokedAt == nil }
    }

    struct Claim: Codable, Equatable, Sendable, Identifiable {
        var claimId: String
        var deviceName: String
        var claimedAt: Double
        var role: DeviceRole?
        var id: String { claimId }
    }

    var family: Family
    var rev: Int
    var currentVersion: Int
    var publishedAt: Double?
    var publishedBy: String?
    var snapshot: FamilySnapshot?
    var controls: DeviceControls
    var controlsRev: Int
    var selfDeviceId: String
    var devices: [Device]
    var pendingClaims: [Claim]
    var proposals: [Proposal]?
    var serverTime: Double

    var activeDisplays: [Device] { devices.filter { $0.isDisplay && $0.isActive } }
}

/// What the patient device reports about itself after applying content. Only facts the device can observe.
struct DeviceReport: Codable, Equatable, Sendable {
    var appVersion: String
    var timeZoneID: String
    var deviceTime: Double
    var clockSuspect: Bool
    var clockDetail: String?
    var audioRoute: String
    var speechAvailable: Bool
    var missingAssets: [String]
    var brokenAssets: [String]
    var storageLow: Bool
    var lastProblem: String?
    var textWidthWithPhoto: Double
    var textWidthWithoutPhoto: Double
    var leaseExpiresAt: Double?

    /// Clock readings and lease renewals change on every sync; only other facts are worth a new receipt.
    func sameFacts(as other: DeviceReport?) -> Bool {
        guard var other else { return false }
        other.deviceTime = deviceTime
        other.leaseExpiresAt = leaseExpiresAt
        return other == self
    }
}

enum PublishOutcome: Sendable {
    case published(version: Int)
    case conflict(currentVersion: Int, snapshot: FamilySnapshot?)
    case missingAssets([String])
}

struct PairingCode: Decodable, Sendable {
    var code: String
    var expiresAt: Double
    var role: DeviceRole?
}

struct PairingPreview: Decodable, Sendable {
    var familyName: String
    var initiatedBy: String
    var expiresAt: Double
    var role: DeviceRole?
}

struct PairingClaim: Decodable, Sendable {
    var claimId: String
    var familyName: String
    var initiatedBy: String
    var role: DeviceRole?
}

struct ClaimStatus: Decodable, Sendable {
    var state: String
    var familyId: String?
    var familyName: String?
    var deviceId: String?
    var deviceName: String?
    var role: DeviceRole?
    var token: String?
}

struct DisplaySyncResponse: Decodable, Sendable {
    var status: String
    var rev: Int?
    var familyId: String?
    var familyName: String?
    var deviceId: String?
    var deviceName: String?
    var version: Int?
    var snapshot: FamilySnapshot?
    var controls: DeviceControls?
    var controlsRev: Int?
    var leaseExpiresAt: Double?
    var serverTime: Double
}

struct DeletionStatus: Decodable, Sendable {
    struct Device: Decodable, Sendable, Identifiable {
        var id: String
        var name: String
        var role: String
        var wipeState: String
        var lastSeenAt: Double?
    }

    var deletedAt: Double
    var devices: [Device]
}

enum SyncError: Error, Equatable, LocalizedError {
    case offline(String)
    case server(status: Int, code: String)
    case storageFull
    case invalidResponse

    var code: String? {
        if case let .server(_, code) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case let .offline(detail): "无法连接同步服务（\(detail)）"
        case .storageFull: "这台设备存储空间不足"
        case .invalidResponse: "同步服务返回了无法识别的内容"
        case let .server(_, code): SyncError.message(for: code)
        }
    }

    static func message(for code: String) -> String {
        switch code {
        case "pairing_code_invalid": "配对码不正确，请核对照护者手机上显示的 8 位码"
        case "pairing_code_expired": "配对码已过期，请在照护者手机上重新生成"
        case "pairing_code_consumed": "这个配对码已被使用，请重新生成"
        case "too_many_attempts": "尝试次数过多，请 10 分钟后再试"
        case "recovery_key_invalid": "恢复码不正确或已失效"
        case "device_revoked": "这台设备的访问已被撤销"
        case "family_deleted": "家庭资料已被删除"
        case "last_caregiver": "这是唯一的管理设备，不能直接退出"
        case "claim_expired": "配对请求已过期，请重新生成配对码"
        case "snapshot_too_large": "内容过大，无法发布"
        case "contributor_only", "caregiver_only", "display_only": "这台设备没有这项权限"
        default: "同步服务拒绝了请求（\(code)）"
        }
    }
}

extension JSONEncoder {
    static let hereNow: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let hereNow: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
