import HereNowCore
import Observation
import SwiftUI

struct ContributorCredential: Codable, Equatable {
    var familyID: String
    var deviceID: String
    var token: String
    var familyName: String
    var deviceName: String
}

/// A family member's phone: can send suggestions, sees only its own submissions and their status.
@MainActor
@Observable
final class ContributorStore {
    let credential: ContributorCredential
    private(set) var proposals: [Proposal] = []
    private(set) var problem: String?
    private(set) var sending = false
    var onRevoked: (() -> Void)?
    @ObservationIgnored let assets = AssetStore(name: "ContributorAssets")
    @ObservationIgnored private let api: ContributorSyncing

    init(credential: ContributorCredential, api: ContributorSyncing) {
        self.credential = credential
        self.api = api
    }

    func refresh() async {
        do {
            proposals = try await api.contributorState(token: credential.token).proposals
            problem = nil
        } catch let error as SyncError {
            if case .server(410, _) = error { signOut(); return }
            problem = error.errorDescription
        } catch {
            problem = error.localizedDescription
        }
    }

    func submit(kind: Proposal.Kind, payload: ProposalPayload, asset: String?) async -> Bool {
        sending = true
        defer { sending = false }
        do {
            if let asset, let data = assets.data(for: asset) {
                try await api.uploadAsset(token: credential.token, sha256: asset, data: data, mime: CaregiverStore.mime(of: data))
            }
            try await api.submitProposal(token: credential.token, kind: kind, payload: payload, assetRefs: asset.map { [$0] } ?? [])
            await refresh()
            return true
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func signOut() {
        assets.wipe()
        Keychain.delete("contributor")
        onRevoked?()
    }
}

struct ContributorHomeView: View {
    @Bindable var store: ContributorStore
    @State private var composing: Proposal.Kind?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("你可以给「\(store.credential.familyName)」的主要照护者提供录音、照片或安排建议。照护者决定是否使用，内容不会直接出现在患者屏幕上。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        action("mic.fill", "录一段话", .recording)
                        action("photo.fill", "选一张照片", .photo)
                        action("calendar.badge.plus", "建议安排", .event)
                    }
                    if let problem = store.problem { Text(problem).font(.footnote).foregroundStyle(Theme.bad) }
                    Text("我的提交").font(.headline).padding(.top, 8)
                    if store.proposals.isEmpty {
                        Text("还没有提交").foregroundStyle(.secondary)
                    }
                    ForEach(store.proposals) { proposal in
                        StatusTile(icon: icon(proposal.kind), tint: tint(proposal.state), title: label(proposal.kind),
                                   value: stateText(proposal.state),
                                   detail: proposal.payload.line ?? proposal.payload.note ?? proposal.payload.speakerLabel)
                    }
                }
                .padding(16)
            }
            .background(Theme.wallpaper)
            .navigationTitle(store.credential.familyName)
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .sheet(item: $composing) { ContributorComposeSheet(store: store, kind: $0) }
        }
    }

    private func action(_ icon: String, _ title: String, _ kind: Proposal.Kind) -> some View {
        Button { composing = kind } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Circle().fill(Theme.accentFill))
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("contributor.\(kind.rawValue)")
    }

    private func icon(_ kind: Proposal.Kind) -> String {
        switch kind { case .recording: "waveform"; case .photo: "photo"; case .event: "calendar" }
    }

    private func label(_ kind: Proposal.Kind) -> String {
        switch kind { case .recording: "录音"; case .photo: "照片"; case .event: "安排建议" }
    }

    private func stateText(_ state: String) -> String {
        switch state { case "accepted": "照护者已采用"; case "declined": "照护者未采用"; default: "等待照护者查看" }
    }

    private func tint(_ state: String) -> Color {
        switch state { case "accepted": Theme.ok; case "declined": .gray; default: Theme.warn }
    }
}

extension Proposal.Kind: Identifiable { var id: String { rawValue } }

struct ContributorComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ContributorStore
    var kind: Proposal.Kind
    @State private var recording: Recording?
    @State private var photo: String?
    @State private var payload = ProposalPayload()
    @State private var start = Date().addingTimeInterval(86_400)

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .recording:
                    Section {
                        RecordingField(recording: $recording, fingerprint: "contribution", assets: store.assets, defaultSpeaker: store.credential.deviceName)
                    } footer: {
                        Text("用平常对家人说话的语气，一次说一件事，不超过 30 秒。")
                    }
                case .photo:
                    Section { PhotoField(assetID: $photo, assets: store.assets) }
                case .event:
                    Section {
                        TextField("谁", text: Binding(get: { payload.personName ?? "" }, set: { payload.personName = $0 }))
                        DatePicker("计划时间", selection: $start)
                        TextField("想让患者看到的一句话", text: Binding(get: { payload.line ?? "" }, set: { payload.line = $0 }))
                    } footer: {
                        Text("时间按你的手机时区填写；照护者会按患者当地时间核对。")
                    }
                }
                Section("给照护者的说明（可选）") {
                    TextField("例如 这是给妈妈的早安问候", text: Binding(get: { payload.note ?? "" }, set: { payload.note = $0 }))
                }
                if let problem = store.problem { Text(problem).foregroundStyle(Theme.bad) }
            }
            .navigationTitle(kind == .event ? "建议安排" : (kind == .photo ? "提交照片" : "提交录音"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.sending ? "正在发送…" : "发送给照护者") {
                        Task {
                            var p = payload
                            var asset: String?
                            switch kind {
                            case .recording: asset = recording?.assetID; p.speakerLabel = recording?.speakerLabel
                            case .photo: asset = photo
                            case .event: p.start = start
                            }
                            if await store.submit(kind: kind, payload: p, asset: asset) { dismiss() }
                        }
                    }
                    .disabled(!ready || store.sending)
                    .accessibilityIdentifier("contributor.send")
                }
            }
        }
    }

    private var ready: Bool {
        switch kind {
        case .recording: recording != nil
        case .photo: photo != nil
        case .event: !(payload.personName ?? "").isEmpty && !(payload.line ?? "").isEmpty
        }
    }
}
