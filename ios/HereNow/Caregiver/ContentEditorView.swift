import HereNowCore
import SwiftUI

/// Draft editor. Nothing here reaches the patient until “预览并发布”.
struct ContentEditorView: View {
    @Bindable var store: CaregiverStore
    @State private var editing: EditingEvent?
    @State private var reviewing = false
    @State private var confirmDiscard = false
    @State private var previewingSpeech = PlaybackController()

    struct EditingEvent: Identifiable {
        var event: ScheduleEvent
        var isNew: Bool
        var id: String { event.id }
    }

    private func bind<T>(_ path: WritableKeyPath<FamilySnapshot, T>) -> Binding<T> {
        Binding(get: { store.workingSnapshot[keyPath: path] }, set: { value in store.edit { $0[keyPath: path] = value } })
    }

    var body: some View {
        let snapshot = store.workingSnapshot
        let now = Date()
        let upcoming = snapshot.events.filter { !$0.isCancelled && $0.showUntil > now }.sorted { $0.start < $1.start }
        let past = snapshot.events.filter { $0.isCancelled || $0.showUntil <= now }.sorted { $0.start > $1.start }
        NavigationStack {
            Form {
                if store.hasUnpublishedChanges || store.draft?.mergeNotes.isEmpty == false {
                    Section {
                        ForEach(store.draft?.mergeNotes ?? [], id: \.self) { Text($0).foregroundStyle(Theme.warn) }
                        Label("有未发布的修改，患者端仍显示已发布的版本", systemImage: "pencil.circle")
                        Button("放弃这些修改", role: .destructive) { confirmDiscard = true }
                    }
                }
                Section {
                    ForEach(upcoming) { event in
                        Button { editing = EditingEvent(event: event, isNew: false) } label: { EventRow(event: event, zone: snapshot.timeZone) }
                            .accessibilityIdentifier("editor.event.\(event.personName)")
                    }
                    Button {
                        editing = EditingEvent(event: newEvent(snapshot), isNew: true)
                    } label: {
                        Label("添加安排", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("editor.addEvent")
                    if !past.isEmpty {
                        DisclosureGroup("已取消或已过期（\(past.count)）") {
                            ForEach(past) { EventRow(event: $0, zone: snapshot.timeZone) }
                        }
                    }
                } header: {
                    Text("安排")
                } footer: {
                    Text("患者屏幕一次只显示一项：开始时间最早、仍在显示期内的安排。到“显示至”后自动移除，不会显示为“已来过”。")
                }

                RecurringSection(store: store)

                Section {
                    NavigationLink { PlaceEditor(store: store) } label: {
                        LabeledContent("地点提示", value: snapshot.place.enabled ? snapshot.place.line : "未开启")
                    }
                    Picker("卡片重点", selection: bind(\.display.focus)) {
                        Text("有安排时显示安排").tag(CardFocus.automatic)
                        Text("只显示地点").tag(CardFocus.placeOnly)
                    }
                    Toggle("显示日期和星期", isOn: bind(\.display.showDate))
                    Picker("文字大小", selection: bind(\.display.textScale)) {
                        ForEach(TextScale.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        TextField("没有安排和地点时的中性短句（可留空）", text: bind(\.display.neutralLine))
                        if !snapshot.display.neutralLine.isEmpty {
                            FitIndicator(fits: store.fits(snapshot.display.neutralLine, hasPhoto: false, scale: snapshot.display.textScale))
                        }
                    }
                } header: {
                    Text("患者屏幕")
                } footer: {
                    Text("中性短句不要写应用无法确认的事，例如“家人都在”“已经吃过饭了”。")
                }

                Section {
                    Toggle("没有有效录音时用系统声音朗读", isOn: bind(\.voice.systemSpeechFallback))
                    Toggle("朗读时先叫称呼（\(snapshot.profile.callName)）", isOn: bind(\.voice.addressByName))
                    Button(previewingSpeech.isPlaying ? "停止试听" : "试听系统朗读") {
                        let line = MomentResolver.currentEvent(in: snapshot, now: now)?.line ?? snapshot.place.line
                        let text = MomentResolver.spokenText(line.isEmpty ? "这是系统朗读的声音" : line, snapshot: snapshot)
                        let card = Card(kind: .neutralLine, line: text, photoAssetID: nil, identity: "preview")
                        previewingSpeech.toggle(audio: .speech(text: text, languageCode: snapshot.profile.languageCode), card: card) { _ in URL(fileURLWithPath: "/") }
                    }
                    if !AudioEnvironment.speechAvailable(language: snapshot.profile.languageCode) {
                        Text("这台手机没有可用的中文朗读语音；患者设备的情况见「设备」。").foregroundStyle(Theme.warn)
                    }
                    NavigationLink { AutoPlayEditor(store: store) } label: {
                        LabeledContent("自动问候", value: snapshot.autoPlay.enabled ? "已开启" : "关闭")
                    }
                    .accessibilityIdentifier("editor.autoplay")
                } header: {
                    Text("声音")
                } footer: {
                    Text("系统声音不模仿家人，也不会自动播放。患者设备没有可用语音时，按钮会隐藏，文字照常显示。")
                }

                ComfortSection(store: store)

                Section {
                    NavigationLink("时段与夜间") { SegmentsEditor(store: store) }
                    NavigationLink { ProfileEditor(store: store) } label: {
                        LabeledContent("患者资料", value: "\(snapshot.profile.callName) · \(snapshot.profile.timeZoneID)")
                    }
                }
            }
            .navigationTitle("内容")
            .safeAreaInset(edge: .bottom) {
                Button { reviewing = true } label: {
                    Text("预览并发布")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 26).fill(store.hasUnpublishedChanges ? Theme.accent : Color.gray))
                }
                .disabled(!store.hasUnpublishedChanges)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("editor.review")
            }
            .sheet(item: $editing) { item in
                EventEditor(store: store, event: item.event, isNew: item.isNew)
            }
            .sheet(isPresented: $reviewing) { PublishReviewView(store: store) }
            .confirmationDialog("放弃未发布的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { store.discardDraft() }
            }
        }
    }

    private func newEvent(_ snapshot: FamilySnapshot) -> ScheduleEvent {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = snapshot.timeZone
        let nextHour = calendar.nextDate(after: Date().addingTimeInterval(1800), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        let showFrom = calendar.startOfDay(for: nextHour)
        return ScheduleEvent(personName: "", line: "", lineIsSuggested: true, start: nextHour, showFrom: showFrom, showUntil: nextHour)
    }
}

struct EventRow: View {
    var event: ScheduleEvent
    var zone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.line.isEmpty ? "（未填写短句）" : event.line)
                .font(.body.weight(.semibold))
                .foregroundStyle(event.isCancelled ? .secondary : .primary)
                .strikethrough(event.isCancelled)
            Text("\(event.start.formatted(in: zone)) · 显示至 \(event.showUntil.formatted(in: zone, "M月d日 HH:mm"))\(event.isCancelled ? " · 已取消" : "")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if event.recording != nil {
                Label(event.recordingIsCurrent ? "有家人录音" : "录音待复核", systemImage: event.recordingIsCurrent ? "waveform" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(event.recordingIsCurrent ? Color.secondary : Theme.warn)
            }
        }
    }
}

