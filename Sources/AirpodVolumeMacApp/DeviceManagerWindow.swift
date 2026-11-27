import AppKit
import SwiftUI

final class DeviceManagerViewModel: ObservableObject {
    @Published private(set) var snapshot: VolumeMemoryDataSnapshot
    @Published private(set) var restoresPaused = false
    @Published private(set) var pauseSummary: String?
    @Published private(set) var accessibilityTrusted = AccessibilityAccess.isTrusted
    @Published var automaticRestoreEnabled: Bool
    @Published private(set) var fixedRestoreEnabled = false
    @Published private(set) var fixedRestorePercent = 15

    let preferences: AppPreferences
    let loginItems: LoginItemController
    private let controller: VolumeMemoryController

    init(controller: VolumeMemoryController, preferences: AppPreferences, loginItems: LoginItemController) {
        self.controller = controller
        self.preferences = preferences
        self.loginItems = loginItems
        snapshot = controller.dataSnapshot()
        automaticRestoreEnabled = controller.automaticRestoreEnabled
        refreshRuntimeState()
    }

    func receive(_ snapshot: VolumeMemoryDataSnapshot) {
        self.snapshot = snapshot
        refreshRuntimeState()
    }

    func refreshRuntimeState() {
        restoresPaused = controller.restoresPaused
        pauseSummary = controller.pauseDescription
        automaticRestoreEnabled = controller.automaticRestoreEnabled
        accessibilityTrusted = AccessibilityAccess.isTrusted
        fixedRestoreEnabled = controller.fixedRestoreEnabled
        fixedRestorePercent = controller.fixedRestorePercent
    }

    func setFixedRestore(enabled: Bool, percent: Int) {
        controller.setFixedRestore(enabled: enabled, percent: percent)
        refreshRuntimeState()
    }

    /// launchctl runs in the background, so this is only done when Settings is shown.
    func refreshLoginState() {
        loginItems.refreshInBackground {}
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItems.refresh()
        // A failure is kept in loginItems.lastError and shown under the switch.
        try? loginItems.setEnabled(enabled)
    }

    func finishLoginMigration() {
        loginItems.prepareLegacyMigration()
        if loginItems.state.requiresApproval { loginItems.openSettings() }
    }

    func setRememberedVolume(_ volume: Double, for deviceUID: String) {
        controller.updateRememberedVolume(for: deviceUID, volume: Float(volume))
    }

    func setAutomaticRestore(_ enabled: Bool, for deviceUID: String) {
        controller.setAutomaticRestore(enabled, for: deviceUID)
    }

    func setGlobalAutomaticRestore(_ enabled: Bool) {
        controller.setAutomaticRestoreEnabled(enabled)
        refreshRuntimeState()
    }

    func forgetDevice(_ deviceUID: String) {
        controller.forgetDevice(deviceUID)
    }

    func clearHistory() {
        controller.clearConnectionHistory()
    }

    func pause(for duration: TimeInterval?) {
        controller.pauseRestores(for: duration)
        refreshRuntimeState()
    }

    func resume() {
        controller.resumeRestores()
        refreshRuntimeState()
    }
}

final class DeviceManagerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel: DeviceManagerViewModel

    init(viewModel: DeviceManagerViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        viewModel.refreshRuntimeState()
        viewModel.refreshLoginState()
        if window == nil {
            let rootView = DeviceManagerRootView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AirPods 音量"
            window.setContentSize(NSSize(width: 720, height: 520))
            window.minSize = NSSize(width: 620, height: 440)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.center()
            window.delegate = self
            window.isReleasedWhenClosed = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }
}

private struct DeviceManagerRootView: View {
    @ObservedObject var viewModel: DeviceManagerViewModel

    var body: some View {
        TabView {
            DevicesView(viewModel: viewModel)
                .tabItem { Label("设备", systemImage: "airpodspro") }
            ConnectionHistoryView(viewModel: viewModel)
                .tabItem { Label("历史记录", systemImage: "clock.arrow.circlepath") }
            PreferencesView(viewModel: viewModel, preferences: viewModel.preferences, loginItems: viewModel.loginItems)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
    }
}

private struct DevicesView: View {
    @ObservedObject var viewModel: DeviceManagerViewModel
    @State private var deviceToForget: RememberedAirPods?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("已记忆的 AirPods")
                    .font(.title2.weight(.semibold))
                Text("每台设备分别保存音量和自动恢复设置。")
                    .foregroundStyle(.secondary)
            }

