import CryptoKit
import Foundation
import HereNowCore
import LocalAuthentication
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    private(set) var caregiver: CaregiverStore?
    private(set) var display: DisplayEngine?
    private(set) var contributor: ContributorStore?
    /// The caregiver passed the PIN or device check on the patient device.
    var managementUnlocked = false
    /// After a remote wipe the device shows a neutral time page instead of a setup form.
    private(set) var wipedNotice: String?
    var signOutNotice: String?

    let api = HTTPSyncService.fromBundle()

    init() {
        Installation.prepare()
        if let credential = Keychain.load(CaregiverCredential.self, key: "caregiver") { attachCaregiver(credential) }
        if let credential = Keychain.load(DisplayCredential.self, key: "display") { attachDisplay(credential) }
        if let credential = Keychain.load(ContributorCredential.self, key: "contributor") { attachContributor(credential) }
        wipedNotice = UserDefaults.standard.string(forKey: "wipedNotice")
        if let token = Keychain.load(String.self, key: "wipeConfirmPending") {
            Task { [api] in await DisplayEngine.confirmWipe(token: token, api: api) }
        }
    }

    func attachCaregiver(_ credential: CaregiverCredential, initialDraft: FamilySnapshot? = nil) {
        Keychain.save(credential, key: "caregiver")
        let store = CaregiverStore(credential: credential, api: api, initialDraft: initialDraft)
        store.onSignedOut = { [weak self] reason in
            self?.caregiver = nil
            self?.signOutNotice = reason
        }
        caregiver = store
        store.start()
    }

    func attachDisplay(_ credential: DisplayCredential) {
        Keychain.save(credential, key: "display")
        let engine = DisplayEngine(credential: credential, api: api)
        engine.onWiped = { [weak self] in
            guard let self else { return }
            self.display = nil
            self.managementUnlocked = false
            self.wipedNotice = "此设备已解除配对，家庭资料已从本机清除"
            UserDefaults.standard.set(self.wipedNotice, forKey: "wipedNotice")
        }
        display = engine
        clearWipedNotice()
        engine.start()
    }

    func attachContributor(_ credential: ContributorCredential) {
        Keychain.save(credential, key: "contributor")
        let store = ContributorStore(credential: credential, api: api)
        store.onRevoked = { [weak self] in
            self?.contributor = nil
            self?.signOutNotice = "这台手机已不再是「\(credential.familyName)」的提交者"
        }
        contributor = store
    }

    func clearWipedNotice() {
        wipedNotice = nil
        UserDefaults.standard.removeObject(forKey: "wipedNotice")
    }

    func lockToPatientMode() {
        managementUnlocked = false
        display?.tick()
    }

    /// Unpairs this patient device from here: wipes local data and tells the service.
    func unpairDisplay() async {
        await display?.wipe()
    }

    static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "患者的 iPad" : "照护者的 iPhone"
    }
}

/// Management PIN on the patient device. Failures add delays but never clear content.
enum ManagementPIN {
    private struct Stored: Codable { var salt: String; var hash: String; var failures: Int; var lockedUntil: Date? }

    static var isSet: Bool { Keychain.load(Stored.self, key: "pin") != nil }

    static func set(_ pin: String) {
        let salt = UUID().uuidString
        Keychain.save(Stored(salt: salt, hash: hash(pin, salt: salt), failures: 0, lockedUntil: nil), key: "pin")
    }

    enum Result: Equatable { case ok, wrong(remainingBeforeDelay: Int), locked(until: Date), notSet }

    static func check(_ pin: String, now: Date = Date()) -> Result {
        guard var stored = Keychain.load(Stored.self, key: "pin") else { return .notSet }
        if let until = stored.lockedUntil, until > now { return .locked(until: until) }
        if hash(pin, salt: stored.salt) == stored.hash {
            stored.failures = 0
            stored.lockedUntil = nil
            Keychain.save(stored, key: "pin")
            return .ok
        }
        stored.failures += 1
        if stored.failures >= 5 {
            let minutes = pow(2, Double(min(stored.failures - 5, 6)))
            stored.lockedUntil = now.addingTimeInterval(minutes * 60)
            Keychain.save(stored, key: "pin")
            return .locked(until: stored.lockedUntil!)
        }
        Keychain.save(stored, key: "pin")
        return .wrong(remainingBeforeDelay: 5 - stored.failures)
    }

    /// Recovery path when the PIN is forgotten: the device owner's passcode or biometrics.
    static func verifyWithDeviceOwner() async -> (Bool, String?) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (false, "这台设备没有设置锁屏密码，无法用设备密码验证。可在照护者手机上撤销此设备后重新配对。")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "进入此刻锚点的照护者设置")
            return (ok, nil)
        } catch {
            return (false, nil)
        }
    }

    private static func hash(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
