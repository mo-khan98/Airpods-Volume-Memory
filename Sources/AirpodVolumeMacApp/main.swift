import AppKit

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

final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private let detailMenuItem = NSMenuItem(title: "Watching audio devices.", action: nil, keyEquivalent: "")
    private let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volumeValueLabel = NSTextField(labelWithString: "--")
    private let controller = VolumeMemoryController()
    private var isRenderingStatus = false

    override init() {
        super.init()
        configureStatusItem()
        configureMenu()

        controller.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.render(status)
            }
        }
        controller.start()
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
        statusMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.isContinuous = true

        let saveNowItem = NSMenuItem(
            title: "Save Current Volume Now",
            action: #selector(saveCurrentVolumeNow),
            keyEquivalent: "s"
        )
        saveNowItem.target = self

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
        menu.addItem(saveNowItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
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
    }

    @objc private func saveCurrentVolumeNow() {
        controller.saveCurrentVolumeNow()
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
