import HereNowCore
import SwiftUI

/// Settings on a patient-only device after PIN verification. Content itself is edited on the caregiver's phone.
struct DisplayManagementView: View {
    @Environment(AppModel.self) private var model
    @Bindable var engine: DisplayEngine
    @State private var confirmUnpair = false
    @State private var changingPIN = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        model.lockToPatientMode()
                    } label: {
                        Label("返回患者屏幕", systemImage: "rectangle.inset.filled")
                            .font(.headline)
                    }
                    .accessibilityIdentifier("display.backToPatient")
                } footer: {
                    Text("内容请在照护者 iPhone 上编辑和发布。这里只管理这台设备。")
                }
                DisplayStatusSections(engine: engine)
                Section("本机暂停") {
                    Toggle("暂停这台设备的声音", isOn: Binding(
                        get: { engine.state.localControls.soundPaused },
                        set: { engine.setLocalControls(DeviceControls(soundPaused: $0, displayPaused: engine.state.localControls.displayPaused)) }))
                    Toggle("暂停展示（只显示时间）", isOn: Binding(
                        get: { engine.state.localControls.displayPaused },
                        set: { engine.setLocalControls(DeviceControls(soundPaused: engine.state.localControls.soundPaused, displayPaused: $0)) }))
                }
                Section("管理保护") {
                    Button("修改管理 PIN") { changingPIN = true }
                }
                Section {
                    Button("解除配对并清除本机数据", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("清除后这台设备不再同步，也不会保留照片、录音和安排。照护者手机上会显示“已清除”。")
                }
            }
            .navigationTitle(engine.credential.deviceName)
            .confirmationDialog("解除配对？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("解除配对并清除", role: .destructive) { Task { await model.unpairDisplay() } }
            } message: {
                Text("家庭资料会从这台设备删除。之后需要重新输入配对码才能再次使用。")
            }
            .fullScreenCover(isPresented: $changingPIN) { PINSetupView { changingPIN = false } }
        }
    }
}

/// Status of the patient device, shared by its own management screen and by single-device caregivers.
struct DisplayStatusSections: View {
    @Bindable var engine: DisplayEngine

    var body: some View {
        let state = engine.state
        let zone = state.snapshot?.timeZone ?? .current
        Section("内容") {
            LabeledContent("家庭", value: engine.credential.familyName)
            LabeledContent("正在显示", value: state.version == 0 ? "尚未收到发布内容" : "第 \(state.version) 版")
            if let applied = state.appliedAt { LabeledContent("应用时间", value: applied.formatted(in: zone)) }
            if let blocked = state.blockedVersion { LabeledContent("未能应用", value: "第 \(blocked) 版") }
            if state.controls.displayPaused || state.controls.soundPaused {
                Text("照护者手机已暂停\(state.controls.displayPaused ? "展示" : "")\(state.controls.displayPaused && state.controls.soundPaused ? "和" : "")\(state.controls.soundPaused ? "声音" : "")")
                    .foregroundStyle(Theme.warn)
            }
            if let problem = state.lastProblem { Text(problem).foregroundStyle(Theme.warn) }
        }
        Section {
            LabeledContent("同步", value: engine.online ? "已连接" : "未连接")
            if let last = state.lastSyncAt { LabeledContent("最后同步", value: last.relativeChinese) }
            if let lease = state.leaseExpiresAt {
                LabeledContent("离线展示授权至", value: lease.formatted(in: zone))
            }
            if let problem = engine.connectionProblem, !engine.online { Text(problem).foregroundStyle(Theme.warn) }
        } header: {
            Text("连接")
        } footer: {
            Text("连续 7 天无法联网验证授权后，这台设备只显示时间，不再显示家庭内容。")
        }
        Section("时间") {
            LabeledContent("患者所在地", value: zone.identifier)
            LabeledContent("设备时间", value: Date().formatted(in: zone, "M月d日 HH:mm"))
            if state.clock.suspect {
                Text(state.clock.detail ?? "设备时间可能不正确，已暂停安排提示").foregroundStyle(Theme.bad)
                Button("我已核对设备时间正确") { engine.confirmClockInPerson() }
            } else {
                LabeledContent("时间检查", value: "正常")
            }
        }
        Section("声音") {
            LabeledContent("当前输出", value: AudioEnvironment.currentRoute)
            LabeledContent("系统朗读（中文）", value: AudioEnvironment.speechAvailable(language: state.snapshot?.profile.languageCode ?? "zh-CN") ? "可用" : "不可用")
            if let audio = engine.moment.audio {
                Button(engine.playback.isPlaying ? "停止试听" : "试听患者现在会听到的声音") { engine.toggleSound() }
                Text(audioDescription(audio)).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("当前没有可播放的声音，患者端不显示“听一听”按钮。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func audioDescription(_ audio: AudioSource) -> String {
        switch audio {
        case let .recording(_, speaker): "家人录音：\(speaker)"
        case .speech: "系统朗读当前短句"
        }
    }
}
