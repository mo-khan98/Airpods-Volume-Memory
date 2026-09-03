import AppKit
import SwiftUI

final class DeviceManagerViewModel: ObservableObject {
    @Published private(set) var snapshot: VolumeMemoryDataSnapshot
    @Published private(set) var restoresPaused = false
    @Published private(set) var pauseSummary: String?
    @Published var automaticRestoreEnabled: Bool

    let preferences: AppPreferences
    private let controller: VolumeMemoryController

    init(controller: VolumeMemoryController, preferences: AppPreferences) {
        self.controller = controller
        self.preferences = preferences
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
        if window == nil {
            let rootView = DeviceManagerRootView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AirPods Volume"
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
                .tabItem { Label("Devices", systemImage: "airpodspro") }
            ConnectionHistoryView(viewModel: viewModel)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            PreferencesView(viewModel: viewModel, preferences: viewModel.preferences)
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
                Text("Remembered AirPods")
                    .font(.title2.weight(.semibold))
                Text("Each device keeps its own volume and restore preference.")
                    .foregroundStyle(.secondary)
            }

            if viewModel.snapshot.devices.isEmpty {
                EmptyStateView(
                    icon: "airpodspro",
                    title: "No remembered devices",
                    message: "Connect AirPods and set their volume to add them here."
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
        .alert("Forget this device?", isPresented: Binding(
            get: { deviceToForget != nil },
            set: { if !$0 { deviceToForget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deviceToForget = nil }
            Button("Forget", role: .destructive) {
                if let deviceToForget {
                    viewModel.forgetDevice(deviceToForget.uid)
                }
                deviceToForget = nil
            }
        } message: {
            Text("Its remembered volume will be removed. Connection history is kept.")
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
                            Text("CONNECTED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                    }
                    if let date = device.lastConnectedAt {
                        Text("Last connected \(date, style: .relative)")
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
                .help("Forget this device")
            }

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

            HStack {
                Toggle(
                    "Restore automatically for this device",
                    isOn: Binding(
                        get: { device.automaticRestoreEnabled },
                        set: { viewModel.setAutomaticRestore($0, for: device.uid) }
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if let restored = device.lastRestoredVolume {
                    Text("Last restored to \(Int((restored * 100).rounded()))%")
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
                    Text("Connection History")
                        .font(.title2.weight(.semibold))
                    Text("The most recent 100 AirPods connections are kept locally.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear History", role: .destructive) { confirmsClear = true }
                    .disabled(viewModel.snapshot.history.isEmpty)
            }

            if viewModel.snapshot.history.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No connection history",
                    message: "Connections and restore results will appear here."
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
        .alert("Clear connection history?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { viewModel.clearHistory() }
        } message: {
            Text("Remembered devices and volumes will not be affected.")
        }
    }

    private func historyDescription(_ entry: AirPodsConnectionHistoryEntry) -> String {
        let connected = entry.connectedVolume.map { "Connected at \(Int(($0 * 100).rounded()))%" }
            ?? "Connected volume unavailable"
        switch entry.outcome {
        case .restored:
            let restored = entry.restoredVolume.map { "\(Int(($0 * 100).rounded()))%" } ?? "an unknown level"
            return "\(connected)  →  restored to \(restored)"
        case .failed: return "\(connected)  →  restore did not stick"
        case .paused: return "\(connected)  →  skipped while paused"
        case .automaticRestoreOff: return "\(connected)  →  automatic restore was off"
        case .noRememberedVolume: return "\(connected)  →  saved as the initial level"
        case .pending: return "\(connected)  →  restore in progress"
        }
    }

    private func historyIcon(_ outcome: RestoreHistoryOutcome) -> String {
        switch outcome {
        case .restored: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .pending: return "arrow.triangle.2.circlepath"
        case .automaticRestoreOff, .noRememberedVolume: return "minus.circle.fill"
        }
    }

    private func historyColor(_ outcome: RestoreHistoryOutcome) -> Color {
        switch outcome {
        case .restored: return .green
        case .failed: return .orange
        case .pending: return .accentColor
        case .paused, .automaticRestoreOff, .noRememberedVolume: return .secondary
        }
    }
}

private struct PreferencesView: View {
    @ObservedObject var viewModel: DeviceManagerViewModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Restoration") {
                Toggle(
                    "Restore automatically when AirPods connect",
                    isOn: Binding(
                        get: { viewModel.automaticRestoreEnabled },
                        set: { viewModel.setGlobalAutomaticRestore($0) }
                    )
                )

                LabeledContent("Temporary pause") {
                    if viewModel.restoresPaused {
                        HStack {
                            Text(viewModel.pauseSummary ?? "Paused").foregroundStyle(.secondary)
                            Button("Resume") { viewModel.resume() }
                        }
                    } else {
                        Menu("Pause…") {
                            Button("For 15 Minutes") { viewModel.pause(for: 15 * 60) }
                            Button("For 1 Hour") { viewModel.pause(for: 60 * 60) }
                            Button("Until Resumed") { viewModel.pause(for: nil) }
                        }
                    }
                }
            }

            Section("Appearance") {
                Picker("Menu bar display", selection: $preferences.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Notifications") {
                Picker("Restore notifications", selection: $preferences.restoreNotificationMode) {
                    ForEach(RestoreNotificationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Notifications are sent only after the final restore verification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Device memory and connection history stay on this Mac. Nothing is uploaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