struct FitIndicator: View {
    var fits: Bool

    var body: some View {
        Label(fits ? "患者屏幕上两行内" : "超过两行，请改短（不会缩小字号或截断）",
              systemImage: fits ? "checkmark.circle" : "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(fits ? Theme.ok : Theme.bad)
            .accessibilityIdentifier("fit.indicator")
    }
}

struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    @State var event: ScheduleEvent
    var isNew: Bool
    @State private var untilChosen: Bool
    @State private var showFromChoice: ShowFrom = .sameDay
    @State private var confirmCancel = false
    @State private var voice = false

    enum ShowFrom: String, CaseIterable { case now = "现在起", sameDay = "当天", dayBefore = "提前一天" }

    init(store: CaregiverStore, event: ScheduleEvent, isNew: Bool) {
        self.store = store
        _event = State(initialValue: event)
        self.isNew = isNew
        _untilChosen = State(initialValue: !isNew)
    }

    private var snapshot: FamilySnapshot { store.workingSnapshot }
    private var zone: TimeZone { snapshot.timeZone }

    var body: some View {
        NavigationStack {
            Form {
                Section("人物") {
                    TextField("例如 小雨（女儿）", text: $event.personName)
                        .accessibilityIdentifier("event.person")
                        .onChange(of: event.personName) { _, _ in refreshSuggestion() }
                    Button { voice = true } label: { Label("用语音填写", systemImage: "waveform.badge.mic") }
                        .accessibilityIdentifier("event.voice")
                }
                Section {
                    DatePicker("开始", selection: $event.start)
                        .environment(\.timeZone, zone)
                        .onChange(of: event.start) { _, _ in
                            applyShowFrom()
                            if !untilChosen { event.showUntil = event.start }
                            refreshSuggestion()
                        }
                    Picker("开始显示", selection: $showFromChoice) {
                        ForEach(ShowFrom.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: showFromChoice) { _, _ in applyShowFrom(); refreshSuggestion() }
                    if untilChosen {
                        DatePicker("显示至", selection: $event.showUntil, in: event.start...)
                            .environment(\.timeZone, zone)
                            .accessibilityIdentifier("event.until")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(untilChosen ? "快速设置“显示至”" : "选择“显示至”（必填）")
                            .font(.subheadline)
                            .foregroundStyle(untilChosen ? Color.secondary : Theme.accent)
                        HStack {
                            Button("1 小时") { setUntil(hours: 1) }.accessibilityIdentifier("event.until.1h")
                            Button("2 小时") { setUntil(hours: 2) }.accessibilityIdentifier("event.until.2h")
                            Button("3 小时") { setUntil(hours: 3) }.accessibilityIdentifier("event.until.3h")
                            Button("当天结束") { setUntilEndOfDay() }.accessibilityIdentifier("event.until.endOfDay")
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("时间（患者当地：\(zone.identifier)，\(zone.abbreviation() ?? "")）")
                } footer: {
                    Text("到开始时间不会被标记为已发生。到“显示至”后，这项安排从患者屏幕移除。")
                }
                Section {
                    TextField("例如 小雨计划下午 3 点来", text: $event.line, axis: .vertical)
                        .font(.title3)
                        .accessibilityIdentifier("event.line")
                        .onChange(of: event.line) { _, value in
                            if value != suggestion { event.lineIsSuggested = false }
                        }
                    if !event.line.isEmpty {
                        FitIndicator(fits: store.fits(event.line, hasPhoto: event.photoAssetID != nil, scale: snapshot.display.textScale))
                    }
                    if !event.personName.isEmpty, event.line != suggestion {
                        Button("使用建议：\(suggestion)") {
                            event.line = suggestion
                            event.lineIsSuggested = true
                        }
                    }
                } header: {
                    Text("给患者看的一句话")
                } footer: {
                    Text("一句话只说一件事，写“计划”，不要写“已经到了”。")
                }
                Section("照片（可选，只显示一张）") {
                    PhotoField(assetID: $event.photoAssetID, assets: store.assets)
                }
                Section {
                    RecordingField(recording: $event.recording, fingerprint: event.fingerprint, assets: store.assets,
                                   defaultSpeaker: event.personName)
                } header: {
                    Text("家人录音（可选）")
                } footer: {
                    Text("录音会和这句话一起出现。修改时间、人物或短句后，旧录音会标为待复核，复核前不会播放。")
                }
                if hasTie {
                    Section {
                        Toggle("同一时间有多项安排时，患者端显示这一项", isOn: $event.preferredOnTie)
                    } footer: {
                        Text("另有安排的开始时间与这项相同。发布前必须合并，或选出患者端显示的一项。")
                    }
                }
                if !isNew, !event.isCancelled {
                    Section {
                        Button("取消这项安排", role: .destructive) { confirmCancel = true }
                            .accessibilityIdentifier("event.cancel")
                    } footer: {
                        Text("取消后需要发布才会生效；它的录音同时失效。")
                    }
                }
            }
            .navigationTitle(isNew ? "新安排" : "编辑安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存到草稿") { save() }
                        .disabled(event.personName.trimmingCharacters(in: .whitespaces).isEmpty || event.line.isEmpty || !untilChosen)
                        .accessibilityIdentifier("event.save")
                }
            }
            .confirmationDialog("取消这项安排？", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("取消安排", role: .destructive) {
                    event.isCancelled = true
                    save()
                }
            }
            .onAppear(perform: inferShowFrom)
            .sheet(isPresented: $voice) {
                VoiceDraftSheet(zone: zone) { draft in
                    if let name = draft.personName { event.personName = name }
                    if let start = draft.start { event.start = start }
                    event.lineIsSuggested = true
                    refreshSuggestion()
                }
            }
        }
    }

    private var suggestion: String {
        EventWording.suggestedLine(person: event.personName, start: event.start, showFrom: event.showFrom, snapshot: snapshot)
    }

    private var hasTie: Bool {
        snapshot.events.contains { $0.id != event.id && !$0.isCancelled && Int($0.start.timeIntervalSince1970 / 60) == Int(event.start.timeIntervalSince1970 / 60) }
    }

    private func refreshSuggestion() {
        if event.lineIsSuggested, !event.personName.isEmpty { event.line = suggestion }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func inferShowFrom() {
        let startDay = calendar.startOfDay(for: event.start)
        if event.showFrom == startDay { showFromChoice = .sameDay }
        else if event.showFrom == calendar.date(byAdding: .day, value: -1, to: startDay) { showFromChoice = .dayBefore }
        else if !isNew { showFromChoice = .now }
    }

    private func applyShowFrom() {
        let startDay = calendar.startOfDay(for: event.start)
        switch showFromChoice {
        case .now: event.showFrom = min(Date(), event.start)
        case .sameDay: event.showFrom = startDay
        case .dayBefore: event.showFrom = calendar.date(byAdding: .day, value: -1, to: startDay) ?? startDay
        }
    }

    private func setUntil(hours: Double) {
        event.showUntil = event.start.addingTimeInterval(hours * 3600)
        untilChosen = true
    }

    private func setUntilEndOfDay() {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.start))!.addingTimeInterval(-60)
        event.showUntil = max(end, event.start)
        untilChosen = true
    }

