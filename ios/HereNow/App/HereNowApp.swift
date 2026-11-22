import Combine
import HereNowCore
import SwiftUI

@main
struct HereNowApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var askingPIN = false

    var body: some View {
        Group {
            if let display = model.display, !model.managementUnlocked {
                PatientScreen(engine: display) { askingPIN = true }
                    .fullScreenCover(isPresented: $askingPIN) {
                        PINGateView {
                            askingPIN = false
                            model.managementUnlocked = true
                        } onCancel: {
                            askingPIN = false
                        }
                    }
            } else if let display = model.display {
                if let caregiver = model.caregiver {
                    CaregiverRootView(store: caregiver, ownDisplay: display)
                } else {
                    DisplayManagementView(engine: display)
                }
            } else if let caregiver = model.caregiver {
                CaregiverRootView(store: caregiver, ownDisplay: nil)
            } else if model.wipedNotice != nil {
                WipedNeutralView()
            } else {
                WelcomeView()
            }
        }
        .alert("已退出", isPresented: Binding(get: { model.signOutNotice != nil }, set: { if !$0 { model.signOutNotice = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.signOutNotice ?? "")
        }
    }
}

/// After a remote wipe: only the time, plus a quiet way for a caregiver to set the device up again.
struct WipedNeutralView: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let moment = MomentResolver.resolve(.init(snapshot: nil, now: now))
        PatientMomentView(moment: moment, isPlaying: false, photo: { _ in nil }) {}
            .overlay(alignment: .bottomTrailing) {
                Button("设置此设备") { model.clearWipedNotice() }
                    .font(.footnote)
                    .foregroundStyle(Color(hex: PatientPalette.of(moment.palette).secondaryTimeText).opacity(0.8))
                    .padding(24)
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onReceive(timer) { now = $0 }
    }
}

struct WelcomeView: View {
    @State private var route: Route?

    enum Route: Identifiable {
        case createFamily, pairDisplay, recover
        var id: Self { self }
    }

    var body: some View {
        ZStack {
            Theme.wallpaper
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("此刻锚点").font(.largeTitle.bold())
                        Text("用照护者确认过的少量信息，在熟悉的屏幕上温和地提示现在和接下来。")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                    choice("person.crop.circle.badge.plus", "我是照护者", "创建家庭，在这台设备上管理内容", .createFamily)
                    choice("ipad.landscape", "这台设备给患者看", "输入照护者手机上的配对码", .pairDisplay)
                    choice("key.fill", "用恢复码找回管理权", "换了手机或原设备丢失时使用", .recover)
                    Text("本应用不提供医疗、用药或安全监测功能，不能代替照护者的陪伴与判断。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .fullScreenCover(item: $route) { route in
            switch route {
            case .createFamily: CaregiverOnboardingView { self.route = nil }
            case .pairDisplay: DisplayPairingView { self.route = nil }
            case .recover: RecoverView { self.route = nil }
            }
        }
    }

    private func choice(_ icon: String, _ title: String, _ detail: String, _ target: Route) -> some View {
        Button { route = target } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.accentFill))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("welcome.\(target)")
    }
}

struct RecoverView: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void
    @State private var key = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                } header: {
                    Text("恢复码")
                } footer: {
                    Text("恢复后，原来的管理设备会失去管理权限，旧恢复码失效并生成新的恢复码；患者设备和已发布内容不受影响。")
                }
                if let error { Text(error).foregroundStyle(Theme.bad) }
                Button(working ? "正在验证…" : "找回管理权") { Task { await recover() } }
                    .disabled(key.filter { $0.isLetter || $0.isNumber }.count < 20 || working)
            }
            .navigationTitle("找回管理权")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: onClose) } }
        }
    }

    private func recover() async {
        working = true
        defer { working = false }
        do {
            let session = try await model.api.recover(recoveryKey: key, installationID: Installation.id, deviceName: AppModel.deviceName)
            PendingRecoveryKey.save(session.recoveryKey)
            onClose()
            model.attachCaregiver(CaregiverCredential(familyID: session.familyId, deviceID: session.deviceId, token: session.token, familyName: ""))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
        }
    }
}

