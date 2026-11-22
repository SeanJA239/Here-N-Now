import AVFoundation
import HereNowCore
import Observation

/// Plays at most one sound. A second tap stops it; interruptions stop it and never resume on their own.
@MainActor
@Observable
final class PlaybackController: NSObject {
    private(set) var playingCardIdentity: String?
    private(set) var playingAudioIdentity: String?
    var onBrokenAsset: ((String) -> Void)?
    /// Called when a sound starts and when it ends; `finished` is false when it was stopped or interrupted.
    var onStart: ((AudioSource) -> Void)?
    var onEnd: ((_ finished: Bool) -> Void)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var lastToggle = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var isPlaying: Bool { playingAudioIdentity != nil }

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    /// One tap: play when idle, stop when playing. Rapid repeat taps inside 0.35 s are ignored so they never stack.
    func toggle(audio: AudioSource, card: Card, assetURL: (String) -> URL) {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.35 else { return }
        lastToggle = now
        if isPlaying {
            stop()
            return
        }
        start(audio, card: card, assetURL: assetURL)
    }

    /// Starts a sound without a tap (scheduled greeting, comfort item). Never interrupts a sound already playing.
    func play(audio: AudioSource, card: Card, assetURL: (String) -> URL) {
        guard !isPlaying else { return }
        lastToggle = Date()
        start(audio, card: card, assetURL: assetURL)
    }

    func stop() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish(completed: false)
    }

    /// Stops a sound whose card is no longer the one on screen, e.g. after an event was cancelled or changed.
    func contentChanged(to moment: Moment) {
        guard let playingCardIdentity else { return }
        if moment.card?.identity != playingCardIdentity || moment.audio?.identity != playingAudioIdentity {
            stop()
        }
    }

    private func start(_ audio: AudioSource, card: Card, assetURL: (String) -> URL) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        switch audio {
        case let .recording(assetID, _):
            do {
                let player = try AVAudioPlayer(contentsOf: assetURL(assetID))
                player.delegate = self
                guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
                self.player = player
            } catch {
                onBrokenAsset?(assetID)
                return
            }
        case let .speech(text, language):
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
            synthesizer.speak(utterance)
        }
        playingCardIdentity = card.identity
        playingAudioIdentity = audio.identity
        onStart?(audio)
    }

    private func finish(completed: Bool) {
        let wasPlaying = playingAudioIdentity != nil
        playingCardIdentity = nil
        playingAudioIdentity = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if wasPlaying { onEnd?(completed) }
    }
}

extension PlaybackController: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { if self.player === player { self.player = nil; self.finish(completed: true) } }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated {
            if let id = self.playingAudioIdentity, id.hasPrefix("rec:") { self.onBrokenAsset?(String(id.dropFirst(4))) }
            self.player = nil
            self.finish(completed: false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { if self.player == nil { self.finish(completed: true) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { if self.player == nil, self.playingAudioIdentity?.hasPrefix("tts:") == true { self.finish(completed: false) } }
    }
}

enum AudioEnvironment {
    static func speechAvailable(language: String) -> Bool {
        AVSpeechSynthesisVoice(language: language) != nil
    }

    static var currentRoute: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "无输出设备" }
        return outputs.map { output -> String in
            switch output.portType {
            case .builtInSpeaker: "内置扬声器"
            case .builtInReceiver: "听筒"
            case .headphones: "有线耳机"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: "蓝牙：\(output.portName)"
            case .airPlay: "AirPlay：\(output.portName)"
            case .HDMI: "HDMI：\(output.portName)"
            default: output.portName
            }
        }.joined(separator: "、")
    }
}
