import AVFoundation
import HereNowCore
import Speech
import SwiftUI

// MARK: Recurring plans

struct RecurringSection: View {
    @Bindable var store: CaregiverStore
    @State private var editing: RecurringEvent?

    var body: some View {
        let plans = store.workingSnapshot.recurring
        Section {
            ForEach(plans) { plan in
                Button { editing = plan } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.line.isEmpty ? "（未填写短句）" : plan.line)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(plan.isCancelled ? .secondary : .primary)
                            .strikethrough(plan.isCancelled)
                        Text("\(RecurringEvent.weekdayNames(plan.weekdays)) \(String(format: "%02d:%02d", plan.startMinute / 60, plan.startMinute % 60)) · 显示 \(plan.showForMinutes / 60) 小时\(plan.isCancelled ? " · 已停止" : "")")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("editor.recurring.\(plan.personName)")
            }
            Button {
                let zone = store.workingSnapshot.timeZone
                editing = RecurringEvent(personName: "", line: "", weekdays: [], startMinute: 15 * 60, showForMinutes: 0,
                                         firstDay: DayKey.string(Date(), zone: zone))
            } label: {
                Label("添加重复安排", systemImage: "repeat.circle.fill")
            }
            .accessibilityIdentifier("editor.addRecurring")
        } header: {
            Text("重复安排")
        } footer: {
            Text("例如每周六小雨来。每一次都按单次安排的规则显示：只在当天显示，到“显示至”后移除。可以跳过某一天。")
        }
        .sheet(item: $editing) { plan in
            RecurringEditor(store: store, plan: plan, isNew: !plans.contains { $0.id == plan.id })
        }
    }
}

struct RecurringEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    @State var plan: RecurringEvent
    var isNew: Bool

    private var zone: TimeZone { store.workingSnapshot.timeZone }

    var body: some View {
        NavigationStack {
            Form {
                Section("人物") {
                    TextField("例如 小雨（女儿）", text: $plan.personName).accessibilityIdentifier("recurring.person")
                }
                Section {
                    HStack(spacing: 6) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                            let on = plan.weekdays.contains(day)
                            Button(["日", "一", "二", "三", "四", "五", "六"][day - 1]) {
                                if on { plan.weekdays.removeAll { $0 == day } } else { plan.weekdays.append(day) }
                            }
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(on ? Theme.accent : Color(.tertiarySystemFill)))
                            .foregroundStyle(on ? .white : .primary)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("星期\(["日", "一", "二", "三", "四", "五", "六"][day - 1])")
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityIdentifier("recurring.day.\(day)")
                        }
                    }
                    DatePicker("开始时间", selection: minuteBinding($plan.startMinute), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    Picker("每次显示多久（必选）", selection: $plan.showForMinutes) {
                        Text("请选择").tag(0)
                        Text("1 小时").tag(60)
                        Text("2 小时").tag(120)
                        Text("3 小时").tag(180)
                    }
                    .accessibilityIdentifier("recurring.showFor")
                    Picker("开始显示", selection: $plan.showFrom) {
                        Text("当天").tag(RecurringEvent.ShowFrom.sameDay)
                        Text("提前一天").tag(RecurringEvent.ShowFrom.dayBefore)
                    }
                } header: {
                    Text("哪几天、几点（患者当地：\(zone.identifier)）")
                }
                Section {
                    TextField("例如 小雨计划下午 3 点来", text: $plan.line, axis: .vertical)
                        .font(.title3)
                        .accessibilityIdentifier("recurring.line")
                    if !plan.line.isEmpty {
                        FitIndicator(fits: store.fits(plan.line, hasPhoto: plan.photoAssetID != nil, scale: store.workingSnapshot.display.textScale))
                    }
                    if !plan.personName.isEmpty {
                        let suggestion = suggestedLine
                        if plan.line != suggestion {
                            Button("使用建议：\(suggestion)") { plan.line = suggestion }
                        }
                    }
                } header: {
                    Text("给患者看的一句话")
                } footer: {
                    Text("每一次都显示同一句话，所以不要写“明天”“这周”这类会过时的词。")
                }
                if !isNew, !plan.isCancelled {
                    Section {
                        ForEach(upcomingDays, id: \.self) { day in
                            Toggle(isOn: Binding(get: { !plan.skippedDays.contains(day) }, set: { on in
                                if on { plan.skippedDays.removeAll { $0 == day } } else { plan.skippedDays.append(day) }
                            })) {
                                Text(day)
                            }
                        }
                    } header: {
                        Text("接下来几次")
                    } footer: {
                        Text("关掉某一天即跳过这一次，其余照常。")
                    }
                }
                Section("照片（可选）") { PhotoField(assetID: $plan.photoAssetID, assets: store.assets) }
                Section {
                    RecordingField(recording: $plan.recording, fingerprint: plan.fingerprint, assets: store.assets, defaultSpeaker: plan.personName)
                } header: {
                    Text("家人录音（可选）")
                } footer: {
                    Text("修改人物、短句、时间或星期后，旧录音待复核，复核前不播放。")
                }
                if !isNew, !plan.isCancelled {
                    Section {
                        Button("停止这项重复安排", role: .destructive) {
                            plan.isCancelled = true
                            save()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新重复安排" : "编辑重复安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存到草稿") { save() }
                        .disabled(plan.personName.isEmpty || plan.line.isEmpty || plan.weekdays.isEmpty || plan.showForMinutes == 0)
                        .accessibilityIdentifier("recurring.save")
                }
            }
        }
    }

    private var suggestedLine: String {
        let segment = MomentResolver.segmentName(minute: plan.startMinute, segments: store.workingSnapshot.segments)
        let hour = plan.startMinute / 60 % 12 == 0 ? 12 : plan.startMinute / 60 % 12
        let minute = plan.startMinute % 60
        let clock = minute == 0 ? "\(hour) 点" : (minute == 30 ? "\(hour) 点半" : "\(hour):\(String(format: "%02d", minute))")
        return "\(plan.personName)计划\(segment) \(clock)来"
    }

    private var upcomingDays: [String] {
        let now = Date()
        var copy = plan
        copy.skippedDays = []
        return copy.occurrences(from: now, to: now.addingTimeInterval(21 * 86_400), in: zone)
            .prefix(4).map { DayKey.string($0.start, zone: zone) }
    }

    private func save() {
        plan.updatedAt = Date()
        let saved = plan
        store.edit { snapshot in
            if let index = snapshot.recurring.firstIndex(where: { $0.id == saved.id }) {
                snapshot.recurring[index] = saved
            } else {
                snapshot.recurring.append(saved)
            }
        }
        dismiss()
    }
}

