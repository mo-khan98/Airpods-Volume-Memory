import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private let detailMenuItem = NSMenuItem(title: "Watching audio devices.", action: nil, keyEquivalent: "")
    private let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volumeValueLabel = NSTextField(labelWithString: "--")
    private lazy var restoreNowItem = makeMenuItem(
        title: "Restore Remembered Volume",
        action: #selector(restoreRememberedVolumeNow),
        keyEquivalent: "r"
    )
    private lazy var saveNowItem = makeMenuItem(
        title: "Save Current Volume",
        action: #selector(saveCurrentVolumeNow),
        keyEquivalent: "s"
    )
    private lazy var forgetVolumeItem = makeMenuItem(
        title: "Forget Remembered Volume",
        action: #selector(forgetRememberedVolume)
    )
    private lazy var automaticRestoreItem = makeMenuItem(
        title: "Restore Automatically",
        action: #selector(toggleAutomaticRestore)
    )
    private lazy var launchAtLoginItem = makeMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin)
    )
    private let controller = VolumeMemoryController()
    private var isRenderingStatus = false
    private var wakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        configureStatusItem()
        configureMenu()

        controller.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.render(status)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller.handleSystemWake()
        }
        controller.start()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func stop() {
        controller.stop()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "AirPods Vol"
        statusItem.button?.toolTip = "AirPods Volume Memory"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        statusMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.isContinuous = true
        volumeSlider.numberOfTickMarks = 17
        volumeSlider.allowsTickMarkValuesOnly = true

        let quitItem = NSMenuItem(
            title: "Quit AirPods Volume",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(detailMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeVolumeSliderItem())
        menu.addItem(.separator())
        menu.addItem(restoreNowItem)
        menu.addItem(saveNowItem)
        menu.addItem(forgetVolumeItem)
        menu.addItem(.separator())
        menu.addItem(automaticRestoreItem)
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refresh()
        updateLaunchAtLoginState()
    }

    private func makeVolumeSliderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        let titleLabel = NSTextField(labelWithString: "AirPods volume")
        let menuItem = NSMenuItem()

        [titleLabel, volumeSlider, volumeValueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        volumeValueLabel.alignment = .right
        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            volumeValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            volumeValueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            volumeValueLabel.widthAnchor.constraint(equalToConstant: 42),

            volumeSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            volumeSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            volumeSlider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])

        menuItem.view = container
        return menuItem
    }

    private func render(_ status: VolumeMemoryStatus) {
        isRenderingStatus = true
        defer { isRenderingStatus = false }

        statusItem.button?.title = status.menuBarTitle
        statusMenuItem.title = status.primaryText
        detailMenuItem.title = status.secondaryText

        if let currentVolume = status.currentVolume {
            let percent = Int((min(max(currentVolume, 0), 1) * 100).rounded())
            volumeSlider.doubleValue = Double(percent)
            volumeValueLabel.stringValue = "\(percent)%"
        } else {
            volumeSlider.doubleValue = 0
            volumeValueLabel.stringValue = "--"
        }

        volumeSlider.isEnabled = status.canAdjustVolume
        saveNowItem.isEnabled = status.canAdjustVolume
        restoreNowItem.isEnabled = status.canAdjustVolume && status.hasRememberedVolume
        forgetVolumeItem.isEnabled = status.canAdjustVolume && status.hasRememberedVolume
        automaticRestoreItem.state = status.automaticRestoreEnabled ? .on : .off
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

    @objc private func saveCurrentVolumeNow() {
        controller.saveCurrentVolumeNow()
    }

    @objc private func restoreRememberedVolumeNow() {
        controller.restoreRememberedVolumeNow()
    }

    @objc private func forgetRememberedVolume() {
        controller.forgetRememberedVolume()
    }

    @objc private func toggleAutomaticRestore() {
        controller.setAutomaticRestoreEnabled(!controller.automaticRestoreEnabled)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
            updateLaunchAtLoginState()
        } catch {
            showLaunchAtLoginError(error)
        }
    }

    private func updateLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.state = .on
            launchAtLoginItem.toolTip = nil
        case .requiresApproval:
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.toolTip = "Approval is required in System Settings > General > Login Items."
        default:
            launchAtLoginItem.state = .off
            launchAtLoginItem.toolTip = nil
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Change Launch at Login"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func volumeSliderChanged() {
        guard !isRenderingStatus else {
            return
        }

        controller.setCurrentAirPodsVolume(Float(volumeSlider.doubleValue / 100))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
