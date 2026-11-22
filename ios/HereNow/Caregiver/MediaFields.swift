import AVFoundation
import HereNowCore
import PhotosUI
import SwiftUI

/// One photo, picked through the system picker so the app never needs access to the whole library.
struct PhotoField: View {
    @Binding var assetID: String?
    var assets: AssetStore
    @State private var item: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 14) {
            if let assetID, let image = ImageCache.image(at: assets.url(for: assetID), key: assetID) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(selection: $item, matching: .images) {
                    Text(assetID == nil ? "选择一张照片" : "更换照片")
                }
                if assetID != nil {
                    Button("移除照片", role: .destructive) { assetID = nil }
                }
            }
        }
        if let error { Text(error).foregroundStyle(Theme.bad) }
        Text("请选择患者熟悉的真实人物或场景，并确认照片中的人同意这样使用。").font(.footnote).foregroundStyle(.secondary)
            .onChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task { await load(newItem) }
            }
    }

    private func load(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                error = "无法读取这张照片"
                return
            }
            let resized = image.downscaled(maxSide: 1200)
            guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return }
            assetID = try assets.store(jpeg)
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "照片保存失败"
        }
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

@MainActor
@Observable
final class RecorderModel: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum Phase: Equatable { case idle, recording(started: Date), recorded(URL, Double), playing }

    var phase: Phase = .idle
    var message: String?
    var permission: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.delegate = self
            guard recorder.record(forDuration: Retention.maxRecordingSeconds) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            phase = .recording(started: Date())
            message = nil
        } catch {
            message = "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stop() { recorder?.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        MainActor.assumeIsolated {
            let duration = (try? AVAudioPlayer(contentsOf: recorder.url))?.duration ?? 0
            if case let .recording(started) = phase, Date().timeIntervalSince(started) >= Retention.maxRecordingSeconds - 0.5 {
                message = "已到 30 秒上限，录音在这里停止。请试听，如果话没说完请重录一段更短的。"
            }
            phase = flag ? .recorded(recorder.url, duration.isFinite ? duration : 0) : .idle
            if !flag { message = "录音没有成功，请重试" }
            self.recorder = nil
        }
    }

    @ObservationIgnored private var phaseAfterPlaying: Phase = .idle

    func play(_ url: URL, returningTo next: Phase) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        phaseAfterPlaying = next
        if player?.play() == true { phase = .playing } else { message = "这段录音无法播放" }
    }

    func stopPlaying() {
        player?.stop()
        finishPlaying()
    }

    private func finishPlaying() {
        player = nil
        if case .playing = phase { phase = phaseAfterPlaying }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { finishPlaying() }
    }
}

/// Record, preview, re-record, delete, and confirm a family recording. Identity of the speaker is only a label.
struct RecordingField: View {
    @Binding var recording: Recording?
    var fingerprint: String
    var assets: AssetStore
    var defaultSpeaker: String
    @State private var recorder = RecorderModel()
    @State private var explaining = false
    @State private var speaker = ""

    var body: some View {
        Group {
            if let recording {
                existing(recording)
            } else {
                newRecording
            }
            if let message = recorder.message { Text(message).foregroundStyle(Theme.warn) }
        }
        .alert("使用麦克风录一段家人的话", isPresented: $explaining) {
            Button("继续") { Task { if await recorder.requestPermission() { recorder.start() } } }
            Button("暂不", role: .cancel) {}
        } message: {
            Text("录音用于让患者听到家人真实的声音。只在你按下录音时使用麦克风，最长 30 秒。不录音也能完整使用文字。")
        }
    }

    @ViewBuilder
    private func existing(_ value: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("录音人：\(value.speakerLabel)", systemImage: "waveform")
            Text("录制于 \(value.recordedAt.formatted(in: .current)) · \(Int(value.durationSeconds.rounded())) 秒")
                .font(.footnote).foregroundStyle(.secondary)
            Text("录音人由你标注，应用不验证身份。").font(.footnote).foregroundStyle(.secondary)
        }
        if value.confirmedFingerprint != fingerprint {
            VStack(alignment: .leading, spacing: 8) {
                Label("内容已修改，这段录音待复核", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("复核或重录前，患者端不会播放它。").font(.footnote)
                Button("试听后确认：录音内容与现在一致") {
                    recording?.confirmedFingerprint = fingerprint
                }
            }
        }
        if recorder.phase == .playing {
            Button("停止试听") { recorder.stopPlaying() }
        } else {
            Button("试听") { recorder.play(assets.url(for: value.assetID), returningTo: .idle) }
        }
        Button("重录") { recording = nil; startFlow() }
        Button("删除录音", role: .destructive) { recording = nil }
    }

    @ViewBuilder
    private var newRecording: some View {
        switch recorder.phase {
        case .idle:
            Button { startFlow() } label: { Label("录一段家人的话（最多 30 秒）", systemImage: "mic.fill") }
                .accessibilityIdentifier("recording.start")
            if recorder.permission == .denied {
                Text("麦克风权限已关闭。可以在“设置”中开启；不录音也能完整管理文字。").font(.footnote).foregroundStyle(Theme.warn)
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case let .recording(started):
            TimelineView(.periodic(from: started, by: 1)) { context in
                Label("正在录音 \(Int(context.date.timeIntervalSince(started))) / 30 秒", systemImage: "record.circle")
                    .foregroundStyle(Theme.bad)
            }
            Button("停止录音") { recorder.stop() }.accessibilityIdentifier("recording.stop")
        case let .recorded(url, duration):
            Button("试听") { recorder.play(url, returningTo: .recorded(url, duration)) }
            TextField("录音人，例如 小雨（女儿）", text: $speaker).onAppear { if speaker.isEmpty { speaker = defaultSpeaker } }
            Button("使用这段录音") { keep(url, duration: duration) }
                .disabled(speaker.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("重录") { recorder.phase = .idle; startFlow() }
        case .playing:
            Button("停止试听") { recorder.stopPlaying() }
        }
    }

    private func startFlow() {
        switch recorder.permission {
        case .granted: recorder.start()
        case .denied: recorder.message = "麦克风权限已关闭，可以在“设置”中开启"
        default: explaining = true
        }
    }

    private func keep(_ url: URL, duration: Double) {
        do {
            let data = try Data(contentsOf: url)
            let sha = try assets.store(data)
            recording = Recording(assetID: sha, speakerLabel: speaker, recordedAt: Date(), durationSeconds: duration,
                                  confirmedFingerprint: fingerprint)
            recorder.phase = .idle
            try? FileManager.default.removeItem(at: url)
        } catch {
            recorder.message = (error as? LocalizedError)?.errorDescription ?? "录音保存失败"
        }
    }
}
