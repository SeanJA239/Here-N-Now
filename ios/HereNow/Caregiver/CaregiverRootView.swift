import Combine
import HereNowCore
import SwiftUI

struct CaregiverRootView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: CaregiverStore
    var ownDisplay: DisplayEngine?
    @State private var tab = 0
    @State private var recoveryKey = PendingRecoveryKey.value

    var body: some View {
        TabView(selection: $tab) {
            DashboardView(store: store, ownDisplay: ownDisplay, openTab: { tab = $0 })
                .tabItem { Label("此刻", systemImage: "house.fill") }
                .tag(0)
            ContentEditorView(store: store)
                .tabItem { Label("内容", systemImage: "square.and.pencil") }
                .tag(1)
            DevicesView(store: store, ownDisplay: ownDisplay)
                .tabItem { Label("设备", systemImage: "ipad.and.iphone") }
                .tag(2)
            FamilySettingsView(store: store)
                .tabItem { Label("家庭", systemImage: "person.2.fill") }
                .tag(3)
        }
        .fullScreenCover(isPresented: Binding(get: { recoveryKey != nil }, set: { if !$0 { recoveryKey = nil } })) {
            RecoveryKeySheet(key: recoveryKey ?? "") {
                PendingRecoveryKey.confirmSaved()
                recoveryKey = nil
            }
        }
    }
}

