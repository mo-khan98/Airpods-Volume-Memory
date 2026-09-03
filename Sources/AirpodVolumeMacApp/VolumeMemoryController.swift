import Foundation

enum RestoreHistoryOutcome: String, Codable {
    case pending
    case restored
    case failed
    case paused
    case automaticRestoreOff
    case noRememberedVolume
}

struct RememberedAirPods: Codable, Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    var name: String
    var rememberedVolume: Float
    var lastConnectedAt: Date?
    var lastConnectedVolume: Float?
    var lastRestoredAt: Date?
    var lastRestoredVolume: Float?
    var automaticRestoreEnabled: Bool
}

struct AirPodsConnectionHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let deviceUID: String
    var deviceName: String
    let connectedAt: Date
    var connectedVolume: Float?
    var restoredVolume: Float?
    var outcome: RestoreHistoryOutcome
}

struct VolumeMemoryDataSnapshot {
    let devices: [RememberedAirPods]
    let history: [AirPodsConnectionHistoryEntry]
    let currentDeviceUID: String?
}

struct RestoreNotificationEvent {
    let deviceName: String
    let volume: Float?
    let succeeded: Bool
}

struct VolumeMemoryStatus {
    let menuBarTitle: String
    let primaryText: String
    let secondaryText: String
    let currentVolume: Float?
    let canAdjustVolume: Bool
    let hasRememberedVolume: Bool
    let automaticRestoreEnabled: Bool
    let currentDeviceName: String?
    let restoresPaused: Bool
    let pauseDescription: String?
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
    var onDataChanged: ((VolumeMemoryDataSnapshot) -> Void)?
    var onRestoreNotification: ((RestoreNotificationEvent) -> Void)?

    private let defaults: UserDefaults
    private let audioHardware: AudioHardwareControlling
    private let scheduler: VolumeMemoryScheduling
    private let configuration: VolumeMemoryConfiguration
    private let now: () -> Date
    private let savedVolumeKeyPrefix = "savedOutputVolume."
    private let automaticRestoreEnabledKey = "automaticRestoreEnabled"
    private let rememberedDevicesKey = "rememberedAirPods.v2"
    private let connectionHistoryKey = "airPodsConnectionHistory.v1"
    private let restorePausedUntilKey = "restorePausedUntil"
    private let restorePausedIndefinitelyKey = "restorePausedIndefinitely"
    private let maximumHistoryCount = 100

    private var defaultOutputListener: AudioPropertyListening?
    private var volumeListener: AudioPropertyListening?
    private var currentDevice: AudioDevice?
    private var pendingRestoreTasks: [VolumeMemoryScheduledTask] = []
    private var pendingSaveTask: VolumeMemoryScheduledTask?
    private var pendingSettlingTask: VolumeMemoryScheduledTask?
    private var pendingPauseExpirationTask: VolumeMemoryScheduledTask?
    private var restoreTarget: Float?
    private var isRestoreInProgress = false
    private var isConnectionSettling = false
    private var currentHistoryEntryID: UUID?
    private var rememberedDevices: [RememberedAirPods]
    private var connectionHistory: [AirPodsConnectionHistoryEntry]

    init(
        defaults: UserDefaults = .standard,
        audioHardware: AudioHardwareControlling = SystemAudioHardware(),
        scheduler: VolumeMemoryScheduling = MainQueueVolumeMemoryScheduler(),
        configuration: VolumeMemoryConfiguration = VolumeMemoryConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.audioHardware = audioHardware
        self.scheduler = scheduler
        self.configuration = configuration
        self.now = now
        self.rememberedDevices = Self.decode([RememberedAirPods].self, from: defaults, key: rememberedDevicesKey) ?? []
        self.connectionHistory = Self.decode(
            [AirPodsConnectionHistoryEntry].self,
            from: defaults,
            key: connectionHistoryKey
        ) ?? []
    }

    var automaticRestoreEnabled: Bool {
        guard defaults.object(forKey: automaticRestoreEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: automaticRestoreEnabledKey)
    }