            if viewModel.snapshot.devices.isEmpty {
                EmptyStateView(
                    icon: "airpodspro",
                    title: "暂无记忆设备",
                    message: "连接 AirPods 并调整音量，即可添加设备。"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.snapshot.devices) { device in
                            deviceCard(device)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .alert("忘记这台设备？", isPresented: Binding(
            get: { deviceToForget != nil },
            set: { if !$0 { deviceToForget = nil } }
        )) {
            Button("取消", role: .cancel) { deviceToForget = nil }
            Button("忘记", role: .destructive) {
                if let deviceToForget {
                    viewModel.forgetDevice(deviceToForget.uid)
                }
                deviceToForget = nil
            }
        } message: {
            Text("将删除该设备的记忆音量，连接记录仍会保留。")
        }
    }

    private func deviceCard(_ device: RememberedAirPods) -> some View {
        let isConnected = viewModel.snapshot.currentDeviceUID == device.uid
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "airpodspro")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.name).font(.headline)
                        if isConnected {
                            Text("已连接")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                    }
                    if let date = device.lastConnectedAt {
                        Text("上次连接：\(date, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    deviceToForget = device
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("忘记此设备")
            }

            if viewModel.fixedRestoreEnabled {
                Text("固定恢复到 \(viewModel.fixedRestorePercent)%")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(device.rememberedVolume) },
                            set: { viewModel.setRememberedVolume($0, for: device.uid) }
                        ),
                        in: 0...1,
                        step: 0.01
                    )
                    Text("\(Int((device.rememberedVolume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }

            HStack {
                Toggle(
                    "自动恢复此设备的音量",
                    isOn: Binding(
                        get: { device.automaticRestoreEnabled },
                        set: { viewModel.setAutomaticRestore($0, for: device.uid) }
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if let restored = device.lastRestoredVolume {
                    Text("上次恢复至：\(Int((restored * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ConnectionHistoryView: View {
    @ObservedObject var viewModel: DeviceManagerViewModel
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接记录")
                        .font(.title2.weight(.semibold))
                    Text("最近 100 条 AirPods 连接记录保存在本机。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空记录", role: .destructive) { confirmsClear = true }
                    .disabled(viewModel.snapshot.history.isEmpty)
            }

            if viewModel.snapshot.history.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "暂无连接记录",
                    message: "连接记录和音量恢复结果会显示在这里。"
                )
            } else {
                List(viewModel.snapshot.history) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: historyIcon(entry.outcome))
                            .foregroundStyle(historyColor(entry.outcome))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.deviceName).font(.headline)
                            Text(historyDescription(entry))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.connectedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.connectedAt, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .alert("清空连接记录？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { viewModel.clearHistory() }
        } message: {
            Text("不会影响已记忆的设备和音量。")
        }
    }

    private func historyDescription(_ entry: AirPodsConnectionHistoryEntry) -> String {
        let connected = entry.connectedVolume.map { "连接时音量：\(Int(($0 * 100).rounded()))%" }
            ?? "无法读取连接时的音量"
        switch entry.outcome {
        case .restored:
            let restored = entry.restoredVolume.map { "\(Int(($0 * 100).rounded()))%" } ?? "未知音量"
            return "\(connected)  →  已恢复至 \(restored)"
        case .failed: return "\(connected)  →  恢复未生效"
        case .paused: return "\(connected)  →  暂停期间跳过"
        case .automaticRestoreOff: return "\(connected)  →  自动恢复已关闭"
        case .noRememberedVolume: return "\(connected)  →  已保存为初始音量"
        case .pending: return "\(connected)  →  正在恢复音量"
        case .interrupted: return "\(connected)  →  恢复被中断"
        }
    }

    private func historyIcon(_ outcome: RestoreHistoryOutcome) -> String {
        switch outcome {
        case .restored: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .pending: return "arrow.triangle.2.circlepath"
        case .automaticRestoreOff, .noRememberedVolume: return "minus.circle.fill"
        case .interrupted: return "xmark.circle.fill"
        }
    }

    private func historyColor(_ outcome: RestoreHistoryOutcome) -> Color {
        switch outcome {
        case .restored: return .green
        case .failed: return .orange
        case .pending: return .accentColor
        case .paused, .automaticRestoreOff, .noRememberedVolume, .interrupted: return .secondary
        }
    }
}

