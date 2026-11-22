import HereNowCore
import SwiftUI

struct FamilySettingsView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: CaregiverStore
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var deleting = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("家庭") {
                    LabeledContent("名称", value: store.credential.familyName)
                    LabeledContent("内容版本", value: "第 \(store.currentVersion) 版")
                }
                Section {
                    Text("恢复码在创建家庭时显示过一次。换手机时，在新设备选择“用恢复码找回管理权”。")
                        .font(.subheadline)
                } header: {
                    Text("恢复")
                } footer: {
                    Text("首版不支持把管理权转交给他人。更换主要照护者时，请导出资料、删除家庭，再由新照护者重新建立。不要共享旧的恢复码。")
                }
                Section {
                    Button("准备导出文件") {
                        do { exportURL = try store.exportFile(); exportError = nil } catch { exportError = error.localizedDescription }
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("分享或存储导出文件", systemImage: "square.and.arrow.up") }
                    }
                    if let exportError { Text(exportError).foregroundStyle(Theme.bad) }
                } header: {
                    Text("导出")
                } footer: {
                    Text("包含已发布内容、未发布草稿、时间设置、照片和录音；不包含任何访问凭据。导出文件含家人照片和声音，请妥善保管。")
                }
                Section {
                    Button("退出这台设备的管理权", role: .destructive) { confirmSignOut = true }
                    if let error = store.actionError { Text(error).foregroundStyle(Theme.bad) }
                } footer: {
                    Text("只影响这台手机：家庭、已发布内容和患者设备照常工作。之后需要用恢复码才能重新管理。")
                }
                Section {
                    Button("删除家庭资料…", role: .destructive) { deleting = true }
                } footer: {
                    Text("删除整个家庭：内容、照片、录音和所有设备的访问。它和撤销单台设备、退出本机管理权是不同的操作。")
                }
                Section("使用边界") {
                    Text("此刻锚点只显示照护者确认过的提示，不提供诊断、用药、定位、报警或安全监测。应用不知道患者是否在屏幕前、是否读懂，也不知道来访者是否已到。")
                        .font(.footnote)
                }
            }
            .navigationTitle("家庭")
            .sheet(isPresented: $deleting) { DeleteFamilyView(store: store) }
            .confirmationDialog("退出这台设备的管理权？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出管理权", role: .destructive) { Task { _ = await store.signOutThisDevice() } }
            } message: {
                Text("请确认你已保存恢复码。")
            }
        }
    }
}

/// Lists everything affected before deleting, then reports each device's wipe state honestly.
struct DeleteFamilyView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CaregiverStore
    @State private var status: DeletionStatus?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let snapshot = store.publishedSnapshot ?? store.workingSnapshot
        NavigationStack {
            Form {
                if let status {
                    Section {
                        Text("家庭资料已从同步服务删除。").font(.headline)
                        ForEach(status.devices.filter { $0.role == "display" }) { device in
                            LabeledContent(device.name, value: device.wipeState == "confirmed" ? "已清除" : "待清除（设备离线）")
                        }
                    } footer: {
                        Text("离线设备联网后会自动清除。若一直离线，需要拿到设备手动解除配对；应用不能远程擦除离线设备。")
                    }
                    Button("刷新状态") { Task { self.status = try? await store.deletionStatus() } }
                    Button("完成并退出") { store.signOutLocally(reason: "家庭资料已删除") }
                } else {
                    Section("将被删除") {
                        Text("患者资料：\(snapshot.profile.callName)，时区 \(snapshot.profile.timeZoneID)")
                        Text("\(snapshot.events.count) 项安排（含已取消）")
                        Text("\(Set(snapshot.events.compactMap(\.photoAssetID) + [snapshot.place.photoAssetID].compactMap { $0 }).count) 张照片")
                        Text("\(snapshot.events.compactMap(\.recording).count + (snapshot.place.recording == nil ? 0 : 1)) 段录音")
                        Text("地点提示、时段和声音设置")
                    }
                    Section("将失去访问的设备") {
                        ForEach(store.family?.devices.filter(\.isActive) ?? []) { Text("\($0.name)（\($0.isDisplay ? "患者设备" : "管理设备")）") }
                    }
                    Section {
                        Button(working ? "正在删除…" : "永久删除家庭资料", role: .destructive) { Task { await delete() } }
                            .disabled(working)
                        if let error { Text(error).foregroundStyle(Theme.bad) }
                    } footer: {
                        Text("同步服务中的内容会立即删除；服务端备份的清除期限取决于部署方式，正式开放前需公布。建议先导出。")
                    }
                }
            }
            .navigationTitle("删除家庭资料")
            .toolbar { ToolbarItem(placement: .cancellationAction) { if status == nil { Button("取消") { dismiss() } } } }
            .interactiveDismissDisabled(status != nil)
        }
    }

    private func delete() async {
        working = true
        defer { working = false }
        do {
            status = try await store.deleteFamily()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
            store.start()
        }
    }
}