// MARK: Comfort content

struct ComfortSection: View {
    @Bindable var store: CaregiverStore
    @State private var editing: ComfortItem?

    var body: some View {
        let items = store.workingSnapshot.comfortItems
        Section {
            ForEach(items) { item in
                Button { editing = item } label: {
                    HStack {
                        Label(item.title, systemImage: "heart.circle")
                        Spacer()
                        if !item.enabled { Text("已停用").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            Button { editing = ComfortItem(title: "") } label: { Label("添加安抚内容", systemImage: "plus.circle.fill") }
                .accessibilityIdentifier("editor.addComfort")
        } header: {
            Text("安抚内容")
        } footer: {
            Text("本人愿意听的家人录音或有权使用的音频，可配一张照片。只能由照护者手动开始，先在现场观察反应；不会定时或循环播放。")
        }
        .sheet(item: $editing) { item in
            ComfortEditor(store: store, item: item, isNew: !items.contains { $0.id == item.id })
        }
    }
}

struct ComfortEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    @State var item: ComfortItem
    var isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如 小雨唱的歌", text: $item.title).accessibilityIdentifier("comfort.title")
                    TextField("播放时给患者看的一句话（可留空）", text: $item.line)
                    Toggle("启用", isOn: $item.enabled)
                } footer: {
                    Text("如果某段内容让本人不舒服，停用它即可，其他内容不受影响。")
                }
                Section("录音（必需）") {
                    RecordingField(recording: $item.recording, fingerprint: ComfortItem.fingerprint, assets: store.assets, defaultSpeaker: "")
                }
                Section("照片（可选）") { PhotoField(assetID: $item.photoAssetID, assets: store.assets) }
                if !isNew {
                    Section {
                        Button("删除这项内容", role: .destructive) {
                            store.edit { $0.comfortItems.removeAll { $0.id == item.id } }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新安抚内容" : "安抚内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存到草稿") {
                        let saved = item
                        store.edit { snapshot in
                            if let index = snapshot.comfortItems.firstIndex(where: { $0.id == saved.id }) {
                                snapshot.comfortItems[index] = saved
                            } else {
                                snapshot.comfortItems.append(saved)
                            }
                        }
                        dismiss()
                    }
                    .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty || item.recording == nil)
                }
            }
        }
    }
}