    var restoresPaused: Bool {
        if defaults.bool(forKey: restorePausedIndefinitelyKey) {
            return true
        }
        guard let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return false
        }
        if until > now() {
            return true
        }
        defaults.removeObject(forKey: restorePausedUntilKey)
        return false
    }

    var pauseDescription: String? {
        if defaults.bool(forKey: restorePausedIndefinitelyKey) {
            return "until resumed"
        }
        guard restoresPaused, let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return nil
        }
        return "until \(Self.pauseDateFormatter.string(from: until))"
    }

    func dataSnapshot() -> VolumeMemoryDataSnapshot {
        VolumeMemoryDataSnapshot(
            devices: rememberedDevices.sorted {
                ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
            },
            history: connectionHistory.sorted { $0.connectedAt > $1.connectedAt },
            currentDeviceUID: currentDevice?.isAirPods == true ? currentDevice?.uid : nil
        )
    }

    func pauseRestores(for duration: TimeInterval?) {
        let wasRestoreInProgress = isRestoreInProgress
        cancelRestore()
        if let duration {
            defaults.set(now().addingTimeInterval(duration), forKey: restorePausedUntilKey)
            defaults.set(false, forKey: restorePausedIndefinitelyKey)
        } else {
            defaults.removeObject(forKey: restorePausedUntilKey)
            defaults.set(true, forKey: restorePausedIndefinitelyKey)
        }
        schedulePauseExpirationIfNeeded()

        if let device = currentDevice, device.isAirPods {
            beginConnectionSettling(for: device)
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .paused, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "Automatic restores are paused \(pauseDescription ?? "temporarily").")
        } else {
            publishWaitingForAirPods()
        }
    }

    func resumeRestores() {
        defaults.removeObject(forKey: restorePausedUntilKey)
        defaults.set(false, forKey: restorePausedIndefinitelyKey)
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil

        guard let device = currentDevice, device.isAirPods else {
            publishWaitingForAirPods()
            return
        }
        if automaticRestoreEnabled,
           deviceAutomaticRestoreEnabled(device.uid),
           let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "Automatic restores resumed.")
        }
    }

    func updateRememberedVolume(for deviceUID: String, volume: Float) {
        guard let index = rememberedDevices.firstIndex(where: { $0.uid == deviceUID }) else {
            return
        }
        let adjustedVolume = normalizedVolume(volume)
        rememberedDevices[index].rememberedVolume = adjustedVolume
        defaults.set(Double(adjustedVolume), forKey: savedVolumeKey(forUID: deviceUID))
        persistDevices()

        guard let device = currentDevice, device.uid == deviceUID else {
            return
        }
        cancelRestore()
        do {
            try audioHardware.setOutputVolume(adjustedVolume, for: device)
            publishTrackingStatus(
                for: device,
                currentVolume: adjustedVolume,
                note: "Updated this device's remembered volume."
            )
        } catch {
            publishError(primary: "Saved the remembered volume, but could not apply it.", error: error)
        }
    }

    func setAutomaticRestore(_ enabled: Bool, for deviceUID: String) {
        guard let index = rememberedDevices.firstIndex(where: { $0.uid == deviceUID }) else {
            return
        }
        rememberedDevices[index].automaticRestoreEnabled = enabled
        persistDevices()

        guard let device = currentDevice, device.uid == deviceUID else {
            return
        }

        if !enabled {
            let wasRestoreInProgress = isRestoreInProgress
            cancelRestore()
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "Automatic restore is off for this device.")
        } else if automaticRestoreEnabled, !restoresPaused, let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "Automatic restore is on for this device.")
        }
    }

    func forgetDevice(_ deviceUID: String) {
        if currentDevice?.uid == deviceUID {
            cancelRestore()
        }
        rememberedDevices.removeAll { $0.uid == deviceUID }
        defaults.removeObject(forKey: savedVolumeKey(forUID: deviceUID))
        persistDevices()

        if let device = currentDevice, device.uid == deviceUID {
            publishCurrentStatus(for: device, note: "Forgot the remembered volume.")
        }
    }

    func clearConnectionHistory() {
        connectionHistory.removeAll()
        currentHistoryEntryID = nil
        persistHistory()
    }

    func start() {
        stop()
        schedulePauseExpirationIfNeeded()

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
        pendingSettlingTask?.cancel()
        pendingSettlingTask = nil
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil
        isConnectionSettling = false
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

        if !enabled {
            let wasRestoreInProgress = isRestoreInProgress
            cancelRestore()
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "Automatic restore is off.")
        } else if restoresPaused {
            cancelRestore()
            publishCurrentStatus(
                for: device,
                note: "Automatic restore is on, but paused \(pauseDescription ?? "temporarily")."
            )
        } else if !deviceAutomaticRestoreEnabled(device.uid) {
            cancelRestore()
            publishCurrentStatus(for: device, note: "Automatic restore is off for this device.")
        } else if let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "Automatic restore is on. Save a volume first.")
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
            forgetDevice(device.uid)
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
        let reusableHistoryEntryID: UUID? = {
            guard sameEndpoint(device, currentDevice),
                  let currentHistoryEntryID,
                  let entry = connectionHistory.first(where: { $0.id == currentHistoryEntryID }),
                  now().timeIntervalSince(entry.connectedAt) < 10 else {
                return nil
            }
            return currentHistoryEntryID
        }()

        cancelRestore()
        pendingSettlingTask?.cancel()
        pendingSettlingTask = nil
        isConnectionSettling = false
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        volumeListener?.invalidate()
        volumeListener = nil
        currentDevice = device
        currentHistoryEntryID = reusableHistoryEntryID
        publishDataSnapshot()

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
        let rememberedVolume = savedVolume(for: device)
        recordConnection(for: device, connectedVolume: currentVolume)
        beginConnectionSettling(for: device)

        if let rememberedVolume {
            if restoresPaused {
                markCurrentHistory(outcome: .paused, restoredVolume: nil)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "Connected; restores are paused \(pauseDescription ?? "temporarily")."
                )
            } else if automaticRestoreEnabled, deviceAutomaticRestoreEnabled(device.uid) {
                beginRestore(rememberedVolume, for: device, manuallyRequested: false)
            } else {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: automaticRestoreEnabled
                        ? "Connected; automatic restore is off for this device."
                        : "Connected; automatic restore is off."
                )
            }
        } else if let currentVolume {
            save(currentVolume, for: device)
            markCurrentHistory(outcome: .noRememberedVolume, restoredVolume: nil)
            publishTrackingStatus(
                for: device,
                currentVolume: currentVolume,
                note: "Saved this device's initial volume."
            )
        } else {
            markCurrentHistory(outcome: .noRememberedVolume, restoredVolume: nil)
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

    private func beginConnectionSettling(for device: AudioDevice) {
        pendingSettlingTask?.cancel()
        isConnectionSettling = true
        let delay = max(0, configuration.restoreAttemptDelays.max() ?? 0)
            + configuration.restoreCompletionGrace
        pendingSettlingTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.isCurrentEndpoint(device) else {
                return
            }
            self.isConnectionSettling = false
            self.pendingSettlingTask = nil
        }
    }

    private func schedulePauseExpirationIfNeeded() {
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil
        guard !defaults.bool(forKey: restorePausedIndefinitelyKey),
              let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return
        }

        let remaining = until.timeIntervalSince(now())
        guard remaining > 0 else {
            defaults.removeObject(forKey: restorePausedUntilKey)
            return
        }

        pendingPauseExpirationTask = scheduler.schedule(after: remaining) { [weak self] in
            guard let self else { return }
            self.defaults.removeObject(forKey: self.restorePausedUntilKey)
            self.pendingPauseExpirationTask = nil
            if let device = self.currentDevice, device.isAirPods {
                self.publishCurrentStatus(
                    for: device,
                    note: "Temporary pause ended; automatic restore is ready for the next connection."
                )
            } else {
                self.publishWaitingForAirPods()
            }
        }
    }

    private func beginRestore(_ volume: Float, for device: AudioDevice, manuallyRequested: Bool) {
        cancelRestore()
        restoreTarget = normalizedVolume(volume)
        isRestoreInProgress = true
        markCurrentHistory(outcome: .pending, restoredVolume: nil)

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
                recordSuccessfulRestore(for: device, volume: currentVolume)
                markCurrentHistory(outcome: .restored, restoredVolume: currentVolume)
                onRestoreNotification?(
                    RestoreNotificationEvent(deviceName: device.name, volume: currentVolume, succeeded: true)
                )
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "Restored and verified the remembered volume."
                )
            } else {
                markCurrentHistory(outcome: .failed, restoredVolume: currentVolume)
                onRestoreNotification?(
                    RestoreNotificationEvent(deviceName: device.name, volume: currentVolume, succeeded: false)
                )
                publish(
                    primary: "The remembered volume did not stick.",
                    secondary: "Choose Restore Remembered Volume to try again.",
                    currentVolume: currentVolume,
                    canAdjustVolume: true,
                    hasRememberedVolume: true
                )
            }
        } catch {
            markCurrentHistory(outcome: .failed, restoredVolume: nil)
            onRestoreNotification?(
                RestoreNotificationEvent(deviceName: device.name, volume: nil, succeeded: false)
            )
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
            guard !isRestoreInProgress, !isConnectionSettling else {
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
                automaticRestoreEnabled: automaticRestoreEnabled,
                currentDeviceName: currentDevice?.isAirPods == true ? currentDevice?.name : nil,
                restoresPaused: restoresPaused,
                pauseDescription: pauseDescription
            )
        )
    }

    private func save(_ volume: Float, for device: AudioDevice) {
        let saved = normalizedVolume(volume)
        if let index = rememberedDevices.firstIndex(where: { $0.uid == device.uid }) {
            rememberedDevices[index].name = device.name
            rememberedDevices[index].rememberedVolume = saved
        } else {
            rememberedDevices.append(
                RememberedAirPods(
                    uid: device.uid,
                    name: device.name,
                    rememberedVolume: saved,
                    lastConnectedAt: now(),
                    lastConnectedVolume: saved,
                    lastRestoredAt: nil,
                    lastRestoredVolume: nil,
                    automaticRestoreEnabled: true
                )
            )
        }
        defaults.set(Double(saved), forKey: savedVolumeKey(for: device))
        persistDevices()
    }

    private func savedVolume(for device: AudioDevice) -> Float? {
        if let record = rememberedDevices.first(where: { $0.uid == device.uid }) {
            return normalizedVolume(record.rememberedVolume)
        }

        let key = savedVolumeKey(for: device)
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        let legacyVolume = normalizedVolume(Float(defaults.double(forKey: key)))
        rememberedDevices.append(
            RememberedAirPods(
                uid: device.uid,
                name: device.name,
                rememberedVolume: legacyVolume,
                lastConnectedAt: nil,
                lastConnectedVolume: nil,
                lastRestoredAt: nil,
                lastRestoredVolume: nil,
                automaticRestoreEnabled: true
            )
        )
        persistDevices()
        return legacyVolume
    }

    private func savedVolumeKey(for device: AudioDevice) -> String {
        savedVolumeKey(forUID: device.uid)
    }

    private func savedVolumeKey(forUID deviceUID: String) -> String {
        savedVolumeKeyPrefix + deviceUID
    }

    private func deviceAutomaticRestoreEnabled(_ deviceUID: String) -> Bool {
        rememberedDevices.first(where: { $0.uid == deviceUID })?.automaticRestoreEnabled ?? true
    }

    private func recordConnection(for device: AudioDevice, connectedVolume: Float?) {
        let timestamp = now()
        if let index = rememberedDevices.firstIndex(where: { $0.uid == device.uid }) {
            rememberedDevices[index].name = device.name
            rememberedDevices[index].lastConnectedAt = timestamp
            rememberedDevices[index].lastConnectedVolume = connectedVolume
            persistDevices()
        }

        if currentHistoryEntryID != nil {
            return
        }

        let entry = AirPodsConnectionHistoryEntry(
            id: UUID(),
            deviceUID: device.uid,
            deviceName: device.name,
            connectedAt: timestamp,
            connectedVolume: connectedVolume,
            restoredVolume: nil,
            outcome: .pending
        )
        currentHistoryEntryID = entry.id
        connectionHistory.append(entry)
        if connectionHistory.count > maximumHistoryCount {
            connectionHistory.removeFirst(connectionHistory.count - maximumHistoryCount)
        }
        persistHistory()
    }

    private func recordSuccessfulRestore(for device: AudioDevice, volume: Float) {
        guard let index = rememberedDevices.firstIndex(where: { $0.uid == device.uid }) else {
            return
        }
        rememberedDevices[index].lastRestoredAt = now()
        rememberedDevices[index].lastRestoredVolume = normalizedVolume(volume)
        persistDevices()
    }

    private func markCurrentHistory(outcome: RestoreHistoryOutcome, restoredVolume: Float?) {
        guard let id = currentHistoryEntryID,
              let index = connectionHistory.firstIndex(where: { $0.id == id }) else {
            return
        }
        connectionHistory[index].outcome = outcome
        connectionHistory[index].restoredVolume = restoredVolume.map(normalizedVolume)
        persistHistory()
    }

    private func persistDevices() {
        encode(rememberedDevices, key: rememberedDevicesKey)
        publishDataSnapshot()
    }

    private func persistHistory() {
        encode(connectionHistory, key: connectionHistoryKey)
        publishDataSnapshot()
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func publishDataSnapshot() {
        onDataChanged?(dataSnapshot())
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
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

    private static let pauseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