struct RecoveryKeySheet: View {
    var key: String
    var onDone: () -> Void
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    RecoveryKeyBox(key: key)
                } footer: {
                    Text("换手机或这台手机丢失时，用恢复码找回管理权。恢复码只显示这一次，请抄在纸上或存入密码管理器，不要发给他人。")
                }
                Section {
                    Toggle("我已妥善保存恢复码", isOn: $saved).accessibilityIdentifier("recovery.saved")
                }
                Button("继续", action: onDone).disabled(!saved).accessibilityIdentifier("recovery.continue")
            }
            .navigationTitle("保存恢复码")
        }
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: CaregiverStore
    var ownDisplay: DisplayEngine?
    var openTab: (Int) -> Void
    @State private var now = Date()
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !store.online, let problem = store.connectionProblem {
                        StatusTile(icon: "wifi.slash", tint: Theme.bad, title: "未连接同步服务", value: problem,
                                   detail: store.lastFetchAt.map { "以下状态更新于 \($0.relativeChinese)，此后的情况未知" })
                    }
                    if let notes = store.draft?.mergeNotes, !notes.isEmpty {
                        StatusTile(icon: "arrow.triangle.merge", tint: Theme.warn, title: "需要重新确认", value: notes[0],
                                   detail: notes.dropFirst().joined(separator: "\n"))
                            .onTapGesture { openTab(1) }
                    }
                    SetupChecklist(store: store, openTab: openTab)
                    ProposalsCard(store: store)
                    deliveryTile
                    previewCard
                    ComfortControlCard(store: store)
                    ControlsCard(store: store)
                    devicesSummary
                    upcoming
                }
                .padding(16)
            }
            .background(Theme.wallpaper)
            .navigationTitle(store.credential.familyName.isEmpty ? "此刻" : store.credential.familyName)
            .toolbar {
                if ownDisplay != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("进入患者屏幕") { model.lockToPatientMode() }
                            .accessibilityIdentifier("caregiver.enterPatientMode")
                    }
                }
            }
            .refreshable { await store.refreshNow() }
            .onReceive(timer) { now = $0 }
        }
    }

    private var header: some View {
        let snapshot = store.publishedSnapshot ?? store.workingSnapshot
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(snapshot.profile.callName) 当地时间 \(now.formatted(in: snapshot.timeZone, "M月d日 HH:mm"))（\(snapshot.profile.timeZoneID)）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var deliveryTile: some View {
        switch store.deliveryStatus {
        case .nothingPublished:
            StatusTile(icon: "tray", tint: .gray, title: "发布状态", value: "还没有发布内容", detail: "患者设备目前只显示时间。")
        case let .savedLocally(error):
            VStack(alignment: .leading, spacing: 8) {
                StatusTile(icon: "clock.arrow.circlepath", tint: Theme.warn, title: "发布状态", value: "本机已保存 · 等待传送",
                           detail: error.map { "原因：\($0)" } ?? "正在发送到同步服务")
                Button("重试发送") { Task { await store.flushOutbox() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dashboard.retry")
            }
        case let .awaitingDevice(version, devices):
            StatusTile(icon: "paperplane", tint: Theme.warn, title: "发布状态", value: "第 \(version) 版已传送 · 等待设备应用",
                       detail: "\(devices.joined(separator: "、")) 还在显示旧版本。若这次变更影响今天的照护，请直接联系现场的人。")
        case let .applied(version):
            StatusTile(icon: "checkmark.circle.fill", tint: Theme.ok, title: "发布状态", value: "第 \(version) 版 · 设备已接收并应用",
                       detail: "这只说明设备软件已应用，不代表患者已看到或已知道。")
        case let .noDisplay(version):
            StatusTile(icon: "ipad.badge.exclamationmark", tint: .gray, title: "发布状态", value: "第 \(version) 版已发布",
                       detail: "还没有连接患者设备。")
        }
    }

    private var previewCard: some View {
        let snapshot = store.publishedSnapshot
        let moment = MomentResolver.resolve(MomentInput(
            snapshot: snapshot, controls: store.family?.controls ?? .init(), now: now,
            availableAssets: store.assets.all, speechAvailable: AudioEnvironment.speechAvailable(language: snapshot?.profile.languageCode ?? "zh-CN")))
        return VStack(alignment: .leading, spacing: 8) {
            Text("患者屏幕现在应显示").font(.headline)
            PatientPreview(moment: moment, assets: store.assets)
            Text("按已发布的最新版本计算。草稿不会出现在患者屏幕上。").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(0.92)))
    }

    @ViewBuilder
    private var devicesSummary: some View {
        if let family = store.family {
            ForEach(family.activeDisplays) { device in
                DeviceStatusTile(device: device, currentVersion: family.currentVersion, controlsRev: family.controlsRev, zone: store.patientTimeZone)
                    .onTapGesture { openTab(2) }
            }
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        let events = (store.publishedSnapshot?.events ?? []).filter { !$0.isCancelled && $0.showUntil > now }.prefix(3)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("接下来已发布的安排").font(.headline)
                ForEach(Array(events)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.line).font(.body.weight(.semibold))
                        Text("\(event.start.formatted(in: store.patientTimeZone)) · 显示至 \(event.showUntil.formatted(in: store.patientTimeZone, "HH:mm"))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(0.92)))
        }
    }
}

/// Patient screen rendered at iPad size and scaled down, so the preview matches the real layout.
struct PatientPreview: View {
    var moment: Moment
    var assets: AssetStore
    var canvas = CGSize(width: 1180, height: 820)

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / canvas.width
            PatientMomentView(moment: moment, isPlaying: false,
                              photo: { ImageCache.image(at: assets.url(for: $0), key: $0) }, onToggle: {})
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("患者屏幕预览：\(moment.segmentName)，\(moment.card?.line ?? "只显示时间")")
    }
}

struct DeviceStatusTile: View {
    var device: FamilyState.Device
    var currentVersion: Int
    var controlsRev: Int
    var zone: TimeZone
    var framed = true

    var body: some View {
        let applied = device.appliedVersion ?? 0
        let lastSeen = device.lastSeenAt?.serverDate
        let stale = lastSeen.map { Date().timeIntervalSince($0) > 120 } ?? true
        var lines: [String] = []
        lines.append(lastSeen.map { "最后联系 \($0.relativeChinese)" } ?? "从未联系")
        if stale { lines.append("此后的状态未知；设备可能离线、锁屏或没电") }
        if let report = device.report {
            lines.append("声音输出：\(report.audioRoute)")
            if report.clockSuspect { lines.append("⚠︎ \(report.clockDetail ?? "设备时间可能不正确")，已暂停安排提示") }
            if !report.missingAssets.isEmpty { lines.append("⚠︎ \(report.missingAssets.count) 个照片或录音未下载，暂用文字") }
            if !report.brokenAssets.isEmpty { lines.append("⚠︎ \(report.brokenAssets.count) 段录音无法播放，请重录") }
            if !report.speechAvailable { lines.append("⚠︎ 设备上没有可用的中文朗读语音") }
            if report.storageLow { lines.append("⚠︎ 存储空间不足") }
            if let problem = report.lastProblem { lines.append(problem) }
        }
        if (device.appliedControlsRev ?? 0) < controlsRev { lines.append("暂停设置等待设备应用") }
        let value = currentVersion == 0 ? "等待首次发布" : (applied >= currentVersion ? "已应用第 \(applied) 版" : "仍在显示第 \(applied) 版")
        return StatusTile(icon: "ipad.landscape", tint: applied >= currentVersion && !stale ? Theme.ok : Theme.warn,
                          title: device.name, value: value, detail: lines.joined(separator: "\n"), framed: framed)
    }
}

struct ControlsCard: View {
    @Bindable var store: CaregiverStore

    var body: some View {
        let controls = store.family?.controls ?? .init()
        VStack(alignment: .leading, spacing: 10) {
            Text("暂停").font(.headline)
            Toggle("暂停患者设备的声音", isOn: Binding(get: { controls.soundPaused }, set: { value in
                Task { await store.setControls(DeviceControls(soundPaused: value, displayPaused: controls.displayPaused)) }
            }))
            .accessibilityIdentifier("controls.sound")
            Toggle("暂停展示（只显示时间）", isOn: Binding(get: { controls.displayPaused }, set: { value in
                Task { await store.setControls(DeviceControls(soundPaused: controls.soundPaused, displayPaused: value)) }
            }))
            .accessibilityIdentifier("controls.display")
            if let error = store.actionError { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            Text("暂停立即生效，不需要重新发布内容。患者在屏幕上点“停止”随时可以停止声音。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(0.92)))
    }
}

struct SetupChecklist: View {
    @Bindable var store: CaregiverStore
    var openTab: (Int) -> Void
    @AppStorage("checkedInPerson") private var checkedInPerson = false

    var body: some View {
        let published = store.currentVersion > 0
        let paired = !(store.family?.activeDisplays.isEmpty ?? true)
        let applied: Bool = { if case .applied = store.deliveryStatus { return true }; return false }()
        if !(published && paired && applied && checkedInPerson) {
            VStack(alignment: .leading, spacing: 10) {
                Text("完成首次设置").font(.headline)
                row(store.hasUnpublishedChanges || published, "添加一条真实安排（可选照片和录音）", tab: 1)
                row(published, "预览并发布", tab: 1)
                row(paired, "连接患者设备", tab: 2)
                row(applied, "确认患者设备已应用", tab: 2)
                Toggle("我已在患者实际的观看距离和房间声音下检查过", isOn: $checkedInPerson)
                    .font(.subheadline)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(0.92)))
        }
    }

    private func row(_ done: Bool, _ text: String, tab: Int) -> some View {
        Button { openTab(tab) } label: {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.ok : .secondary)
                Text(text).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
