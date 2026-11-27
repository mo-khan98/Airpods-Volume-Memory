import AppKit
import AVFAudio
import OSLog
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showWindowNotification,
            object: String(getuid()), queue: .main
        ) { [weak self] _ in self?.statusBarController?.showDeviceManager() }
        if CommandLine.arguments.contains("--show-settings") {
            statusBarController?.showDeviceManager()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBarController?.showDeviceManager()
        return true
    }
}

private final class ReconnectButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if !isEnabled {
            fill = .quaternaryLabelColor
        } else if cell?.isHighlighted == true {
            fill = NSColor(srgbRed: 0.10, green: 0.25, blue: 0.63, alpha: 1)
        } else {
            fill = NSColor(srgbRed: 0.15, green: 0.34, blue: 0.78, alpha: 1)
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        super.draw(dirtyRect)
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let titleLabel = NSTextField(labelWithString: "正在启动…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volumeValueLabel = NSTextField(labelWithString: "--")
    private let loginItems = LoginItemController()
    private let controller = VolumeMemoryController()
    private let preferences = AppPreferences()
    private let notificationManager = RestoreNotificationManager()
    private let stallMonitor = PlaybackStallMonitor()
    private let volumeKeyMonitor = VolumeKeyMonitor()
    private let handoffMonitor = AirPodsHandoffMonitor()
    private var isArbitratingAudioRoute = false
    private var reconnectOutput: SilentAudioOutput?
    private let reconnectLogger = Logger(subsystem: "com.akhan.AirpodVolumeMacApp", category: "Reconnect")
    private lazy var volumeKeyPermissionItem = makeMenuItem(
        title: "启用键盘音量修复…", action: #selector(enableVolumeKeyFix)
    )
    private lazy var deviceManagerViewModel = DeviceManagerViewModel(
        controller: controller,
        preferences: preferences,
        loginItems: loginItems
    )
    private lazy var deviceManagerWindowController = DeviceManagerWindowController(
        viewModel: deviceManagerViewModel
    )
    private lazy var settingsItem = makeMenuItem(
        title: "设置…",
        action: #selector(showDeviceManager),
        keyEquivalent: ","
    )
    private let menuWidth: CGFloat = 300
    private let connectionMessageItem = NSMenuItem()
    private var connectionRows: [(
        device: PairedHeadphones, item: NSMenuItem, status: NSTextField, button: ReconnectButton
    )] = []
    private var connectionTimer: Timer?
    private var connectingAddress: String?
    private var connectionMessage: String?
    private var isRenderingStatus = false
    private var wakeObserver: NSObjectProtocol?
    private var highVolumeWarningGate = HighVolumeWarningGate()
    private var lastStatus: VolumeMemoryStatus?
    private var lastMuted = false
    private lazy var menuBarIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirPods 音量")
        image?.isTemplate = true
        return image
    }()

    override init() {
        super.init()
        configureStatusItem()
        configureMenu()
        loginItems.prepareLegacyMigration()

        controller.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.render(status)
            }
        }
        controller.onDataChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.deviceManagerViewModel.receive(snapshot)
            }
        }
        controller.onRestoreNotification = { [weak self] event in
            guard let self else { return }
            // The connection notification already reports this result.
            if event.isConnectionRestore && self.preferences.connectionNotificationEnabled { return }
            let mode = self.preferences.restoreNotificationMode
            let threshold = event.succeeded && mode == .allResults
                ? self.restoreWarningThreshold(volume: event.volume, muted: self.outputIsMuted) : nil
            self.notificationManager.deliver(event, mode: mode, warningThreshold: threshold)
        }
        controller.onConnectionNotification = { [weak self] event in
            guard let self, self.preferences.connectionNotificationEnabled else { return }
            let muted = self.outputIsMuted
            let threshold = event.outcome == .restored
                ? self.restoreWarningThreshold(volume: event.volume, muted: muted) : nil
            self.notificationManager.deliverConnection(event, muted: muted, warningThreshold: threshold)
        }
        preferences.onMenuBarDisplayModeChanged = { [weak self] in
            guard let self, let status = self.lastStatus else { return }
            self.renderMenuBar(status, volumeOnIPhone: self.volumeOnIPhone)
        }
        preferences.onRestoreNotificationModeChanged = { [weak self] mode in
            self?.notificationManager.modeChanged(mode)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller.handleSystemWake()
        }
        preferences.onHighVolumeWarningChanged = { [weak self] in
            guard let self else { return }
            if self.preferences.highVolumeWarningEnabled {
                self.notificationManager.requestAuthorization()
            }
            self.highVolumeWarningGate = HighVolumeWarningGate()
            if let status = self.lastStatus { self.checkHighVolume(status) }
        }
        preferences.onConnectionNotificationChanged = { [weak self] in
            guard let self, self.preferences.connectionNotificationEnabled else { return }
            self.notificationManager.requestAuthorization()
        }
        if preferences.anyNotificationEnabled {
            notificationManager.requestAuthorization()
        }
        stallMonitor.isEnabled = { [weak self] in self?.preferences.fixSilentSwitchEnabled ?? false }
        preferences.onFixSilentSwitchChanged = { [weak self] in
            guard let self else { return }
            self.updateStallMonitor()
            if self.preferences.fixSilentSwitchEnabled && !AccessibilityAccess.isTrusted {
                AccessibilityAccess.request()
            }
            self.deviceManagerViewModel.refreshRuntimeState()
        }
        updateStallMonitor()
        controller.start()
        volumeKeyMonitor.onAdjustment = { [weak self] increase, fine in
            self?.controller.handleVolumeKey(increase: increase, fine: fine)
        }
        volumeKeyMonitor.onMute = { [weak self] in self?.controller.handleMuteKey() }
        volumeKeyMonitor.start()
        handoffMonitor.onChange = { [weak self] in
            guard let self else { return }
            self.refreshConnectionRows()
            if self.volumeOnIPhone, let status = self.lastStatus {
                self.render(status)
            }
            self.controller.refresh()
        }
        handoffMonitor.start()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func stop() {
        connectionTimer?.invalidate()
        volumeKeyMonitor.stop()
        handoffMonitor.stop()
        leaveAudioRouteArbitration()
        stallMonitor.stop()
        controller.stop()
    }

    /// The iPhone-Mac switch fix only listens to the device while it is turned on.
    private func updateStallMonitor() {
        if preferences.fixSilentSwitchEnabled {
            stallMonitor.start()
        } else {
            stallMonitor.stop()
        }
    }

    private func configureStatusItem() {
        statusItem.button?.title = "AirPods Vol"
        statusItem.button?.toolTip = "AirPods 音量记忆"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.isContinuous = true

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(makeHeaderItem())
        menu.addItem(.separator())
        menu.addItem(connectionMessageItem)
        menu.addItem(.separator())
        menu.addItem(volumeKeyPermissionItem)
        volumeKeyPermissionItem.isHidden = true
        menu.addItem(settingsItem)
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        handoffMonitor.start()
        volumeKeyMonitor.start()
        volumeKeyPermissionItem.isHidden = volumeKeyMonitor.isListening
        controller.refresh()
        deviceManagerViewModel.refreshRuntimeState()
        rebuildConnectionRows()
        connectionTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshConnectionRows()
            self?.controller.refresh()
        }
        connectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func enableVolumeKeyFix() {
        if !CGRequestListenEventAccess() {
            guard let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
            NSWorkspace.shared.open(settings)
        }
        volumeKeyMonitor.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        connectionTimer?.invalidate()
        connectionTimer = nil
    }

    private func rebuildConnectionRows() {
        for row in connectionRows {
            menu.removeItem(row.item)
        }
        let devices = PairedHeadphones.devices(
            remembered: controller.dataSnapshot().devices,
            currentOutput: try? AudioHardware.defaultOutputDevice()
        )
        connectionRows = devices.map { device in
            let name = NSTextField(labelWithString: device.name)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = device.name

            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 12)
            status.lineBreakMode = .byTruncatingTail

            let button = ReconnectButton(title: "连回 Mac", target: self, action: #selector(reconnectAirPods(_:)))
            button.isBordered = false
            button.alignment = .center

            let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 95))
            for view in [name, status, button] {
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
            }
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                name.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                name.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                status.trailingAnchor.constraint(equalTo: name.trailingAnchor),
                status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
                button.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: name.trailingAnchor),
                button.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
                button.heightAnchor.constraint(equalToConstant: 38)
            ])

            let item = NSMenuItem()
            item.view = container
            menu.insertItem(item, at: menu.index(of: connectionMessageItem))
            return (device, item, status, button)
        }
        refreshConnectionRows()
    }

    private func refreshConnectionRows() {
        let output = try? AudioHardware.defaultOutputDevice()
        for row in connectionRows {
            let selectedOutput = output.flatMap { row.device.matchesOutput($0) ? $0 : nil }
            let connected = row.device.isConnected
            let hasMacAudio = connected && (selectedOutput ?? row.device.audioOutput()).map {
                AudioHardware.anyProcessOutputting(on: $0.id) == true
            } == true
            let owner = handoffMonitor.owner(for: row.device.address)
            let switchedToIPhone = owner == .iPhone
            let macOwnsAudio = connected && !switchedToIPhone && (owner == .mac || hasMacAudio)
            let sourceUnconfirmed = connected && selectedOutput != nil && !macOwnsAudio
            let connecting = connectingAddress == row.device.address
            let status: String
            if connecting {
                status = "正在连回 Mac…"
            } else if switchedToIPhone {
                status = "已切换到 iPhone"
            } else if macOwnsAudio {
                status = hasMacAudio ? "检测到 Mac 音频输出" : "Mac 已取得耳机音频控制权"
            } else if !connected {
                status = "未连接 Mac · 可能在手机或其他设备上"
            } else if sourceUnconfirmed {
                status = "播放设备未确认 · Mac 蓝牙在线"
            } else {
                status = "已连 Mac 蓝牙 · 未选为声音输出"
            }
            row.status.stringValue = status
            row.status.textColor = macOwnsAudio ? .systemGreen : .secondaryLabelColor

            let title: String
            if connecting {
                title = "正在连接…"
            } else if switchedToIPhone {
                title = "连回 Mac"
            } else if macOwnsAudio {
                title = "已连接 Mac"
            } else if sourceUnconfirmed {
                title = "连回 Mac"
            } else {
                title = connected ? "切换到 Mac 输出" : "连回 Mac"
            }
            row.button.isEnabled = connectingAddress == nil && !macOwnsAudio
            row.button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: row.button.isEnabled ? NSColor.white : NSColor.secondaryLabelColor
            ])
            row.button.setAccessibilityLabel("\(title)，\(row.device.name)")
        }

        if connectionRows.isEmpty {
            connectionMessageItem.title = output?.isAirPods == true
                ? "AirPods 播放设备未确认"
                : "未找到已配对的耳机"
        } else {
            connectionMessageItem.title = connectionMessage ?? ""
        }
        connectionMessageItem.isHidden = !connectionRows.isEmpty && connectionMessage == nil
    }

    @objc private func reconnectAirPods(_ sender: NSButton) {
        guard sender.isEnabled, connectingAddress == nil,
              let device = connectionRows.first(where: { $0.button === sender })?.device else { return }
        connectingAddress = device.address
        reconnectLogger.notice("Reconnect requested")
        connectionMessage = nil
        refreshConnectionRows()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = device.connect()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if connected {
                    self.requestAirPodsOutput(device)
                } else {
                    self.finishReconnect(message: "连回 Mac 失败，请确认耳机在附近、Mac 蓝牙已打开后重试")
                }
            }
        }
    }

    private func requestAirPodsOutput(_ device: PairedHeadphones) {
        let owner = handoffMonitor.owner(for: device.address)
        let selectedAirPods = (try? AudioHardware.defaultOutputDevice()).map {
            $0.isAirPods && device.matchesOutput($0)
        } ?? false
        if owner == .iPhone || (owner == nil && selectedAirPods) {
            // The default output can still be a virtual AirPods route owned by the phone.
            isArbitratingAudioRoute = true
            AVAudioRoutingArbiter.shared.begin(category: .playback) { [weak self] changedOutput, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connectingAddress == device.address else { return }
                    self.reconnectLogger.notice("Route arbitration finished, changed output: \(changedOutput), error: \(error != nil)")
                }
            }
        }
        selectAirPodsOutput(device, attemptsRemaining: 32)
    }

    private func leaveAudioRouteArbitration() {
        reconnectOutput = nil
        guard isArbitratingAudioRoute else { return }
        isArbitratingAudioRoute = false
        AVAudioRoutingArbiter.shared.leave()
    }

    private func selectAirPodsOutput(_ device: PairedHeadphones, attemptsRemaining: Int) {
        guard connectingAddress == device.address else { return }
        if !isArbitratingAudioRoute || handoffMonitor.owner(for: device.address) == .mac,
           device.isConnected, let output = try? AudioHardware.defaultOutputDevice(), device.matchesOutput(output) {
            finishReconnect(message: nil)
            return
        }
        // The audio output can appear several seconds after Bluetooth connects.
        guard attemptsRemaining > 0 else {
            finishReconnect(message: "未能切换声音输出，请在 Mac 的「声音」设置中重试")
            return
        }
        if let output = device.audioOutput() {
            if (try? AudioHardware.defaultOutputDevice())?.id != output.id {
                try? AudioHardware.setDefaultOutputDevice(output)
            }
            if isArbitratingAudioRoute, reconnectOutput == nil {
                do {
                    reconnectOutput = try SilentAudioOutput(device: output)
                    reconnectLogger.notice("Silent AirPods output started")
                } catch {
                    reconnectLogger.error("Silent AirPods output could not start: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.selectAirPodsOutput(device, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func finishReconnect(message: String?) {
        reconnectLogger.notice("Reconnect completed, confirmed output: \(message == nil)")
        leaveAudioRouteArbitration()
        connectingAddress = nil
        connectionMessage = message
        controller.refresh()
        refreshConnectionRows()
    }

    /// Device name, what happens to its volume, and the volume slider in one block.
    private func makeHeaderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 74))
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        volumeValueLabel.alignment = .right
        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        [titleLabel, detailLabel].forEach { $0.lineBreakMode = .byTruncatingTail }

        [titleLabel, detailLabel, volumeSlider, volumeValueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            volumeSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeValueLabel.leadingAnchor, constant: -8),
            volumeSlider.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),

            volumeValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            volumeValueLabel.centerYAnchor.constraint(equalTo: volumeSlider.centerYAnchor),
            volumeValueLabel.widthAnchor.constraint(equalToConstant: 42)
        ])

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private var outputIsMuted: Bool {
        guard let device = try? AudioHardware.defaultOutputDevice() else { return false }
        return AudioHardware.outputMuted(for: device.id)
    }

    private var volumeOnIPhone: Bool {
        guard let uid = controller.currentAirPodsUID else { return false }
        if let address = PairedHeadphones.addressInUID(uid) {
            return handoffMonitor.owner(for: address) == .iPhone
        }
        guard let output = try? AudioHardware.defaultOutputDevice(), output.uid == uid,
              let row = connectionRows.first(where: { $0.device.matchesOutput(output) }) else { return false }
        return handoffMonitor.owner(for: row.device.address) == .iPhone
    }

    private func render(_ status: VolumeMemoryStatus) {
        isRenderingStatus = true
        defer { isRenderingStatus = false }
        lastStatus = status
        let volumeOnIPhone = self.volumeOnIPhone
        let muted = !volumeOnIPhone && status.canAdjustVolume && outputIsMuted
        lastMuted = muted

        checkHighVolume(status)
        renderMenuBar(status, volumeOnIPhone: volumeOnIPhone)
        let lines = MenuStatusText.lines(for: status, muted: muted)
        titleLabel.stringValue = lines.title
        detailLabel.stringValue = volumeOnIPhone ? "请在 iPhone 上调节音量" : lines.detail

        if !volumeOnIPhone, let currentVolume = status.currentVolume {
            let percent = Int((min(max(currentVolume, 0), 1) * 100).rounded())
            volumeSlider.doubleValue = Double(percent)
            volumeValueLabel.stringValue = muted ? "静音" : "\(percent)%"
        } else {
            volumeSlider.doubleValue = 0
            volumeValueLabel.stringValue = "—"
        }

        volumeSlider.isEnabled = !volumeOnIPhone && status.canAdjustVolume
        deviceManagerViewModel.refreshRuntimeState()
    }

    private func restoreWarningThreshold(volume: Float?, muted: Bool) -> Double? {
        let threshold = preferences.highVolumeThreshold
        guard preferences.highVolumeWarningEnabled, !muted, let volume,
              NotificationText.exceedsWarningThreshold(volume, threshold: threshold) else { return nil }
        // This result banner already includes the warning for this crossing.
        _ = highVolumeWarningGate.shouldWarn(
            deviceUID: controller.currentAirPodsUID, volume: volume, enabled: true, threshold: threshold
        )
        return threshold
    }

    private func checkHighVolume(_ status: VolumeMemoryStatus) {
        // Reconnect volume is often briefly high before the restore lands. Leave the
        // gate untouched; the settled status that follows is checked normally.
        guard !status.isSettling, !volumeOnIPhone else { return }
        let uid = status.canAdjustVolume ? controller.currentAirPodsUID : nil
        if highVolumeWarningGate.shouldWarn(
            deviceUID: uid,
            volume: status.currentVolume,
            enabled: preferences.highVolumeWarningEnabled && !lastMuted,
            threshold: preferences.highVolumeThreshold
        ), let volume = status.currentVolume {
            notificationManager.deliverHighVolumeWarning(
                deviceName: status.currentDeviceName ?? "AirPods",
                volume: volume,
                threshold: Int(preferences.highVolumeThreshold.rounded())
            )
        }
    }

    private func renderMenuBar(_ status: VolumeMemoryStatus, volumeOnIPhone: Bool) {
        guard let button = statusItem.button else { return }
        let muted = !volumeOnIPhone && lastMuted
        let percent = volumeOnIPhone ? nil : status.currentVolume.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        let icon = menuBarIcon

        switch preferences.menuBarDisplayMode {
        case .iconOnly:
            button.image = icon
            button.title = ""
        case .iconAndPercentage:
            button.image = icon
            button.title = muted ? " 静音" : (percent.map { " \($0)%" } ?? "")
        case .compactText:
            button.image = nil
            button.title = volumeOnIPhone ? "AirPods · iPhone"
                : (muted && status.canAdjustVolume ? "AirPods 静音" : status.menuBarTitle)
        case .deviceName:
            button.image = nil
            if volumeOnIPhone {
                button.title = "\(status.currentDeviceName ?? "AirPods") · iPhone"
            } else if let name = status.currentDeviceName, let percent {
                button.title = muted ? "\(name) 静音" : "\(name) \(percent)%"
            } else {
                button.title = "AirPods Vol"
            }
        }
        button.toolTip = volumeOnIPhone ? "已切换到 iPhone，请在 iPhone 上调节音量"
            : (muted ? "当前已静音" : status.primaryText)
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc func showDeviceManager() {
        deviceManagerWindowController.show()
    }

    @objc private func volumeSliderChanged() {
        guard !isRenderingStatus, !volumeOnIPhone else {
            return
        }

        // Whole percents: fine enough to set any level, and what the label shows.
        let percent = volumeSlider.doubleValue.rounded()
        volumeSlider.doubleValue = percent
        volumeValueLabel.stringValue = "\(Int(percent))%"
        controller.setCurrentAirPodsVolume(Float(percent / 100))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// Installer commands run before AppKit and the process lock. They never create
// a second menu-bar item and preserve the original bundle identifier/storage.
if CommandLine.arguments.contains("--login-item-status") {
    print(SystemLoginStartupBackend().snapshot().nativeStatus.rawValue)
    exit(0)
}
if CommandLine.arguments.contains("--prepare-login-migration") {
    let startup = LoginItemController()
    startup.prepareLegacyMigration()
    if let error = startup.lastError { fputs("\(error)\n", stderr) }
    print(startup.state.nativeStatus.rawValue)
    exit(0)
}

let instance: SingleInstance
do {
    instance = try SingleInstance(lockURL: SingleInstance.defaultLockURL)
    if try !instance.acquire() {
        // The first process may still be bringing up AppKit during simultaneous
        // launches. Retry the wake-up briefly without creating another UI.
        for _ in 0..<3 {
            DistributedNotificationCenter.default().postNotificationName(
                SingleInstance.showWindowNotification, object: String(getuid()),
                userInfo: nil, deliverImmediately: true
            )
            Thread.sleep(forTimeInterval: 0.2)
        }
        exit(0)
    }
} catch {
    fputs("无法取得应用进程锁：\(error.localizedDescription)\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(instance) { app.run() }
