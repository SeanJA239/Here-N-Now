import Foundation
import HereNowCore

/// Self-hosted sync service client (see server/). Needs no Apple Developer entitlements.
final class HTTPSyncService: CaregiverSyncing, DisplaySyncing, @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    static func fromBundle() -> HTTPSyncService {
        let env = ProcessInfo.processInfo.environment["HERE_NOW_SERVER_URL"]
        let plist = Bundle.main.object(forInfoDictionaryKey: "HereNowServerURL") as? String
        return HTTPSyncService(baseURL: URL(string: env ?? plist ?? "http://127.0.0.1:8787")!)
    }

    private struct ErrorBody: Decodable {
        var error: String
        var currentVersion: Int?
        var snapshot: FamilySnapshot?
        var missingAssets: [String]?
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], token: String? = nil,
                         body: Data? = nil, contentType: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
            return (data, http)
        } catch let error as URLError {
            throw SyncError.offline(error.code == .timedOut ? "超时" : error.localizedDescription)
        }
    }

    private func json<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                                  token: String? = nil, body: B) async throws -> T {
        try await send(method, path, query: query, token: token, payload: JSONEncoder.hereNow.encode(body))
    }

    private func json<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], token: String? = nil) async throws -> T {
        try await send(method, path, query: query, token: token, payload: nil)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String], token: String?, payload: Data?) async throws -> T {
        let (data, http) = try await request(method, path, query: query, token: token, body: payload)
        guard (200..<300).contains(http.statusCode) else { throw decodeError(data, status: http.statusCode) }
        do {
            return try JSONDecoder.hereNow.decode(T.self, from: data)
        } catch {
            throw SyncError.invalidResponse
        }
    }

    private func decodeError(_ data: Data, status: Int) -> SyncError {
        let code = (try? JSONDecoder.hereNow.decode(ErrorBody.self, from: data))?.error ?? "http_\(status)"
        return .server(status: status, code: code)
    }

    private struct Ignored: Decodable {}

    // MARK: Caregiver

    func createFamily(familyName: String, installationID: String, deviceName: String) async throws -> NewCaregiverSession {
        try await json("POST", "v1/families", body: ["familyName": familyName, "installationId": installationID, "deviceName": deviceName])
    }

    func recover(recoveryKey: String, installationID: String, deviceName: String) async throws -> NewCaregiverSession {
        try await json("POST", "v1/recover", body: ["recoveryKey": recoveryKey, "installationId": installationID, "deviceName": deviceName])
    }

    func familyState(token: String, waitRev: Int?) async throws -> FamilyState {
        var query: [String: String] = [:]
        if let waitRev { query = ["waitRev": String(waitRev), "wait": "25"] }
        return try await json("GET", "v1/family", query: query, token: token)
    }

    func uploadAsset(token: String, sha256: String, data: Data, mime: String) async throws {
        let (body, http) = try await request("PUT", "v1/family/assets/\(sha256)", token: token, body: data, contentType: mime)
        guard (200..<300).contains(http.statusCode) else { throw decodeError(body, status: http.statusCode) }
    }

    func publish(token: String, baseVersion: Int, publishID: String, snapshot: FamilySnapshot) async throws -> PublishOutcome {
        struct Body: Encodable { var baseVersion: Int; var publishId: String; var snapshot: FamilySnapshot }
        struct Result: Decodable { var version: Int }
        let payload = try JSONEncoder.hereNow.encode(Body(baseVersion: baseVersion, publishId: publishID, snapshot: snapshot))
        let (data, http) = try await request("POST", "v1/family/publish", token: token, body: payload)
        switch http.statusCode {
        case 200..<300:
            return .published(version: try JSONDecoder.hereNow.decode(Result.self, from: data).version)
        case 409:
            let body = try? JSONDecoder.hereNow.decode(ErrorBody.self, from: data)
            if body?.error == "version_conflict" {
                return .conflict(currentVersion: body?.currentVersion ?? 0, snapshot: body?.snapshot)
            }
            throw decodeError(data, status: 409)
        case 422:
            return .missingAssets((try? JSONDecoder.hereNow.decode(ErrorBody.self, from: data))?.missingAssets ?? [])
        default:
            throw decodeError(data, status: http.statusCode)
        }
    }

    func setControls(token: String, controls: DeviceControls) async throws {
        let _: Ignored = try await json("POST", "v1/family/controls", token: token, body: controls)
    }

    func createPairingCode(token: String) async throws -> PairingCode {
        try await json("POST", "v1/family/pairing-codes", token: token)
    }

    func resolveClaim(token: String, claimID: String, approve: Bool) async throws {
        let _: Ignored = try await json("POST", "v1/family/claims/\(claimID)/\(approve ? "approve" : "reject")", token: token)
    }

    func registerOwnDisplay(token: String, deviceName: String) async throws -> (deviceID: String, token: String) {
        struct Result: Decodable { var deviceId: String; var token: String }
        let result: Result = try await json("POST", "v1/family/own-display", token: token, body: ["deviceName": deviceName])
        return (result.deviceId, result.token)
    }

    func revokeDevice(token: String, deviceID: String) async throws {
        let _: Ignored = try await json("DELETE", "v1/family/devices/\(deviceID)", token: token)
    }

    func forgetDevice(token: String, deviceID: String) async throws {
        let _: Ignored = try await json("POST", "v1/family/devices/\(deviceID)/forget", token: token)
    }

    func deleteFamily(token: String) async throws -> DeletionStatus {
        try await json("DELETE", "v1/family", token: token)
    }

    func deletionStatus(token: String) async throws -> DeletionStatus {
        try await json("GET", "v1/family/deletion", token: token)
    }

    // MARK: Display

    func previewPairing(code: String) async throws -> PairingPreview {
        try await json("GET", "v1/pairing/preview", query: ["code": code])
    }

    func claimPairing(code: String, installationID: String, deviceName: String, claimSecret: String) async throws -> PairingClaim {
        try await json("POST", "v1/pairing/claim", body: [
            "code": code, "installationId": installationID, "deviceName": deviceName, "claimSecret": claimSecret,
        ])
    }

    func claimStatus(claimID: String, claimSecret: String) async throws -> ClaimStatus {
        try await json("GET", "v1/pairing/claims/\(claimID)", query: ["secret": claimSecret])
    }

    func sync(token: String, knownRev: Int?, knownVersion: Int, wait: Int) async throws -> DisplaySyncResponse {
        var query = ["knownVersion": String(knownVersion)]
        if let knownRev { query["knownRev"] = String(knownRev); query["wait"] = String(wait) }
        return try await json("GET", "v1/device/sync", query: query, token: token)
    }

    func downloadAsset(token: String, sha256: String) async throws -> Data {
        let (data, http) = try await request("GET", "v1/assets/\(sha256)", token: token)
        guard http.statusCode == 200 else { throw decodeError(data, status: http.statusCode) }
        return data
    }

    func sendReceipt(token: String, appliedVersion: Int, appliedControlsRev: Int, report: DeviceReport) async throws {
        struct Body: Encodable { var appliedVersion: Int; var appliedControlsRev: Int; var report: DeviceReport }
        let _: Ignored = try await json("POST", "v1/device/receipt", token: token,
                                        body: Body(appliedVersion: appliedVersion, appliedControlsRev: appliedControlsRev, report: report))
    }

    func confirmWipe(token: String) async throws {
        let _: Ignored = try await json("POST", "v1/device/wipe-confirm", token: token)
    }
}