private struct PreferencesView: View {
    @ObservedObject var viewModel: DeviceManagerViewModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var loginItems: LoginItemController

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机时自动启动", isOn: Binding(
                    get: { loginItems.state.isEnabled },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                if loginItems.state.requiresApproval {
                    HStack {
                        Label("需要在系统设置的“登录项”里允许", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开系统设置") { loginItems.openSettings() }
                    }
                } else if loginItems.state.legacyEnabled {
                    HStack {
                        Text("正在使用旧版的启动方式")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("改用系统登录项") { viewModel.finishLoginMigration() }
                    }
                }
                if let error = loginItems.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("音量恢复") {
                Toggle(
                    "连接 AirPods 时自动恢复音量",
                    isOn: Binding(
                        get: { viewModel.automaticRestoreEnabled },
                        set: { viewModel.setGlobalAutomaticRestore($0) }
                    )
                )

                Toggle("固定恢复音量", isOn: Binding(
                    get: { viewModel.fixedRestoreEnabled },
                    set: { viewModel.setFixedRestore(enabled: $0, percent: viewModel.fixedRestorePercent) }
                ))
                if viewModel.fixedRestoreEnabled {
                    LabeledContent("固定音量") {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(viewModel.fixedRestorePercent) },
                                set: { viewModel.setFixedRestore(enabled: true, percent: Int($0.rounded())) }
                            ), in: 0...100, step: 1)
                            Text("\(viewModel.fixedRestorePercent)%").monospacedDigit()
                        }
                    }
                    Text("下次连接时应用。连接后仍可手动调节本次音量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("临时暂停") {
                    if viewModel.restoresPaused {
                        HStack {
                            Text(viewModel.pauseSummary ?? "已暂停").foregroundStyle(.secondary)
                            Button("恢复") { viewModel.resume() }
                        }
                    } else {
                        Menu("暂停…") {
                            Button("暂停 15 分钟") { viewModel.pause(for: 15 * 60) }
                            Button("暂停 1 小时") { viewModel.pause(for: 60 * 60) }
                            Button("暂停直到手动恢复") { viewModel.pause(for: nil) }
                        }
                    }
                }
            }

            Section("耳机切换") {
                Toggle("iPhone-Mac 切换修复", isOn: $preferences.fixSilentSwitchEnabled)
                if preferences.fixSilentSwitchEnabled && !viewModel.accessibilityTrusted {
                    HStack {
                        Label("需要辅助功能权限", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开系统设置") {
                            AccessibilityAccess.request()
                            AccessibilityAccess.openSettings()
                        }
                    }
                }
                Text("默认关闭。耳机连着 iPhone 时在 Mac 上点播放，部分播放器（如“音乐”）可能切过来后没声音。开启后，应用会在耳机切换的瞬间自动按一次暂停再播放，开头会晚约半秒出声。没有遇到这个问题就不需要开启。开启后需要在“系统设置 > 隐私与安全性 > 辅助功能”中允许本应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外观") {
                Picker("菜单栏显示", selection: $preferences.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("高音量提醒") {
                Toggle("超过阈值时提醒", isOn: $preferences.highVolumeWarningEnabled)
                HStack {
                    Text("提醒阈值")
                    Slider(value: $preferences.highVolumeThreshold, in: 1...100, step: 1)
                        .disabled(!preferences.highVolumeWarningEnabled)
                    Text("\(Int(preferences.highVolumeThreshold))%")
                        .monospacedDigit()
                        .frame(width: 44)
                }
                Text("仅对识别到的 AirPods 和苹果蓝牙耳机提醒。超过阈值时提醒一次，降低至阈值以内后可再次触发。请在系统设置中允许本应用发送通知。音量百分比并非实际声压级。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                Toggle("连接 AirPods 后通知恢复结果", isOn: $preferences.connectionNotificationEnabled)
                Picker("音量恢复通知", selection: $preferences.restoreNotificationMode) {
                    ForEach(RestoreNotificationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("自动恢复成功或最终失败时发送一次通知。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私") {
                Text("设备记忆和连接记录仅保存在这台 Mac 上，不会上传。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshRuntimeState()
            viewModel.refreshLoginState()
        }
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
