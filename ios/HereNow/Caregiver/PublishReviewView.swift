import HereNowCore
import SwiftUI

/// Preview what the patient will see and hear, check problems, then publish explicitly.
struct PublishReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    @State private var openedAt = Date()
    @State private var previewTime: Date?
    @State private var publishing = false

    var body: some View {
        let snapshot = store.workingSnapshot
        let issues = store.validate(snapshot)
        let blocking = PublishValidator.hasBlocking(issues)
        NavigationStack {
            Form {
                Section {
                    let moments = previewMoments(snapshot)
                    let selected = previewTime ?? openedAt
                    Picker("预览时刻", selection: Binding(get: { selected }, set: { previewTime = $0 })) {
                        ForEach(moments, id: \.1) { label, date in Text(label).tag(date) }
                    }
                    PatientPreview(moment: moment(at: selected, snapshot), assets: store.assets)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    Text(soundDescription(moment(at: selected, snapshot)))
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("患者会看到")
                }
                if !issues.isEmpty {
                    Section("发布前检查") {
                        ForEach(issues) { issue in
                            Label(issue.message, systemImage: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .blocking ? Theme.bad : Theme.warn)
                        }
                    }
                }
                Section("这次的变化") {
                    let changes = ChangeSummary.lines(from: store.draft?.baseSnapshot, to: snapshot, zone: snapshot.timeZone)
                    if changes.isEmpty { Text("没有内容变化") }
                    ForEach(changes, id: \.self) { Text($0) }
                }
                Section {
                    Button {
                        Task {
                            publishing = true
                            await store.publishDraft()
                            publishing = false
                            dismiss()
                        }
                    } label: {
                        Text(publishing ? "正在发布…" : "确认并发布")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(blocking || publishing)
                    .accessibilityIdentifier("review.publish")
                } footer: {
                    Text(blocking ? "请先处理红色问题。" : "发布后会显示“本机已保存”“等待传送”或“设备已接收并应用”。设备应用只说明软件已更新，不代表患者已经知道。")
                }
            }
            .navigationTitle("预览并发布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回编辑") { dismiss() } } }
        }
    }

    private func moment(at date: Date, _ snapshot: FamilySnapshot) -> Moment {
        MomentResolver.resolve(MomentInput(snapshot: snapshot, now: date, availableAssets: store.assets.all,
                                           speechAvailable: AudioEnvironment.speechAvailable(language: snapshot.profile.languageCode)))
    }

    private func previewMoments(_ snapshot: FamilySnapshot) -> [(String, Date)] {
        let now = openedAt
        var result: [(String, Date)] = [("现在", now)]
        for event in snapshot.events where !event.isCancelled && event.showUntil > now {
            let at = max(event.showFrom, now)
            result.append(("「\(event.personName)」显示时", at.addingTimeInterval(at == now ? 1 : 60)))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = snapshot.timeZone
        let night = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(snapshot.night.startMinute * 60 + 30 * 60))
        result.append(("今晚夜间", night > now ? night : night.addingTimeInterval(86_400)))
        return result
    }

    private func soundDescription(_ moment: Moment) -> String {
        switch moment.audio {
        case let .recording(_, speaker)?: "点“听一听”会播放 \(speaker) 的录音。"
        case let .speech(text, _)?: "点“听一听”会用系统声音朗读：“\(text)”"
        case nil: moment.card == nil ? "只显示时间，没有声音。" : "没有可播放的声音，患者端不显示“听一听”。"
        }
    }
}

enum ChangeSummary {
    static func lines(from base: FamilySnapshot?, to new: FamilySnapshot, zone: TimeZone) -> [String] {
        guard let base else { return ["首次发布：\(new.profile.callName) 的屏幕内容和时段设置"] }
        var lines: [String] = []
        let old = Dictionary(base.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for event in new.events {
            guard let previous = old[event.id] else {
                lines.append("新增安排：\(event.line)（\(event.start.formatted(in: zone))）")
                continue
            }
            if event.isCancelled, !previous.isCancelled { lines.append("取消安排：\(previous.line)"); continue }
            if event != previous { lines.append("修改安排：\(event.line)（\(event.start.formatted(in: zone))）") }
        }
        if base.place != new.place { lines.append(new.place.enabled ? "地点提示：\(new.place.line)" : "关闭地点提示") }
        if base.display != new.display { lines.append("患者屏幕显示偏好已调整") }
        if base.voice != new.voice { lines.append(new.voice.systemSpeechFallback ? "开启系统朗读替代" : "声音偏好已调整") }
        if base.segments != new.segments || base.night != new.night { lines.append("时段或夜间设置已调整") }
        if base.profile != new.profile { lines.append("患者资料已修改") }
        return lines
    }
}
