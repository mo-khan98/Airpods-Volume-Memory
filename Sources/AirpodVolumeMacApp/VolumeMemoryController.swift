import Foundation

struct VolumeMemoryStatus {
    let menuBarTitle: String
    let primaryText: String
    let secondaryText: String
    let currentVolume: Float?
    let canAdjustVolume: Bool
}

final class VolumeMemoryController {
    var onStatusChanged: ((VolumeMemoryStatus) -> Void)?

    private let defaults: UserDefaults
    private let savedVolumeKeyPrefix = "savedOutputVolume."
    private let restoreDelay: TimeInterval = 1.0
    private let saveDebounceDelay: TimeInterval = 0.2
    private let reconnectAutoSaveDelay: TimeInterval = 120
    private let keyboardVolumeSteps: Float = 16

    private var defaultOutputListener: AudioPropertyListener?
    private var volumeListener: AudioPropertyListener?
    private var currentDevice: AudioDevice?
    private var pendingRestoreWorkItem: DispatchWorkItem?
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var suppressSavingUntil = Date.distantPast
    private var automaticSavingEnabledAt = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        do {
            defaultOutputListener = try AudioHardware.makeDefaultOutputDeviceListener { [weak self] in
                self?.defaultOutputDeviceChanged()
            }
            defaultOutputDeviceChanged()
        } catch {
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Could not start audio watcher.",
                secondary: error.localizedDescription,
                currentVolume: nil,
                canAdjustVolume: false
            )
        }
    }

    func stop() {
        pendingRestoreWorkItem?.cancel()
        pendingSaveWorkItem?.cancel()
        defaultOutputListener?.invalidate()
        volumeListener?.invalidate()
        defaultOutputListener = nil
        volumeListener = nil
    }

    func saveCurrentVolumeNow() {
        do {
            guard let device = try AudioHardware.defaultOutputDevice() else {
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "No output device is active.",
                    secondary: "Connect your AirPods and try again.",
                    currentVolume: nil,
                    canAdjustVolume: false
                )
                return
            }

            guard device.isAirPods else {
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "The current output is \(device.name).",
                    secondary: "This app only saves devices with AirPods in the name.",
                    currentVolume: nil,
                    canAdjustVolume: false
                )
                return
            }

            let volume = normalizedVolume(try AudioHardware.outputVolume(for: device))
            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "Saved current AirPods volume.")
        } catch {
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Could not save current volume.",
                secondary: error.localizedDescription,
                currentVolume: nil,
                canAdjustVolume: false
            )
        }
    }

    func setCurrentAirPodsVolume(_ volume: Float) {
        pendingRestoreWorkItem?.cancel()

        do {
            guard let device = try AudioHardware.defaultOutputDevice() else {
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "No output device is active.",
                    secondary: "Connect your AirPods and try again.",
                    currentVolume: nil,
                    canAdjustVolume: false
                )
                return
            }

            currentDevice = device

            guard device.isAirPods else {
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "The current output is \(device.name).",
                    secondary: "The menu slider only adjusts AirPods.",
                    currentVolume: nil,
                    canAdjustVolume: false
                )
                return
            }

            let clampedVolume = normalizedVolume(volume)
            try AudioHardware.setOutputVolume(clampedVolume, for: device)
            save(clampedVolume, for: device)
            suppressSaves(for: 0.5)
            automaticSavingEnabledAt = Date()
            publishTrackingStatus(for: device, currentVolume: clampedVolume, note: "Set and saved AirPods volume.")
        } catch {
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Could not set AirPods volume.",
                secondary: error.localizedDescription,
                currentVolume: nil,
                canAdjustVolume: false
            )
        }
    }

    private func defaultOutputDeviceChanged() {
        pendingRestoreWorkItem?.cancel()
        pendingSaveWorkItem?.cancel()
        volumeListener?.invalidate()
        volumeListener = nil

        do {
            guard let device = try AudioHardware.defaultOutputDevice() else {
                currentDevice = nil
                automaticSavingEnabledAt = Date.distantPast
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "No output device is active.",
                    secondary: "Connect your AirPods to start tracking.",
                    currentVolume: nil,
                    canAdjustVolume: false
                )
                return
            }

            currentDevice = device

            guard device.isAirPods else {
                automaticSavingEnabledAt = Date.distantPast
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "Current output: \(device.name)",
                    secondary: "Waiting for an AirPods output device.",
                    currentVolume: nil,
                    canAdjustVolume: false
                )
                return
            }

            installVolumeListener(for: device)
            let currentVolume = (try? AudioHardware.outputVolume(for: device)).map(normalizedVolume)

            if let savedVolume = savedVolume(for: device) {
                let rememberedVolume = normalizedVolume(savedVolume)
                suppressSaves(for: restoreDelay + reconnectAutoSaveDelay)
                automaticSavingEnabledAt = Date().addingTimeInterval(restoreDelay + reconnectAutoSaveDelay)
                publish(
                    menuBarTitle: "AirPods \(percent(rememberedVolume))",
                    primary: "Restoring \(device.name) to \(percent(rememberedVolume)).",
                    secondary: currentVolume.map { "Current system volume is \(percent($0))." } ?? "Waiting for volume controls.",
                    currentVolume: currentVolume ?? rememberedVolume,
                    canAdjustVolume: true
                )
                scheduleRestore(rememberedVolume, for: device)
            } else if let currentVolume {
                save(currentVolume, for: device)
                automaticSavingEnabledAt = Date().addingTimeInterval(reconnectAutoSaveDelay)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "Saved this as the first remembered volume."
                )
            } else {
                automaticSavingEnabledAt = Date().addingTimeInterval(reconnectAutoSaveDelay)
                publish(
                    menuBarTitle: "AirPods Vol",
                    primary: "Tracking \(device.name).",
                    secondary: "Set the AirPods volume once and the app will remember it.",
                    currentVolume: nil,
                    canAdjustVolume: true
                )
            }
        } catch {
            currentDevice = nil
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Could not read the current output device.",
                secondary: error.localizedDescription,
                currentVolume: nil,
                canAdjustVolume: false
            )
        }
    }

    private func installVolumeListener(for device: AudioDevice) {
        do {
            volumeListener = try AudioHardware.makeVolumeListener(for: device.id) { [weak self] in
                self?.volumeChanged()
            }
        } catch {
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Tracking \(device.name), but volume change watching is unavailable.",
                secondary: "Use Save Current Volume Now from the menu if automatic saving does not work.",
                currentVolume: nil,
                canAdjustVolume: true
            )
        }
    }

    private func scheduleRestore(_ volume: Float, for device: AudioDevice) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.restore(volume, for: device)
        }
        pendingRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: workItem)
    }

    private func restore(_ volume: Float, for device: AudioDevice) {
        guard currentDevice?.uid == device.uid else {
            return
        }

        do {
            let restoredVolume = normalizedVolume(volume)
            try AudioHardware.setOutputVolume(restoredVolume, for: device)
            publishTrackingStatus(for: device, currentVolume: restoredVolume, note: "Restored saved volume.")
        } catch {
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Could not restore \(device.name).",
                secondary: error.localizedDescription,
                currentVolume: nil,
                canAdjustVolume: true
            )
        }
    }

    private func volumeChanged() {
        pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.saveChangedVolumeIfNeeded()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceDelay, execute: workItem)
    }

    private func saveChangedVolumeIfNeeded() {
        guard let device = currentDevice, device.isAirPods else {
            return
        }

        do {
            let volume = normalizedVolume(try AudioHardware.outputVolume(for: device))
            let canSaveAutomatically = Date() >= suppressSavingUntil && Date() >= automaticSavingEnabledAt
            guard canSaveAutomatically else {
                publishObservedVolumeStatus(for: device, currentVolume: volume)
                return
            }

            if let savedVolume = savedVolume(for: device), abs(savedVolume - volume) < 0.0001 {
                publishTrackingStatus(for: device, currentVolume: volume, note: "AirPods volume is unchanged.")
                return
            }

            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "Saved new AirPods volume.")
        } catch {
            publish(
                menuBarTitle: "AirPods Vol",
                primary: "Could not save the changed AirPods volume.",
                secondary: error.localizedDescription,
                currentVolume: nil,
                canAdjustVolume: true
            )
        }
    }

    private func publishObservedVolumeStatus(for device: AudioDevice, currentVolume: Float) {
        publish(
            menuBarTitle: "AirPods \(percent(currentVolume))",
            primary: "Current \(device.name) volume: \(percent(currentVolume)).",
            secondary: "Use Save Current Volume Now to remember this level.",
            currentVolume: currentVolume,
            canAdjustVolume: true
        )
    }

    private func publishTrackingStatus(for device: AudioDevice, currentVolume: Float, note: String) {
        let saved = savedVolume(for: device) ?? currentVolume
        publish(
            menuBarTitle: "AirPods \(percent(saved))",
            primary: "\(note) \(device.name): \(percent(saved)).",
            secondary: "Disconnect and reconnect your AirPods to test restore.",
            currentVolume: currentVolume,
            canAdjustVolume: true
        )
    }

    private func suppressSaves(for seconds: TimeInterval) {
        suppressSavingUntil = Date().addingTimeInterval(seconds)
    }

    private func save(_ volume: Float, for device: AudioDevice) {
        defaults.set(Double(normalizedVolume(volume)), forKey: savedVolumeKey(for: device))
    }

    private func savedVolume(for device: AudioDevice) -> Float? {
        let key = savedVolumeKey(for: device)
        guard defaults.object(forKey: key) != nil else {
            return nil
        }

        return normalizedVolume(Float(defaults.double(forKey: key)))
    }

    private func savedVolumeKey(for device: AudioDevice) -> String {
        savedVolumeKeyPrefix + device.uid
    }

    private func publish(
        menuBarTitle: String,
        primary: String,
        secondary: String,
        currentVolume: Float?,
        canAdjustVolume: Bool
    ) {
        onStatusChanged?(
            VolumeMemoryStatus(
                menuBarTitle: menuBarTitle,
                primaryText: primary,
                secondaryText: secondary,
                currentVolume: currentVolume,
                canAdjustVolume: canAdjustVolume
            )
        )
    }

    private func percent(_ volume: Float) -> String {
        "\(Int((normalizedVolume(volume) * 100).rounded()))%"
    }

    private func normalizedVolume(_ volume: Float) -> Float {
        let clamped = min(max(volume, 0), 1)
        return (clamped * keyboardVolumeSteps).rounded() / keyboardVolumeSteps
    }
}
