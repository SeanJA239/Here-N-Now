import HereNowCore
import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: CaregiverStore
    var ownDisplay: DisplayEngine?
    @State private var pairing = false
    @State private var invitingFamily = false
    @State private var revoking: FamilyState.Device?
    @State private var settingUpHere = false

    var body: some View {
        let family = store.family
        NavigationStack {
            List {
                if let claims = family?.pendingClaims, !claims.isEmpty {
                    Section("等待确认") {
                        ForEach(claims) { ClaimRow(store: store, claim: $0) }
                    }
                }
                Section {
                    ForEach(family?.devices.filter(\.isDisplay) ?? []) { device in
                        deviceRow(device, current: family?.currentVersion ?? 0)
                    }
                    Button { pairing = true } label: { Label("配对新的患者设备", systemImage: "plus.circle.fill") }
                        .accessibilityIdentifier("devices.pair")
                    if ownDisplay == nil {
                        Button { settingUpHere = true } label: { Label("在这台设备上展示", systemImage: "rectangle.inset.filled") }
                    }
                } header: {
                    Text("患者设备")
                } footer: {
                    Text("“已应用”来自设备回执，只能证明软件应用了该版本。最后联系时间之后的状态未知。")
                }
                if let ownDisplay {
                    DisplayStatusSections(engine: ownDisplay)
                }
                Section {
                    ForEach(family?.devices.filter { $0.role == "contributor" } ?? []) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.isActive ? "可以提交录音、照片和安排建议" : "已撤销").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.isActive {
                                Button("撤销", role: .destructive) { revoking = device }.buttonStyle(.borderless)
                            }
                        }
                    }
                    Button { invitingFamily = true } label: { Label("邀请家人提供录音或照片", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("devices.inviteFamily")
                } header: {
                    Text("家人")
                } footer: {
                    Text("家人只能提交建议，看不到家庭内容，也不能发布；你决定是否使用。")
                }
                Section("管理设备") {
                    ForEach(family?.devices.filter { $0.role == "caregiver" } ?? []) { device in
                        VStack(alignment: .leading) {
                            Text(device.name + (device.id == family?.selfDeviceId ? "（本机）" : ""))
                            Text(device.isActive ? "可以管理内容" : "管理权已撤销").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("设备")
            .refreshable { await store.refreshNow() }
            .sheet(isPresented: $pairing) { PairDeviceSheet(store: store) }
            .sheet(isPresented: $invitingFamily) { PairDeviceSheet(store: store, role: .contributor) }
            .fullScreenCover(isPresented: $settingUpHere) {
                PINSetupView {
                    settingUpHere = false
                    Task {
                        if let credential = await store.registerThisDeviceAsDisplay(name: AppModel.deviceName) {
                            model.managementUnlocked = true
                            model.attachDisplay(credential)
                        }
                    }
                }
            }
            .confirmationDialog("撤销这台设备？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                                titleVisibility: .visible, presenting: revoking) { device in
                Button("撤销「\(device.name)」", role: .destructive) { Task { await store.revoke(device) } }
            } message: { _ in
                Text("撤销后它不能再同步。设备联网时会自动清除家庭资料；如果它一直离线，已下载的内容无法远程擦除，需要拿到设备手动解除配对。")
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: FamilyState.Device, current: Int) -> some View {
        if device.isActive {
            VStack(alignment: .leading, spacing: 8) {
                DeviceStatusTile(device: device, currentVersion: current, controlsRev: store.family?.controlsRev ?? 0, zone: store.patientTimeZone, framed: false)
                if let lease = device.leaseExpiresAt {
                    Text("离线展示授权到 \(lease.serverDate.formatted(in: store.patientTimeZone))；到期仍未联网，设备只显示时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("撤销访问", role: .destructive) { revoking = device }
                    .buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.headline)
                Text(device.wipeState == "confirmed" ? "访问已撤销 · 设备数据已清除" : "访问已撤销 · 等待设备清除数据")
                    .foregroundStyle(device.wipeState == "confirmed" ? Theme.ok : Theme.warn)
                if device.wipeState != "confirmed" {
                    Text("设备联网后会自动清除。若设备一直离线，请拿到设备在其设置中解除配对。").font(.footnote).foregroundStyle(.secondary)
                }
                Button("从列表移除") { Task { await store.forget(device) } }
            }
        }
    }
}

struct ClaimRow: View {
    @Bindable var store: CaregiverStore
    var claim: FamilyState.Claim

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(claim.role == .contributor ? "家人「\(claim.deviceName)」请求成为提交者" : "「\(claim.deviceName)」请求加入「\(store.credential.familyName)」").font(.headline)
                .accessibilityIdentifier("claim.title")
            Text("请确认这是你正在设置的设备。").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("批准") { Task { await store.resolve(claim: claim, approve: true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("claim.approve")
                Button("拒绝", role: .destructive) { Task { await store.resolve(claim: claim, approve: false) } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

struct PairDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    var role: DeviceRole = .display
    @State private var code: PairingCode?
    @State private var startedDevices: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let code {
                        Text(code.code)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("pairing.code")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = Int(code.expiresAt.serverDate.timeIntervalSince(context.date))
                            Text(remaining > 0 ? "\(remaining / 60) 分 \(remaining % 60) 秒后失效，只能使用一次" : "已失效，请重新生成")
                                .foregroundStyle(remaining > 0 ? Color.secondary : Theme.bad)
                        }
                        Button("重新生成") { Task { self.code = await store.createPairingCode(role: role) } }
                    } else {
                        ProgressView()
                    }
                    if let error = store.actionError { Text(error).foregroundStyle(Theme.bad) }
                } footer: {
                    Text(role == .contributor ? "请家人在自己的手机上打开此刻锚点，选择“我是家人：提供录音或照片”，输入这个邀请码。" : "在患者设备上打开此刻锚点，选择“这台设备给患者看”，输入这个配对码。")
                }
                if let claims = store.family?.pendingClaims, !claims.isEmpty {
                    Section("等待确认") { ForEach(claims) { ClaimRow(store: store, claim: $0) } }
                }
                if let newDevice = store.family?.devices.first(where: { $0.isActive && $0.role == role.rawValue && !startedDevices.contains($0.id) }) {
                    Section {
                        Label("「\(newDevice.name)」已配对", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        Button("完成") { dismiss() }.accessibilityIdentifier("pairing.done")
                    }
                }
            }
            .navigationTitle(role == .contributor ? "邀请家人" : "配对患者设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task {
                startedDevices = Set(store.family?.devices.map(\.id) ?? [])
                code = await store.createPairingCode(role: role)
            }
        }
    }
}
