import Foundation

struct VolumeMemoryStatus {
    let menuBarTitle: String
    let primaryText: String
    let secondaryText: String
    let currentVolume: Float?
    let canAdjustVolume: Bool
    let hasRememberedVolume: Bool
    let automaticRestoreEnabled: Bool
}

struct VolumeMemoryConfiguration {
    var restoreAttemptDelays: [TimeInterval] = [0.75, 2.25, 5.0]
    var restoreCompletionGrace: TimeInterval = 1.0
    var saveDebounceDelay: TimeInterval = 0.2
}

protocol VolumeMemoryScheduledTask: AnyObject {
    func cancel()
}

protocol VolumeMemoryScheduling {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> VolumeMemoryScheduledTask
}

extension DispatchWorkItem: VolumeMemoryScheduledTask {}

struct MainQueueVolumeMemoryScheduler: VolumeMemoryScheduling {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> VolumeMemoryScheduledTask {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return workItem
    }
}

final class VolumeMemoryController {
    var onStatusChanged: ((VolumeMemoryStatus) -> Void)?

    private let defaults: UserDefaults
    private let audioHardware: AudioHardwareControlling
    private let scheduler: VolumeMemoryScheduling
    private let configuration: VolumeMemoryConfiguration
    private let savedVolumeKeyPrefix = "savedOutputVolume."
    private let automaticRestoreEnabledKey = "automaticRestoreEnabled"

    private var defaultOutputListener: AudioPropertyListening?
    private var volumeListener: AudioPropertyListening?
    private var currentDevice: AudioDevice?
    private var pendingRestoreTasks: [VolumeMemoryScheduledTask] = []
    private var pendingSaveTask: VolumeMemoryScheduledTask?
    private var restoreTarget: Float?
    private var isRestoreInProgress = false

    init(
        defaults: UserDefaults = .standard,
        audioHardware: AudioHardwareControlling = SystemAudioHardware(),
        scheduler: VolumeMemoryScheduling = MainQueueVolumeMemoryScheduler(),
        configuration: VolumeMemoryConfiguration = VolumeMemoryConfiguration()
    ) {
        self.defaults = defaults
        self.audioHardware = audioHardware
        self.scheduler = scheduler
        self.configuration = configuration
    }

    var automaticRestoreEnabled: Bool {
        guard defaults.object(forKey: automaticRestoreEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: automaticRestoreEnabledKey)
    }

    func start() {
        stop()

        do {
            defaultOutputListener = try audioHardware.makeDefaultOutputDeviceListener { [weak self] in
                // A Bluetooth reconnect can reuse the same CoreAudio ID and UID. A real
                // default-output notification must therefore rebuild listeners and restore.
                self?.reconcileDefaultOutputDevice(force: true)
            }
            reconcileDefaultOutputDevice(force: true)
        } catch {
            publishError(
                primary: "Could not start the audio watcher.",
                error: error,
                canAdjustVolume: false
            )
        }
    }

    func stop() {
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        defaultOutputListener?.invalidate()
        volumeListener?.invalidate()
        defaultOutputListener = nil
        volumeListener = nil
        currentDevice = nil
    }

    func refresh() {
        reconcileDefaultOutputDevice(force: false)
    }

    func handleSystemWake() {
        reconcileDefaultOutputDevice(force: true)
    }