/// Dashboard card: start a published comfort item on the patient screen, or stop it.
struct ComfortControlCard: View {
    @Bindable var store: CaregiverStore

    var body: some View {
        let items = (store.publishedSnapshot?.comfortItems ?? []).filter(\.enabled)
        let active = store.family?.controls.comfortItemID
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("安抚内容").font(.headline)
                ForEach(items) { item in
                    HStack {
                        Label(item.title, systemImage: active == item.id ? "speaker.wave.2.fill" : "heart")
                        Spacer()
                        if active == item.id {
                            Button("停止") { Task { await store.startComfort(nil) } }.buttonStyle(.bordered)
                        } else {
                            Button("播放") { Task { await store.startComfort(item.id) } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("comfort.play.\(item.title)")
                        }
                    }
                }
                Text("请在患者身边时使用，观察是否让本人舒服。设备离线超过 2 分钟后才收到的请求不会播放。患者点“停止”随时可以结束。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(14)
            .tile()
        }
    }
}

// MARK: Scheduled greetings

struct AutoPlayEditor: View {
    @Bindable var store: CaregiverStore

    private func bind<T>(_ path: WritableKeyPath<AutoPlaySettings, T>) -> Binding<T> {
        Binding(get: { store.workingSnapshot.autoPlay[keyPath: path] }, set: { v in store.edit { $0.autoPlay[keyPath: path] = v } })
    }

