import HereNowCore
import SwiftUI

/// First-time setup for the primary caregiver: boundaries, minimal profile, time segments, preferences, recovery key.
struct CaregiverOnboardingView: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void

    enum Step: Int, CaseIterable { case boundaries, profile, segments, preferences }

    @State private var step = Step.boundaries
    @State private var explained = false
    @State private var authorized = false
    @State private var snapshot = FamilySnapshot(profile: .init(callName: "", timeZoneID: TimeZone.current.identifier))
    @State private var familyName = ""
    @State private var placeReviewDays = 30
    @State private var segmentsConfirmed = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .boundaries: boundaries
                case .profile: profile
                case .segments: segments
                case .preferences: preferences
                }
                if let error { Text(error).foregroundStyle(Theme.bad) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.wallpaper)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .boundaries { Button("取消", action: onClose) } else { Button("上一步") { step = Step(rawValue: step.rawValue - 1)! } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == .preferences ? (working ? "正在创建…" : "创建家庭") : "下一步") { Task { await next() } }
                        .disabled(!canContinue || working)
                        .accessibilityIdentifier("onboarding.next")
                }
            }
        }
    }

    private var title: String {
        switch step {
        case .boundaries: "开始之前"
        case .profile: "患者资料"
        case .segments: "确认时段"
        case .preferences: "屏幕与声音"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .boundaries: explained && authorized
        case .profile: !snapshot.profile.callName.trimmingCharacters(in: .whitespaces).isEmpty
            && !familyName.trimmingCharacters(in: .whitespaces).isEmpty
            && (!snapshot.place.enabled || !snapshot.place.line.trimmingCharacters(in: .whitespaces).isEmpty)
        case .segments: segmentsConfirmed
        case .preferences: true
        }
    }

    private var boundaries: some View {
        Group {
            Section {
                Label("在熟悉的屏幕上显示现在的时段、一项已安排的事或所在地点，并可按需播放家人录音。", systemImage: "rectangle.and.text.magnifyingglass")
                Label("内容由你确认后发布；应用不知道患者是否看见、是否读懂，也不知道家人是否已到。", systemImage: "hand.raised")
                Label("不提供用药提醒、诊断、定位、跌倒报警或无人值守的安全监测。", systemImage: "cross.case")
                Label("能力或状况变化时可以随时暂停或停止使用。", systemImage: "pause.circle")
            } header: {
                Text("这个应用能做什么、不能做什么")
            }
            Section {
                Toggle("我已用患者能理解的方式说明屏幕用途，并尊重其意愿", isOn: $explained)
                    .accessibilityIdentifier("onboarding.explained")
                Toggle("我是主要照护者，有为其设置此类提示的照护授权", isOn: $authorized)
                    .accessibilityIdentifier("onboarding.authorized")
            } footer: {
                Text("不需要上传诊断证明。患者本人能参与时，请尊重其同意、拒绝和撤回。")
            }
        }
    }

    private var profile: some View {
        Group {
            Section {
                TextField("例如 妈妈、王阿姨", text: $snapshot.profile.callName)
                    .accessibilityIdentifier("onboarding.callName")
            } header: {
                Text("家人怎样称呼患者")
            } footer: {
                Text("不需要法定姓名、具体住址或病史。")
            }
            Section {
                TextField("例如 妈妈的家", text: $familyName)
                    .accessibilityIdentifier("onboarding.familyName")
            } header: {
                Text("家庭名称")
            } footer: {
                Text("配对患者设备时会显示这个名字，用来确认加入的是正确的家庭。")
            }
            Section {
                NavigationLink {
                    TimeZonePicker(selection: $snapshot.profile.timeZoneID)
                } label: {
                    LabeledContent("患者所在地时区", value: snapshot.profile.timeZoneID)
                }
                LabeledContent("界面语言", value: "简体中文")
            } footer: {
                Text("所有安排都按患者当地时间编辑和显示，即使你的手机在其他时区。")
            }
            Section {
                Toggle("显示地点提示", isOn: $snapshot.place.enabled)
                if snapshot.place.enabled {
                    TextField("例如 这里是家里的客厅", text: $snapshot.place.line)
                        .accessibilityIdentifier("onboarding.placeLine")
                    Picker("复核期限", selection: $placeReviewDays) {
                        Text("7 天后").tag(7)
                        Text("30 天后").tag(30)
                        Text("90 天后").tag(90)
                    }
                }
            } header: {
                Text("地点提示")
            } footer: {
                Text("没有安排时显示这句话。到复核期限仍未确认，患者端会隐藏这句地点断言。设备位置变化不会被自动识别。")
            }
        }
    }

    private var segments: some View {
        Group {
            SegmentRows(segments: $snapshot.segments, zone: snapshot.timeZone)
            NightRows(night: $snapshot.night)
            Section {
                Toggle("这些时段符合患者的作息", isOn: $segmentsConfirmed)
                    .accessibilityIdentifier("onboarding.segmentsConfirmed")
            } footer: {
                Text("默认时段只是起点，请按本人的作息调整。之后可在「内容」中修改。")
            }
        }
    }

    private var preferences: some View {
        Group {
            Section {
                Toggle("在时段下方显示日期和星期", isOn: $snapshot.display.showDate)
                Picker("文字大小", selection: $snapshot.display.textScale) {
                    ForEach(TextScale.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("患者屏幕")
            } footer: {
                Text("默认只突出“下午”这样的时段，不显示精确时钟。")
            }
            Section {
                Toggle("没有家人录音时，用系统声音朗读短句", isOn: $snapshot.voice.systemSpeechFallback)
                Toggle("朗读时先叫称呼", isOn: $snapshot.voice.addressByName)
            } header: {
                Text("声音")
            } footer: {
                Text("系统声音不会模仿家人。默认不自动播放任何声音，患者点“听一听”才会播放。")
            }
        }
    }

    private func next() async {
        error = nil
        guard step == .preferences else {
            step = Step(rawValue: step.rawValue + 1)!
            return
        }
        working = true
        defer { working = false }
        if snapshot.place.enabled {
            snapshot.place.reviewBy = Calendar.current.date(byAdding: .day, value: placeReviewDays, to: Date())
        }
        do {
            let session = try await model.api.createFamily(familyName: familyName, installationID: Installation.id, deviceName: AppModel.deviceName)
            PendingRecoveryKey.save(session.recoveryKey)
            onClose()
            model.attachCaregiver(
                CaregiverCredential(familyID: session.familyId, deviceID: session.deviceId, token: session.token, familyName: familyName),
                initialDraft: snapshot
            )
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
        }
    }
}

struct TimeZonePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List(TimeZone.knownTimeZoneIdentifiers.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { id in
            Button {
                selection = id
                dismiss()
            } label: {
                HStack {
                    Text(id).foregroundStyle(.primary)
                    Spacer()
                    if id == selection { Image(systemName: "checkmark") }
                }
            }
        }
        .searchable(text: $query, prompt: "例如 Shanghai")
        .navigationTitle("患者所在地时区")
    }
}