    func setAutomaticRestoreEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: automaticRestoreEnabledKey)

        guard let device = currentDevice, device.isAirPods else {
            publishWaitingForAirPods()
            return
        }

        if enabled, let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            cancelRestore()
            publishCurrentStatus(for: device, note: "Automatic restore is off.")
        }
    }

    func saveCurrentVolumeNow() {
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            guard let device = try activeAirPods() else {
                return
            }

            currentDevice = device
            let volume = normalizedVolume(try audioHardware.outputVolume(for: device))
            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "Saved current volume.")
        } catch {
            publishError(primary: "Could not save the current volume.", error: error)
        }
    }

    func restoreRememberedVolumeNow() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            guard let device = try activeAirPods() else {
                return
            }

            currentDevice = device
            guard let rememberedVolume = savedVolume(for: device) else {
                publishCurrentStatus(for: device, note: "No remembered volume yet. Save one first.")
                return
            }

            beginRestore(rememberedVolume, for: device, manuallyRequested: true)
        } catch {
            publishError(primary: "Could not restore the remembered volume.", error: error)
        }
    }

    func forgetRememberedVolume() {
        cancelRestore()

        do {
            guard let device = try activeAirPods() else {
                return
            }
            defaults.removeObject(forKey: savedVolumeKey(for: device))
            publishCurrentStatus(for: device, note: "Forgot the remembered volume.")
        } catch {
            publishError(primary: "Could not forget the remembered volume.", error: error)
        }
    }

    func setCurrentAirPodsVolume(_ volume: Float) {
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            guard let device = try activeAirPods() else {
                return
            }

            currentDevice = device
            let clampedVolume = normalizedVolume(volume)
            try audioHardware.setOutputVolume(clampedVolume, for: device)
            save(clampedVolume, for: device)
            publishTrackingStatus(for: device, currentVolume: clampedVolume, note: "Set and saved volume.")
        } catch {
            publishError(primary: "Could not set the AirPods volume.", error: error)
        }
    }

    private func reconcileDefaultOutputDevice(force: Bool) {
        do {
            let device = try audioHardware.defaultOutputDevice()
            if !force, sameEndpoint(device, currentDevice) {
                if let device {
                    if device.isAirPods {
                        publishCurrentStatus(
                            for: device,
                            note: isRestoreInProgress ? "Stabilizing the remembered volume…" : nil
                        )
                    } else {
                        publishWaitingForAirPods()
                    }
                } else {
                    publishNoOutputDevice()
                }
                return
            }

            outputDeviceChanged(to: device)
        } catch {
            currentDevice = nil
            publishError(
                primary: "Could not read the current output device.",
                error: error,
                canAdjustVolume: false
            )
        }
    }

    private func outputDeviceChanged(to device: AudioDevice?) {
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        volumeListener?.invalidate()
        volumeListener = nil
        currentDevice = device

        guard let device else {
            publishNoOutputDevice()
            return
        }

        guard device.isAirPods else {
            publishWaitingForAirPods()
            return
        }

        installVolumeListener(for: device)
        let currentVolume = try? normalizedVolume(audioHardware.outputVolume(for: device))

        if let rememberedVolume = savedVolume(for: device) {
            if automaticRestoreEnabled {
                beginRestore(rememberedVolume, for: device, manuallyRequested: false)
            } else {
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "Connected; automatic restore is off."
                )
            }
        } else if let currentVolume {
            save(currentVolume, for: device)
            publishTrackingStatus(
                for: device,
                currentVolume: currentVolume,
                note: "Saved this device's initial volume."
            )
        } else {
            publish(
                primary: "Tracking \(device.name).",
                secondary: "Set its volume once and the app will remember it.",
                currentVolume: nil,
                canAdjustVolume: true,
                hasRememberedVolume: false
            )
        }
    }

    private func installVolumeListener(for device: AudioDevice) {
        guard volumeListener == nil else {
            return
        }

        volumeListener = try? audioHardware.makeVolumeListener(for: device.id) { [weak self] in
            self?.volumeChanged()
        }
    }

    private func beginRestore(_ volume: Float, for device: AudioDevice, manuallyRequested: Bool) {
        cancelRestore()
        restoreTarget = normalizedVolume(volume)
        isRestoreInProgress = true

        let delays = configuration.restoreAttemptDelays.isEmpty ? [0] : configuration.restoreAttemptDelays
        for (index, delay) in delays.enumerated() {
            pendingRestoreTasks.append(
                scheduler.schedule(after: max(0, delay)) { [weak self] in
                    self?.performRestoreAttempt(index: index, totalAttempts: delays.count, for: device)
                }
            )
        }

        let completionDelay = max(0, delays.max() ?? 0) + configuration.restoreCompletionGrace
        pendingRestoreTasks.append(
            scheduler.schedule(after: completionDelay) { [weak self] in
                self?.finishRestore(for: device)
            }
        )

        let target = restoreTarget ?? volume
        publish(
            primary: "Restoring \(device.name) to \(percent(target)).",
            secondary: manuallyRequested
                ? "Applying and verifying the remembered volume."
                : "Bluetooth audio is settling; the app will verify the result.",
            currentVolume: try? normalizedVolume(audioHardware.outputVolume(for: device)),
            canAdjustVolume: true,
            hasRememberedVolume: true
        )
    }

    private func performRestoreAttempt(index: Int, totalAttempts: Int, for device: AudioDevice) {
        guard isCurrentEndpoint(device), let target = restoreTarget else {
            return
        }

        installVolumeListener(for: device)

        do {
            try audioHardware.setOutputVolume(target, for: device)
            let observed = try? normalizedVolume(audioHardware.outputVolume(for: device))
            publish(
                primary: "Restoring \(device.name) to \(percent(target)).",
                secondary: "Verification pass \(index + 1) of \(totalAttempts).",
                currentVolume: observed ?? target,
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
        } catch {
            let willRetry = index + 1 < totalAttempts
            publish(
                primary: willRetry ? "AirPods are still becoming ready." : "The last restore attempt failed.",
                secondary: willRetry ? "The app will retry automatically." : error.localizedDescription,
                currentVolume: try? normalizedVolume(audioHardware.outputVolume(for: device)),
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
        }
    }

    private func finishRestore(for device: AudioDevice) {
        guard isCurrentEndpoint(device), let target = restoreTarget else {
            return
        }

        isRestoreInProgress = false
        restoreTarget = nil
        pendingRestoreTasks.removeAll()

        do {
            let currentVolume = normalizedVolume(try audioHardware.outputVolume(for: device))
            if volumesMatch(currentVolume, target) {
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "Restored and verified the remembered volume."
                )
            } else {
                publish(
                    primary: "The remembered volume did not stick.",
                    secondary: "Choose Restore Remembered Volume to try again.",
                    currentVolume: currentVolume,
                    canAdjustVolume: true,
                    hasRememberedVolume: true
                )
            }
        } catch {
            publishError(primary: "Could not verify the restored volume.", error: error)
        }
    }

    private func cancelRestore() {
        pendingRestoreTasks.forEach { $0.cancel() }
        pendingRestoreTasks.removeAll()
        restoreTarget = nil
        isRestoreInProgress = false
    }

    private func volumeChanged() {
        pendingSaveTask?.cancel()
        pendingSaveTask = scheduler.schedule(after: configuration.saveDebounceDelay) { [weak self] in
            self?.saveChangedVolumeIfNeeded()
        }
    }

    private func saveChangedVolumeIfNeeded() {
        pendingSaveTask = nil
        guard let device = currentDevice, device.isAirPods else {
            return
        }

        do {
            let volume = normalizedVolume(try audioHardware.outputVolume(for: device))
            guard !isRestoreInProgress else {
                publish(
                    primary: "Stabilizing \(device.name) at \(percent(restoreTarget ?? volume)).",
                    secondary: "Temporary reconnect changes will not replace the remembered volume.",
                    currentVolume: volume,
                    canAdjustVolume: true,
                    hasRememberedVolume: savedVolume(for: device) != nil
                )
                return
            }

            if let saved = savedVolume(for: device), volumesMatch(saved, volume) {
                publishTrackingStatus(for: device, currentVolume: volume, note: "Volume is up to date.")
                return
            }

            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "Saved the new volume.")
        } catch {
            publishError(primary: "Could not save the changed volume.", error: error)
        }
    }

    private func publishCurrentStatus(for device: AudioDevice, note: String?) {
        let currentVolume = try? normalizedVolume(audioHardware.outputVolume(for: device))
        publishTrackingStatus(for: device, currentVolume: currentVolume, note: note)
    }

    private func publishTrackingStatus(for device: AudioDevice, currentVolume: Float?, note: String?) {
        let saved = savedVolume(for: device)
        let displayed = currentVolume ?? saved
        publish(
            primary: note ?? "Tracking \(device.name).",
            secondary: saved.map { "Remembered for next connection: \(percent($0))." }
                ?? "Adjust the volume to create a remembered value.",
            currentVolume: displayed,
            canAdjustVolume: true,
            hasRememberedVolume: saved != nil
        )
    }

    private func activeAirPods() throws -> AudioDevice? {
        guard let device = try audioHardware.defaultOutputDevice() else {
            volumeListener?.invalidate()
            volumeListener = nil
            currentDevice = nil
            publishNoOutputDevice()
            return nil
        }

        guard device.isAirPods else {
            volumeListener?.invalidate()
            volumeListener = nil
            currentDevice = device
            publishWaitingForAirPods()
            return nil
        }

        if !sameEndpoint(device, currentDevice) {
            volumeListener?.invalidate()
            volumeListener = nil
            currentDevice = device
            installVolumeListener(for: device)
        }

        return device
    }

    private func publishNoOutputDevice() {
        publish(
            primary: "No output device is active.",
            secondary: "Connect your AirPods to start tracking.",
            currentVolume: nil,
            canAdjustVolume: false,
            hasRememberedVolume: false
        )
    }

    private func publishWaitingForAirPods() {
        let deviceName = currentDevice?.name
        publish(
            primary: deviceName.map { "Current output: \($0)" } ?? "Waiting for AirPods.",
            secondary: "AirPods and Apple Bluetooth headphones are detected automatically.",
            currentVolume: nil,
            canAdjustVolume: false,
            hasRememberedVolume: false
        )
    }

    private func publishError(
        primary: String,
        error: Error,
        canAdjustVolume: Bool = true
    ) {
        let hasRememberedVolume = currentDevice.flatMap(savedVolume(for:)) != nil
        publish(
            primary: primary,
            secondary: error.localizedDescription,
            currentVolume: nil,
            canAdjustVolume: canAdjustVolume,
            hasRememberedVolume: hasRememberedVolume
        )
    }

    private func publish(
        primary: String,
        secondary: String,
        currentVolume: Float?,
        canAdjustVolume: Bool,
        hasRememberedVolume: Bool
    ) {
        let title = currentVolume.map { "AirPods \(percent($0))" } ?? "AirPods Vol"
        onStatusChanged?(
            VolumeMemoryStatus(
                menuBarTitle: title,
                primaryText: primary,
                secondaryText: secondary,
                currentVolume: currentVolume,
                canAdjustVolume: canAdjustVolume,
                hasRememberedVolume: hasRememberedVolume,
                automaticRestoreEnabled: automaticRestoreEnabled
            )
        )
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

    private func sameEndpoint(_ lhs: AudioDevice?, _ rhs: AudioDevice?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.id == rhs.id && lhs.uid == rhs.uid
        default:
            return false
        }
    }

    private func isCurrentEndpoint(_ device: AudioDevice) -> Bool {
        sameEndpoint(device, currentDevice)
    }

    private func volumesMatch(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(normalizedVolume(lhs) - normalizedVolume(rhs)) < 0.005
    }

    private func percent(_ volume: Float) -> String {
        "\(Int((normalizedVolume(volume) * 100).rounded()))%"
    }

    private func normalizedVolume(_ volume: Float) -> Float {
        min(max(volume, 0), 1)
    }
}