    var body: some View {
        let settings = store.workingSnapshot.autoPlay
        Form {
            Section {
                Toggle("开启自动问候", isOn: bind(\.enabled)).accessibilityIdentifier("autoplay.enabled")
            } footer: {
                Text("默认关闭。不是每个人都需要自动出现的声音；先由照护者陪同点“听一听”，确认本人愿意听再开启。")
            }
            if settings.enabled {
                Section("什么时候") {
                    Toggle("安排开始前问候一次", isOn: bind(\.greetBeforeEvents))
                    if settings.greetBeforeEvents {
                        Stepper("提前 \(settings.leadMinutes) 分钟", value: bind(\.leadMinutes), in: 5...120, step: 5)
                    }
                    ForEach(store.workingSnapshot.segments) { segment in
                        Toggle("“\(segment.name)”开始时问候一次", isOn: Binding(
                            get: { settings.segmentIDs.contains(segment.id) },
                            set: { on in store.edit { s in
                                if on { s.autoPlay.segmentIDs.append(segment.id) } else { s.autoPlay.segmentIDs.removeAll { $0 == segment.id } }
                            } }))
                    }
                }
                Section {
                    DatePicker("静音开始", selection: minuteBinding(bind(\.quietStartMinute)), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    DatePicker("静音结束", selection: minuteBinding(bind(\.quietEndMinute)), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    Stepper("每天最多 \(settings.dailyLimit) 次", value: bind(\.dailyLimit), in: 1...10)
                    Stepper("两次至少间隔 \(settings.minIntervalMinutes) 分钟", value: bind(\.minIntervalMinutes), in: 15...240, step: 15)
                } header: {
                    Text("限制")
                } footer: {
                    Text("只在患者屏幕亮着、应用在前台时播放；离线、锁屏或在后台时错过的不会补播。暂停声音或患者点“停止”永远优先。")
                }
            }
        }
        .navigationTitle("自动问候")
    }
}

// MARK: Play log

struct PlayLogView: View {
    @Bindable var store: CaregiverStore
    @State private var log: PlayLogResponse?
    @State private var confirmClear = false

    var body: some View {
        let zone = store.patientTimeZone
        Form {
            Section {
                Toggle("记录播放使用情况", isOn: Binding(
                    get: { store.workingSnapshot.playLog.enabled },
                    set: { value in store.edit { $0.playLog.enabled = value } }))
            } footer: {
                Text("默认关闭，开关在发布后生效。只记录按钮播放、自动问候和安抚内容何时开始和结束，不录音、不记录患者说的话，也不推断情绪或病情。保留 7 天。")
            }
            if let log {
                let days = PlayLogSummary.days(
                    entries: log.entries.map { PlayLogEntry(at: $0.at, kind: PlayLogEntry.Kind(rawValue: $0.kind) ?? .started,
                                                            trigger: PlayLogEntry.Trigger(rawValue: $0.trigger) ?? .button, source: $0.source) },
                    coverage: log.coverage.map { CoverageSpan(start: $0.start, end: $0.end) },
                    zone: zone, endingAt: Date())
                Section {
                    ForEach(days, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.day).font(.headline)
                            if day.coveredMinutes == 0 {
                                Text("没有记录数据（设备未开、应用不在前台或尚未开启记录），不代表没有使用").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("点“听一听” \(day.buttonStarts) 次 · 自动问候 \(day.greetingStarts) 次 · 安抚内容 \(day.comfortStarts) 次")
                                Text("有记录的时间约 \(day.coveredMinutes / 60) 小时 \(day.coveredMinutes % 60) 分钟").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("最近 7 天（患者当地日期）")
                } footer: {
                    Text("次数少可能是设备没开、本人不想用、不会用或内容不相关；这不是重复提问的次数，也不说明病情变化。")
                }
                Section {
                    Button("清除全部记录", role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle("播放使用记录")
        .task { log = await store.loadPlayLog() }
        .refreshable { log = await store.loadPlayLog() }
        .confirmationDialog("清除全部播放记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                Task {
                    await store.clearPlayLog()
                    log = await store.loadPlayLog()
                }
            }
        }
    }
}

// MARK: Family suggestions

struct ProposalsCard: View {
    @Bindable var store: CaregiverStore
    @State private var placing: Proposal?

    var body: some View {
        let proposals = store.pendingProposals
        if !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("家人提交（\(proposals.count)）").font(.headline)
                ForEach(proposals) { proposal in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(proposal.deviceName) · \(title(proposal))").font(.subheadline.weight(.semibold))
                        if let note = proposal.payload.note, !note.isEmpty { Text(note).font(.footnote) }
                        HStack {
                            Button("使用") {
                                Task { if await store.fetchProposalAssets(proposal) { placing = proposal } }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("proposal.use")
                            Button("不使用", role: .destructive) { Task { await store.resolve(proposal: proposal, accept: false) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if let error = store.actionError { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
                Text("家人提交的内容不会直接出现在患者屏幕上；放进草稿后仍需你预览并发布。").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(14)
            .tile()
            .sheet(item: $placing) { ProposalPlacementSheet(store: store, proposal: $0) }
        }
    }

    private func title(_ p: Proposal) -> String {
        switch p.kind {
        case .recording: "录音（\(p.payload.speakerLabel ?? "未署名")）"
        case .photo: "照片"
        case .event: "建议安排：\(p.payload.line ?? p.payload.personName ?? "")"
        }
    }
}

/// Puts an accepted suggestion into the draft where the caregiver chooses.
struct ProposalPlacementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    var proposal: Proposal

    var body: some View {
        let snapshot = store.workingSnapshot
        let upcoming = snapshot.events.filter { !$0.isCancelled && $0.showUntil > Date() }
        NavigationStack {
            Form {
                if proposal.kind == .event {
                    Section {
                        Text(proposal.payload.line ?? "")
                        if let start = proposal.payload.start { Text(start.formatted(in: snapshot.timeZone)).foregroundStyle(.secondary) }
                        Button("加入草稿（还需设置“显示至”）") { place { s in
                            let start = proposal.payload.start ?? Date()
                            var calendar = Calendar(identifier: .gregorian)
                            calendar.timeZone = s.timeZone
                            s.events.append(ScheduleEvent(personName: proposal.payload.personName ?? "", line: proposal.payload.line ?? "",
                                                          start: start, showFrom: calendar.startOfDay(for: start), showUntil: start))
                        } }
                    } footer: {
                        Text("加入后“显示至”与开始时间相同，发布前请在「内容」里打开这项安排确认结束展示的时间。")
                    }
                } else {
                    Section("放到哪里") {
                        ForEach(upcoming) { event in
                            Button("附到「\(event.line)」") { place { s in
                                guard let i = s.events.firstIndex(where: { $0.id == event.id }) else { return }
                                var target = s.events[i]
                                attach(to: &target.photoAssetID, recording: &target.recording, fingerprint: target.fingerprint)
                                s.events[i] = target
                            } }
                        }
                        if snapshot.place.enabled {
                            Button("附到地点提示") { place { s in
                                var place = s.place
                                attach(to: &place.photoAssetID, recording: &place.recording, fingerprint: place.fingerprint)
                                s.place = place
                            } }
                        }
                        if proposal.kind == .recording {
                            Button("作为新的安抚内容（默认停用）") { place { s in
                                s.comfortItems.append(ComfortItem(title: "\(proposal.payload.speakerLabel ?? proposal.deviceName)的录音",
                                                                  recording: recording(fingerprint: ComfortItem.fingerprint), enabled: false))
                            } }
                        }
                    }
                }
            }
            .navigationTitle("使用家人提交的内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func recording(fingerprint: String) -> Recording? {
        guard proposal.kind == .recording, let sha = proposal.assetRefs.first else { return nil }
        let duration = (try? AVAudioPlayer(contentsOf: store.assets.url(for: sha)))?.duration ?? 0
        return Recording(assetID: sha, speakerLabel: proposal.payload.speakerLabel ?? proposal.deviceName,
                         recordedAt: proposal.createdAt.serverDate, durationSeconds: duration, confirmedFingerprint: fingerprint)
    }

    private func attach(to photo: inout String?, recording target: inout Recording?, fingerprint: String) {
        if proposal.kind == .photo { photo = proposal.assetRefs.first } else { target = recording(fingerprint: fingerprint) }
    }

    private func place(_ change: @escaping (inout FamilySnapshot) -> Void) {
        store.edit(change)
        Task {
            await store.resolve(proposal: proposal, accept: true)
            dismiss()
        }
    }
}

// MARK: Voice input

/// Dictation that only fills draft fields. Recognition runs on the device; without on-device support,
/// the caregiver types instead, so nothing is sent to a cloud service without a separate decision.
@MainActor
@Observable
final class DictationModel {
    var transcript = ""
    var listening = false
    var problem: String?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    var onDeviceAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true }

    func start() async {
        problem = nil
        guard onDeviceAvailable else {
            problem = "这台设备不支持本机中文语音识别，请直接输入文字。"
            return
        }
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speechOK, await AVAudioApplication.requestRecordPermission() else {
            problem = "没有语音识别或麦克风权限。可以直接输入文字，手工填写不受影响。"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
        } catch {
            problem = "无法开始听写：\(error.localizedDescription)"
            return
        }
        self.request = request
        listening = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result { self?.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self?.stop() }
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct VoiceDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    var zone: TimeZone
    var apply: (VoiceDraft) -> Void
    @State private var dictation = DictationModel()

    var body: some View {
        let draft = VoiceDraftParser.parse(dictation.transcript, now: Date(), zone: zone)
        NavigationStack {
            Form {
                Section {
                    TextField("例如：小雨明天下午三点来", text: $dictation.transcript, axis: .vertical)
                        .font(.title3)
                        .accessibilityIdentifier("voice.transcript")
                    if dictation.listening {
                        Button("停止听写") { dictation.stop() }
                    } else {
                        Button { Task { await dictation.start() } } label: { Label("按下后说话", systemImage: "mic.fill") }
                    }
                    if let problem = dictation.problem { Text(problem).foregroundStyle(Theme.warn) }
                } header: {
                    Text("说一句或输入一句")
                } footer: {
                    Text("只在本机识别，结果只进入草稿；必须由你核对后保存和发布。")
                }
                if !dictation.transcript.isEmpty {
                    Section("整理结果") {
                        LabeledContent("人物", value: draft.personName ?? "—")
                        LabeledContent("时间", value: draft.start.map { $0.formatted(in: zone, "M月d日 HH:mm") } ?? "—")
                        ForEach(draft.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn) }
                    }
                    Button("填入表单") {
                        dictation.stop()
                        apply(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier("voice.apply")
                }
            }
            .navigationTitle("用语音填写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dictation.stop(); dismiss() } } }
        }
    }
}