    private func save() {
        event.updatedAt = Date()
        let saved = event
        store.edit { snapshot in
            if let index = snapshot.events.firstIndex(where: { $0.id == saved.id }) {
                snapshot.events[index] = saved
            } else {
                snapshot.events.append(saved)
            }
        }
        dismiss()
    }
}

struct PlaceEditor: View {
    @Bindable var store: CaregiverStore

    private func bind<T>(_ path: WritableKeyPath<PlacePrompt, T>) -> Binding<T> {
        Binding(get: { store.workingSnapshot.place[keyPath: path] }, set: { value in store.edit { $0.place[keyPath: path] = value } })
    }

    var body: some View {
        let place = store.workingSnapshot.place
        Form {
            Section {
                Toggle("显示地点提示", isOn: bind(\.enabled))
            } footer: {
                Text("地点只来自你的设置。设备被搬到别的房间时，应用不会知道，需要你更新。")
            }
            if place.enabled {
                Section("给患者看的一句话") {
                    TextField("例如 这里是家里的客厅", text: bind(\.line), axis: .vertical).font(.title3)
                    if !place.line.isEmpty {
                        FitIndicator(fits: store.fits(place.line, hasPhoto: place.photoAssetID != nil, scale: store.workingSnapshot.display.textScale))
                    }
                }
                Section {
                    DatePicker("复核期限", selection: Binding(get: { place.reviewBy ?? Date().addingTimeInterval(30 * 86_400) },
                                                          set: { value in store.edit { $0.place.reviewBy = value } }),
                               in: Date()..., displayedComponents: .date)
                        .environment(\.timeZone, store.workingSnapshot.timeZone)
                    HStack {
                        ForEach([7, 30, 90], id: \.self) { days in
                            Button("\(days) 天") { store.edit { $0.place.reviewBy = Date().addingTimeInterval(Double(days) * 86_400) } }
                                .buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    Text("到期仍未重新确认，患者端会隐藏这句地点断言，只保留时间。")
                }
                Section("照片（可选）") { PhotoField(assetID: bind(\.photoAssetID), assets: store.assets) }
                Section("家人录音（可选）") {
                    RecordingField(recording: bind(\.recording), fingerprint: place.fingerprint, assets: store.assets, defaultSpeaker: "")
                }
            }
        }
        .navigationTitle("地点提示")
    }
}

struct SegmentsEditor: View {
    @Bindable var store: CaregiverStore

    var body: some View {
        Form {
            SegmentRows(segments: Binding(get: { store.workingSnapshot.segments }, set: { v in store.edit { $0.segments = v } }),
                        zone: store.workingSnapshot.timeZone)
            NightRows(night: Binding(get: { store.workingSnapshot.night }, set: { v in store.edit { $0.night = v } }))
        }
        .navigationTitle("时段与夜间")
    }
}

struct ProfileEditor: View {
    @Bindable var store: CaregiverStore

    var body: some View {
        Form {
            Section("称呼") {
                TextField("称呼", text: Binding(get: { store.workingSnapshot.profile.callName }, set: { v in store.edit { $0.profile.callName = v } }))
            }
            Section {
                NavigationLink {
                    TimeZonePicker(selection: Binding(get: { store.workingSnapshot.profile.timeZoneID }, set: { v in store.edit { $0.profile.timeZoneID = v } }))
                } label: {
                    LabeledContent("患者所在地时区", value: store.workingSnapshot.profile.timeZoneID)
                }
            } footer: {
                Text("修改时区后，已有安排的绝对时间不变，请检查它们在患者当地显示的时间是否仍正确。")
            }
        }
        .navigationTitle("患者资料")
    }
}