/// A new recovery key stays in the Keychain until the caregiver confirms they saved it, so a crash cannot lose it.
enum PendingRecoveryKey {
    static func save(_ key: String) { Keychain.save(key, key: "recoveryPending") }
    static var value: String? { Keychain.load(String.self, key: "recoveryPending") }
    static func confirmSaved() { Keychain.delete("recoveryPending") }
}

struct RecoveryKeyBox: View {
    var key: String

    var body: some View {
        Text(key)
            .font(.title2.monospaced().weight(.semibold))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemFill)))
            .accessibilityIdentifier("recoveryKey")
    }
}

/// Six-digit management PIN with large keys. Wrong entries never touch the patient's content.
struct PINGateView: View {
    var onSuccess: () -> Void
    var onCancel: () -> Void
    @State private var digits = ""
    @State private var message: String?

    var body: some View {
        PINPad(title: "照护者验证", subtitle: "输入管理 PIN", digits: $digits, message: message) {
            switch ManagementPIN.check(digits) {
            case .ok: onSuccess()
            case let .wrong(remaining): message = "PIN 不正确，还可再试 \(remaining) 次后需要等待"
            case let .locked(until): message = "尝试次数过多，请在 \(until.formatted(in: .current, "HH:mm")) 后再试"
            case .notSet: onSuccess()
            }
            digits = ""
        } footer: {
            VStack(spacing: 12) {
                Button("忘记 PIN？用设备密码验证") {
                    Task {
                        let (ok, problem) = await ManagementPIN.verifyWithDeviceOwner()
                        if ok { onSuccess() } else if let problem { message = problem }
                    }
                }
                Button("返回", action: onCancel).accessibilityIdentifier("pin.cancel")
            }
        }
    }
}

struct PINSetupView: View {
    var onDone: () -> Void
    @State private var first: String?
    @State private var digits = ""
    @State private var message: String?

    var body: some View {
        PINPad(title: "设置管理 PIN", subtitle: first == nil ? "请设置 6 位数字，只告诉照护者" : "再输入一次确认",
               digits: $digits, message: message) {
            if let first {
                if first == digits {
                    ManagementPIN.set(digits)
                    onDone()
                } else {
                    message = "两次输入不一致，请重新设置"
                    self.first = nil
                }
            } else {
                first = digits
                message = nil
            }
            digits = ""
        } footer: {
            Text("在患者屏幕右上角长按两秒，输入 PIN 才能进入设置。停止声音不需要 PIN。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

struct PINPad<Footer: View>: View {
    var title: String
    var subtitle: String
    @Binding var digits: String
    var message: String?
    var onComplete: () -> Void
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ZStack {
            Theme.wallpaper
            VStack(spacing: 24) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ForEach(0..<6, id: \.self) { index in
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.6), lineWidth: 2)
                            .background(Circle().fill(index < digits.count ? Color.primary : .clear))
                            .frame(width: 22, height: 22)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("已输入 \(digits.count) 位")
                if let message {
                    Text(message).font(.callout).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 20), count: 3), spacing: 18) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 88, height: 88)
                        } else {
                            Button {
                                if key == "⌫" { if !digits.isEmpty { digits.removeLast() } } else if digits.count < 6 {
                                    digits.append(key)
                                    if digits.count == 6 { onComplete() }
                                }
                            } label: {
                                Text(key)
                                    .font(.title.weight(.medium))
                                    .frame(width: 88, height: 88)
                                    .background(Circle().fill(.background.opacity(0.9)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(key == "⌫" ? "删除" : key)
                            .accessibilityIdentifier("pin.\(key)")
                        }
                    }
                }
                footer()
            }
            .padding(32)
        }
    }
}
