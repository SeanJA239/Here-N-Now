import CryptoKit
import Foundation
import Security

struct CaregiverCredential: Codable, Equatable {
    var familyID: String
    var deviceID: String
    var token: String
    var familyName: String
}

struct DisplayCredential: Codable, Equatable {
    var familyID: String
    var deviceID: String
    var token: String
    var familyName: String
    var deviceName: String
}

/// Credentials live in the Keychain and never go into exports.
enum Keychain {
    private static let service = "app.herenow.credentials"

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

enum Installation {
    /// Keychain items survive app deletion; a fresh install must not inherit an old family.
    static func prepare() {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") || !defaults.bool(forKey: "installed") {
            Keychain.deleteAll()
            try? FileManager.default.removeItem(at: LocalFiles.root)
            defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            defaults.set(true, forKey: "installed")
        }
    }

    static var id: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "installationID") { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: "installationID")
        return value
    }
}

enum LocalFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HereNow", isDirectory: true)
    }

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.hereNow.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.hereNow.decode(type, from: data)
    }

    /// Space the system will give us for important data; nil when it cannot be determined.
    static var availableBytes: Int64? {
        let values = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func hasRoom(for bytes: Int) -> Bool {
        guard let available = availableBytes else { return true }
        return available > Int64(bytes) + 50_000_000
    }
}

/// Content-addressed file store; the name of each file is the SHA-256 of its bytes.
struct AssetStore {
    let directory: URL

    init(name: String) { directory = LocalFiles.directory(name) }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func url(for sha: String) -> URL { directory.appendingPathComponent(sha) }

    func contains(_ sha: String) -> Bool { FileManager.default.fileExists(atPath: url(for: sha).path) }

    func data(for sha: String) -> Data? { try? Data(contentsOf: url(for: sha)) }

    @discardableResult
    func store(_ data: Data) throws -> String {
        guard LocalFiles.hasRoom(for: data.count) else { throw SyncError.storageFull }
        let sha = Self.sha256(data)
        if !contains(sha) { try data.write(to: url(for: sha), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        return sha
    }

    var all: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    func removeAll(except keep: Set<String>) {
        for sha in all where !keep.contains(sha) { try? FileManager.default.removeItem(at: url(for: sha)) }
    }

    func wipe() { try? FileManager.default.removeItem(at: directory) }
}
