import HereNowCore
import SwiftUI

/// Pairing on the patient device: enter code → confirm the family → caregiver approves → set PIN.
struct DisplayPairingView: View {
    @Environment(AppModel.self) private var model
    var role: DeviceRole = .display
    var onClose: () -> Void

    enum Step { case code, confirm(PairingPreview), waiting(PairingClaim), setPIN(DisplayCredential) }

    @State private var step: Step = .code
    @State private var code = ""
    @State private var deviceName = ""
    @State private var error: String?
    @State private var working = false
    @State private var claimSecret = UUID().uuidString + UUID().uuidString

    var body: some View {
        switch step {
        case let .setPIN(credential):
            PINSetupView {
                onClose()
                model.attachDisplay(credential)
            }
        default:
            NavigationStack {
                ZStack {
                    Theme.wallpaper
                    VStack(spacing: 20) {
                        HStack {
                            Text(role == .contributor ? "加入家庭" : "连接患者屏幕").font(.largeTitle.bold())
                            Spacer()
                            Button("取消", action: onClose).font(.headline)
                        }
                        .foregroundStyle(.white)
                        VStack(spacing: 24) {
                        content
                        if let error {
                            Text(error)
                                .font(.title3)
                                .foregroundStyle(Theme.bad)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("pair.error")
                        }
                        }
                        .padding(28)
                        .tile(cornerRadius: 32)
                    }
                    .padding(24)
                    .frame(maxWidth: 620)
                }
                .toolbar(.hidden, for: .navigationBar)
                .onAppear { if deviceName.isEmpty { deviceName = role == .contributor ? "" : AppModel.deviceName } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .code:
            VStack(spacing: 20) {
                Text(role == .contributor ? "请主要照护者在「设备」→「邀请家人提供录音或照片」生成邀请码，在这里输入。" : "在照护者手机上打开「设备」→「配对新的患者设备」，输入显示的 8 位配对码。")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                TextField("XXXX-XXXX", text: $code)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 20).fill(Theme.pageBase))
                    .accessibilityIdentifier("pair.code")
                primary(working ? "正在核对…" : "下一步", id: "pair.next", disabled: code.filter { $0.isLetter || $0.isNumber }.count != 8 || working) {
                    await preview()
                }
            }
        case let .confirm(preview):
            VStack(spacing: 20) {
                Text("加入「\(preview.familyName)」？").font(.largeTitle.bold()).accessibilityIdentifier("pair.familyName")
                Text(role == .contributor ? "邀请由「\(preview.initiatedBy)」发起。加入后你可以提交录音、照片和安排建议，但看不到家庭内容。" : "配对由「\(preview.initiatedBy)」发起。加入后，这台设备只会显示该家庭发布的内容。")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(role == .contributor ? "你的称呼（照护者会看到）" : "这台设备的名字").font(.headline)
                    TextField(role == .contributor ? "例如 小雨（女儿）" : "例如 客厅 iPad", text: $deviceName)
                        .font(.title3)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.pageBase))
                        .accessibilityIdentifier("pair.deviceName")
                }
                primary(working ? "正在发送…" : "确认加入", id: "pair.confirm", disabled: deviceName.isEmpty || working) {
                    await claim()
                }
                Button("不是这个家庭") { step = .code; code = "" }
            }
        case let .waiting(claim):
            VStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text("请在照护者手机上确认").font(.largeTitle.bold())
                Text("「\(claim.initiatedBy)」会看到「\(deviceName)」请求加入「\(claim.familyName)」。确认后这里会自动继续。")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .task(id: claim.claimId) { await poll(claim) }
        case .setPIN:
            EmptyView()
        }
    }

    private func primary(_ title: String, id: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 32).fill(Theme.accent.opacity(disabled ? 0.35 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    private func preview() async {
        working = true
        defer { working = false }
        do {
            let preview = try await model.api.previewPairing(code: code)
            guard (preview.role ?? .display) == role else {
                error = role == .contributor ? "这是患者设备的配对码，不是家人邀请码" : "这是家人邀请码，不能用来配对患者屏幕"
                return
            }
            step = .confirm(preview)
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
        }
    }

    private func claim() async {
        working = true
        defer { working = false }
        do {
            step = .waiting(try await model.api.claimPairing(code: code, installationID: Installation.id, deviceName: deviceName,
                                                             claimSecret: claimSecret))
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
        }
    }

    private func poll(_ claim: PairingClaim) async {
        while !Task.isCancelled {
            do {
                let status = try await model.api.claimStatus(claimID: claim.claimId, claimSecret: claimSecret)
                switch status.state {
                case "approved":
                    guard let token = status.token, let familyID = status.familyId, let deviceID = status.deviceId else {
                        error = "配对已确认，但凭据已失效。请在照护者手机上重新生成配对码。"
                        step = .code
                        return
                    }
                    if status.role == .contributor {
                        onClose()
                        model.attachContributor(ContributorCredential(familyID: familyID, deviceID: deviceID, token: token,
                                                                      familyName: status.familyName ?? claim.familyName, deviceName: deviceName))
                        return
                    }
                    step = .setPIN(DisplayCredential(familyID: familyID, deviceID: deviceID, token: token,
                                                     familyName: status.familyName ?? claim.familyName, deviceName: deviceName))
                    return
                case "rejected":
                    error = "照护者拒绝了这次配对"
                    step = .code
                    return
                case "expired":
                    error = "等待确认超时，请重新生成配对码"
                    step = .code
                    return
                default:
                    error = nil
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