/// Minutes-of-day editing without time zone conversions: a UTC calendar keeps 13:30 as 13:30.
private let minuteCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
    Binding(
        get: { Date(timeIntervalSince1970: TimeInterval(minute.wrappedValue * 60)) },
        set: {
            let parts = minuteCalendar.dateComponents([.hour, .minute], from: $0)
            minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    )
}

struct SegmentRows: View {
    @Binding var segments: [DaySegment]
    var zone: TimeZone

    var body: some View {
        Section {
            ForEach($segments) { $segment in
                HStack {
                    TextField("名称", text: $segment.name).frame(maxWidth: 120)
                    Spacer()
                    DatePicker("开始", selection: minuteBinding($segment.startMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                }
            }
            .onDelete { segments.remove(atOffsets: $0) }
            Button("添加时段") { segments.append(DaySegment(name: "新时段", startMinute: 12 * 60)) }
            Button("恢复默认时段") { segments = DaySegment.defaults }
        } header: {
            Text("时段（患者当地时间）")
        } footer: {
            Text("患者屏幕显示当前所在时段的名称，例如“下午”。最后一个时段会一直持续到第二天第一个时段开始。")
        }
    }
}

struct NightRows: View {
    @Binding var night: NightSettings

    var body: some View {
        Section {
            DatePicker("夜间开始", selection: minuteBinding($night.startMinute), displayedComponents: .hourAndMinute)
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            DatePicker("夜间结束", selection: minuteBinding($night.endMinute), displayedComponents: .hourAndMinute)
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            Toggle("夜间隐藏照片", isOn: $night.hidePhoto)
        } header: {
            Text("夜间")
        } footer: {
            Text("夜间使用更暗、刺激更少的配色，文字仍保持清晰对比；没有自动声音和动画。")
        }
    }
}
