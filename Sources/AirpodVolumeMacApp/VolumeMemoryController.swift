import Foundation

enum RestoreHistoryOutcome: String, Codable {
    case pending
    case restored
    case failed
    case paused
    case automaticRestoreOff
    case noRememberedVolume
    case interrupted
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
    /// The automatic restore that ran because the AirPods just connected.
    let isConnectionRestore: Bool
}

/// Sent once per connection, after the reconnect volume has settled.
struct ConnectionNotificationEvent {
    let deviceUID: String
    let deviceName: String
    let volume: Float?
    let rememberedVolume: Float?
    let outcome: RestoreHistoryOutcome
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
    /// Reconnect or restore is still in progress, so the volume may be temporary.
    let isSettling: Bool
    let rememberedVolume: Float?
    let fixedRestoreEnabled: Bool
    let deviceAutomaticRestoreEnabled: Bool
    /// Something the user should know about, e.g. a restore that did not hold.
    let problem: String?
}

struct VolumeMemoryConfiguration {
    var restoreAttemptDelays: [TimeInterval] = [0.2, 2.25, 5.0]
    var restoreCompletionGrace: TimeInterval = 1.0
    var saveDebounceDelay: TimeInterval = 0.2
    var earlyVerificationDelay: TimeInterval? = 2
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
    var onConnectionNotification: ((ConnectionNotificationEvent) -> Void)?

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
    private var outputActivityListener: AudioPropertyListening?
    private var deferredVolume: (target: Float, automatic: Bool)?
    private var volumeListenerGeneration = UUID()
    private var currentDevice: AudioDevice?
    private var pendingRestoreTasks: [VolumeMemoryScheduledTask] = []
    private var pendingSaveTask: VolumeMemoryScheduledTask?
    private var pendingManualVolumeVerification: VolumeMemoryScheduledTask?
    private var pendingKeyboardVolume: Float?
    private var lastStableVolume: Float?
    private var pendingSettlingTask: VolumeMemoryScheduledTask?
    private var pendingPauseExpirationTask: VolumeMemoryScheduledTask?
    private var restoreTarget: Float?
    private var recoveryAttemptsRemaining = 0
    private var isRestoreInProgress = false
    private var isManualRestore = false
    private var isConnectionSettling = false
    private var connectionNotificationPending = false

    var currentAirPodsUID: String? { currentDevice?.isAirPods == true ? currentDevice?.uid : nil }
    private var lastTrackingNote: String?
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

        // A restore cannot still be running at launch; the app quit or crashed during it.
        if connectionHistory.contains(where: { $0.outcome == .pending }) {
            for index in connectionHistory.indices where connectionHistory[index].outcome == .pending {
                connectionHistory[index].outcome = .interrupted
            }
            encode(connectionHistory, key: connectionHistoryKey)
        }
    }

    var fixedRestoreEnabled: Bool { defaults.bool(forKey: "fixedRestoreEnabled") }

    var fixedRestorePercent: Int {
        guard defaults.object(forKey: "fixedRestorePercent") != nil else { return 15 }
        return min(max(defaults.integer(forKey: "fixedRestorePercent"), 0), 100)
    }

    func setFixedRestore(enabled: Bool, percent: Int) {
        let clamped = min(max(percent, 0), 100)
        guard enabled != fixedRestoreEnabled || clamped != fixedRestorePercent else { return }
        defaults.set(enabled, forKey: "fixedRestoreEnabled")
        defaults.set(clamped, forKey: "fixedRestorePercent")
        cancelManualVolumeVerification()
        // Settings choose the next restore target. Cancel writes already queued for the old target.
        if isRestoreInProgress { cancelRestore() }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        refresh()
    }

    private func preferredRestoreVolume(for device: AudioDevice) -> Float? {
        if fixedRestoreEnabled { return Float(fixedRestorePercent) / 100 }
        return savedVolume(for: device)
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
            return "直到手动恢复"
        }
        guard restoresPaused, let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return nil
        }
        return "直到 \(Self.pauseDateFormatter.string(from: until))"
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
        let wasRestoreInProgress = isAutomaticRestoreInProgress
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
            publishCurrentStatus(for: device, note: "自动恢复已暂停：\(pauseDescription ?? "临时").")
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
           let rememberedVolume = preferredRestoreVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "已恢复自动调节。")
        }
    }

    func updateRememberedVolume(for deviceUID: String, volume: Float) {
        guard !fixedRestoreEnabled, let index = rememberedDevices.firstIndex(where: { $0.uid == deviceUID }) else {
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
                note: "已更新此设备的记忆音量。"
            )
        } catch {
            publishError(primary: "已保存记忆音量，但无法应用。", error: error)
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
            let wasRestoreInProgress = isAutomaticRestoreInProgress
            cancelRestore()
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "此设备的自动恢复已关闭。")
        } else if automaticRestoreEnabled, !restoresPaused, let rememberedVolume = preferredRestoreVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "此设备的自动恢复已开启。")
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
            publishCurrentStatus(for: device, note: "已删除记忆音量。")
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
                primary: "无法启动声音设备监听。",
                error: error,
                canAdjustVolume: false
            )
        }
    }

    func stop() {
        cancelManualVolumeVerification()
        cancelRestore()
        pendingSettlingTask?.cancel()
        pendingSettlingTask = nil
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil
        isConnectionSettling = false
        connectionNotificationPending = false
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        defaultOutputListener?.invalidate()
        volumeListener?.invalidate()
        outputActivityListener?.invalidate()
        outputActivityListener = nil
        deferredVolume = nil
        defaultOutputListener = nil
        volumeListener = nil
        currentDevice = nil
        lastStableVolume = nil
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
            let wasRestoreInProgress = isAutomaticRestoreInProgress
            cancelRestore()
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "自动恢复已关闭。")
        } else if restoresPaused {
            cancelRestore()
            publishCurrentStatus(
                for: device,
                note: "自动恢复已开启，但已暂停：\(pauseDescription ?? "临时")."
            )
        } else if !deviceAutomaticRestoreEnabled(device.uid) {
            cancelRestore()
            publishCurrentStatus(for: device, note: "此设备的自动恢复已关闭。")
        } else if let rememberedVolume = preferredRestoreVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "自动恢复已开启，请先保存音量。")
        }
    }

    func saveCurrentVolumeNow() {
        guard !fixedRestoreEnabled else { return }
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
            publishTrackingStatus(for: device, currentVolume: volume, note: "已保存当前音量。")
        } catch {
            publishError(primary: "无法保存当前音量。", error: error)
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
            guard let rememberedVolume = preferredRestoreVolume(for: device) else {
                publishCurrentStatus(for: device, note: "暂无记忆音量，请先保存。")
                return
            }

            beginRestore(rememberedVolume, for: device, manuallyRequested: true)
        } catch {
            publishError(primary: "无法恢复记忆音量。", error: error)
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
            publishError(primary: "无法删除记忆音量。", error: error)
        }
    }

    func setCurrentAirPodsVolume(_ volume: Float) {
        deferredVolume = nil
        cancelManualVolumeVerification()
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
            if !fixedRestoreEnabled { save(clampedVolume, for: device) }
            // A handoff can apply the system's 50% default shortly after a slider write.
            // Verify this explicit choice once, while the same output is still selected.
            pendingManualVolumeVerification = scheduler.schedule(after: 1.5) { [weak self] in
                self?.verifyManualVolume(clampedVolume, for: device)
            }
            publishTrackingStatus(for: device, currentVolume: clampedVolume,
                                  note: fixedRestoreEnabled ? "已调整当前音量。" : "已调整并保存音量。")
        } catch {
            publishError(primary: "无法调整 AirPods 音量。", error: error)
        }
    }

    func handleVolumeKey(increase: Bool, fine: Bool) {
        guard let device = try? audioHardware.defaultOutputDevice(), device.isAirPods,
              let volume = try? audioHardware.outputVolume(for: device) else { return }
        if !isCurrentEndpoint(device) {
            reconcileDefaultOutputDevice(force: false)
        }
        // The normal key event still goes to macOS. Estimate its step only for
        // the case where the resulting volume is the erroneous 50%.
        let handoffVolume = lastStableVolume ?? (
            isConnectionSettling || isRestoreInProgress ? preferredRestoreVolume(for: device) : nil
        )
        let baseline = volumesMatch(volume, 0.5)
            ? (pendingKeyboardVolume ?? deferredVolume?.target ?? handoffVolume ?? volume) : volume
        let steps: Float = fine ? 64 : 16
        let scaled = normalizedVolume(baseline) * steps
        let nearest = scaled.rounded()
        let step: Float
        if abs(nearest - scaled) < 0.001 {
            step = nearest + (increase ? 1 : -1)
        } else {
            step = increase ? ceil(scaled) : floor(scaled)
        }
        let target = normalizedVolume(step / steps)

        deferredVolume = nil
        cancelManualVolumeVerification()
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        pendingKeyboardVolume = target
        pendingManualVolumeVerification = scheduler.schedule(after: 0.35) { [weak self] in
            self?.verifyManualVolume(target, for: device, fromKeyboard: true)
        }
    }

    func handleMuteKey() {
        if deferredVolume?.automatic == false { deferredVolume = nil }
        cancelManualVolumeVerification()
    }

    private func cancelManualVolumeVerification() {
        pendingManualVolumeVerification?.cancel()
        pendingManualVolumeVerification = nil
        pendingKeyboardVolume = nil
    }

    private func verifyManualVolume(_ target: Float, for device: AudioDevice, fromKeyboard: Bool = false) {
        pendingManualVolumeVerification = nil
        pendingKeyboardVolume = nil
        guard isCurrentEndpoint(device),
              let active = try? audioHardware.defaultOutputDevice(), sameEndpoint(active, device),
              let observed = try? audioHardware.outputVolume(for: device) else { return }
        do {
            if volumesMatch(observed, 0.5), !volumesMatch(observed, target) {
                try audioHardware.setOutputVolume(target, for: device)
            }
            let current = normalizedVolume(try audioHardware.outputVolume(for: device))
            if deferVolumeIfWaitingForPlayback(target, observed: current, device: device, automatic: false) {
                return
            }
            if fromKeyboard, !fixedRestoreEnabled,
               savedVolume(for: device).map({ !volumesMatch($0, current) }) ?? true,
               !volumesMatch(current, 0.5) || volumesMatch(target, 0.5) {
                save(current, for: device)
            }
            publishTrackingStatus(for: device, currentVolume: current, note: lastTrackingNote)
        } catch {
            publishError(primary: "无法保持刚刚设置的 AirPods 音量。", error: error)
        }
    }

    private func reconcileDefaultOutputDevice(force: Bool) {
        do {
            let device = try audioHardware.defaultOutputDevice()
            if sameEndpoint(device, currentDevice),
               pendingManualVolumeVerification != nil || deferredVolume != nil {
                return
            }
            if !force, sameEndpoint(device, currentDevice) {
                if let device {
                    if device.isAirPods {
                        publishCurrentStatus(
                            for: device,
                            note: isRestoreInProgress ? "正在稳定记忆音量…" : nil
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
                primary: "无法读取当前输出设备。",
                error: error,
                canAdjustVolume: false
            )
        }
    }

    private func outputDeviceChanged(to device: AudioDevice?) {
        deferredVolume = nil
        outputActivityListener?.invalidate()
        outputActivityListener = nil
        cancelManualVolumeVerification()
        let reusableHistoryEntryID: UUID? = {
            guard sameEndpoint(device, currentDevice),
                  let currentHistoryEntryID,
                  let entry = connectionHistory.first(where: { $0.id == currentHistoryEntryID }),
                  now().timeIntervalSince(entry.connectedAt) < 10 else {
                return nil
            }
            return currentHistoryEntryID
        }()
        let isNewConnection = reusableHistoryEntryID == nil

        cancelRestore()
        pendingSettlingTask?.cancel()
        pendingSettlingTask = nil
        isConnectionSettling = false
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        volumeListener?.invalidate()
        volumeListener = nil
        if !sameEndpoint(device, currentDevice) { lastStableVolume = nil }
        currentDevice = device
        currentHistoryEntryID = reusableHistoryEntryID
        if isNewConnection {
            connectionNotificationPending = false
            lastTrackingNote = nil
        }
        publishDataSnapshot()

        guard let device else {
            publishNoOutputDevice()
            return
        }

        guard device.isAirPods else {
            publishWaitingForAirPods()
            return
        }

        if isNewConnection {
            connectionNotificationPending = true
        }
        installVolumeListener(for: device)
        outputActivityListener = try? audioHardware.makeOutputActivityListener(for: device) { [weak self] in
            self?.outputActivityChanged(for: device)
        }
        let currentVolume = try? normalizedVolume(audioHardware.outputVolume(for: device))
        let rememberedVolume = preferredRestoreVolume(for: device)
        recordConnection(for: device, connectedVolume: currentVolume)
        beginConnectionSettling(for: device)

        if let rememberedVolume {
            if restoresPaused {
                markCurrentHistory(outcome: .paused, restoredVolume: nil)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "已连接；自动恢复已暂停：\(pauseDescription ?? "临时")."
                )
            } else if automaticRestoreEnabled, deviceAutomaticRestoreEnabled(device.uid) {
                beginRestore(rememberedVolume, for: device, manuallyRequested: false)
            } else {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: automaticRestoreEnabled
                        ? "已连接；此设备的自动恢复已关闭。"
                        : "已连接；自动恢复已关闭。"
                )
            }
        } else if let currentVolume {
            save(currentVolume, for: device)
            markCurrentHistory(outcome: .noRememberedVolume, restoredVolume: nil)
            publishTrackingStatus(
                for: device,
                currentVolume: currentVolume,
                note: "已保存此设备的初始音量。"
            )
        } else {
            markCurrentHistory(outcome: .noRememberedVolume, restoredVolume: nil)
            publish(
                primary: "正在记忆：\(device.name).",
                secondary: "调整一次音量，应用即可记住。",
                currentVolume: nil,
                canAdjustVolume: true,
                hasRememberedVolume: false
            )
        }
    }

    private func deferVolumeIfWaitingForPlayback(
        _ target: Float, observed: Float, device: AudioDevice, automatic: Bool
    ) -> Bool {
        guard outputActivityListener != nil, audioHardware.isOutputActive(for: device) == false,
              volumesMatch(observed, 0.5), !volumesMatch(observed, target) else { return false }
        deferredVolume = (target, automatic)
        publishTrackingStatus(for: device, currentVolume: observed, note: "等待 Mac 开始播放，再应用调整后的音量。")
        return true
    }

    private func outputActivityChanged(for device: AudioDevice) {
        guard isCurrentEndpoint(device), let pending = deferredVolume,
              audioHardware.isOutputActive(for: device) == true,
              let active = try? audioHardware.defaultOutputDevice(), sameEndpoint(active, device) else { return }
        deferredVolume = nil
        if pending.automatic {
            guard automaticRestoreEnabled, !restoresPaused, deviceAutomaticRestoreEnabled(device.uid),
                  let volume = preferredRestoreVolume(for: device) else { return }
            beginRestore(volume, for: device, manuallyRequested: false)
        } else {
            setCurrentAirPodsVolume(pending.target)
        }
    }

    private func installVolumeListener(for device: AudioDevice) {
        guard volumeListener == nil else {
            return
        }

        let generation = UUID()
        volumeListenerGeneration = generation
        volumeListener = try? audioHardware.makeVolumeListener(for: device.id) { [weak self] in
            guard let self, self.volumeListenerGeneration == generation,
                  self.isCurrentEndpoint(device) else { return }
            self.volumeChanged()
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
            // A running restore reports its own result when it finishes.
            guard !self.isRestoreInProgress else {
                return
            }
            self.publishCurrentStatus(for: device, note: self.lastTrackingNote)
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
                    note: "暂停已结束，下次连接时将自动恢复音量。"
                )
            } else {
                self.publishWaitingForAirPods()
            }
        }
    }

    private func beginRestore(_ volume: Float, for device: AudioDevice, manuallyRequested: Bool) {
        deferredVolume = nil
        cancelManualVolumeVerification()
        cancelRestore()
        restoreTarget = normalizedVolume(volume)
        recoveryAttemptsRemaining = 2
        isRestoreInProgress = true
        isManualRestore = manuallyRequested
        // A manual retry must not rewrite how this connection was originally handled.
        if !manuallyRequested {
            markCurrentHistory(outcome: .pending, restoredVolume: nil)
        }

        let initialVolume = try? audioHardware.outputVolume(for: device)
        let allowEarlyVerification = !fixedRestoreEnabled
            && (initialVolume.map { volumesMatch($0, volume) } ?? false)
        let delays = configuration.restoreAttemptDelays.isEmpty ? [0] : configuration.restoreAttemptDelays
        for (index, delay) in delays.enumerated() {
            pendingRestoreTasks.append(
                scheduler.schedule(after: max(0, delay)) { [weak self] in
                    self?.performRestoreAttempt(index: index, totalAttempts: delays.count, for: device,
                                                allowEarlyVerification: allowEarlyVerification && index == 0)
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
            primary: "正在恢复：\(device.name) 至 \(percent(target)).",
            secondary: manuallyRequested
                ? "正在应用并验证记忆音量。"
                : "正在等待蓝牙音频就绪，随后验证音量。",
            currentVolume: try? normalizedVolume(audioHardware.outputVolume(for: device)),
            canAdjustVolume: true,
            hasRememberedVolume: true
        )
    }

    private func performRestoreAttempt(
        index: Int, totalAttempts: Int, for device: AudioDevice, allowEarlyVerification: Bool = false
    ) {
        guard isCurrentEndpoint(device), let target = restoreTarget else {
            return
        }

        // CoreAudio may already have switched routes while its listener callback is queued.
        guard let active = try? audioHardware.defaultOutputDevice(), sameEndpoint(active, device) else { return }
        installVolumeListener(for: device)

        do {
            try audioHardware.setOutputVolume(target, for: device)
            let observed = try? normalizedVolume(audioHardware.outputVolume(for: device))
            if allowEarlyVerification, let delay = configuration.earlyVerificationDelay,
               let observed, volumesMatch(observed, target) {
                pendingRestoreTasks.append(scheduler.schedule(after: delay) { [weak self] in
                    self?.finishRestore(for: device, onlyIfVerified: true)
                })
            }
            publish(
                primary: "正在恢复：\(device.name) 至 \(percent(target)).",
                secondary: "验证次数：\(index + 1) / \(totalAttempts).",
                currentVolume: observed,
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
        } catch {
            let willRetry = index + 1 < totalAttempts
            publish(
                primary: willRetry ? "AirPods 尚未就绪。" : "最后一次恢复尝试失败。",
                secondary: willRetry ? "应用将自动重试。" : error.localizedDescription,
                currentVolume: try? normalizedVolume(audioHardware.outputVolume(for: device)),
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
        }
    }

    private func finishRestore(for device: AudioDevice, onlyIfVerified: Bool = false) {
        guard isCurrentEndpoint(device), let target = restoreTarget else {
            return
        }

        let observed: Result<Float, Error> = Result {
            let active = try audioHardware.defaultOutputDevice()
            guard sameEndpoint(active, device) else { throw RestoreRouteError.outputChanged }
            return normalizedVolume(try audioHardware.outputVolume(for: device))
        }
        if case .failure(RestoreRouteError.outputChanged) = observed {
            reconcileDefaultOutputDevice(force: false)
            return
        }

        // A late Bluetooth reset or temporary read error merits a bounded retry.
        // Keep the same restore transaction, memory protection and notification.
        let volume = try? observed.get()
        let verified = volume.map { volumesMatch($0, target) } ?? false
        if onlyIfVerified && !verified { return }
        if !verified, recoveryAttemptsRemaining > 0 {
            recoveryAttemptsRemaining -= 1
            let attempt = 2 - recoveryAttemptsRemaining
            pendingRestoreTasks.append(scheduler.schedule(after: TimeInterval(attempt)) { [weak self] in
                self?.performRestoreAttempt(index: attempt - 1, totalAttempts: 2, for: device)
            })
            pendingRestoreTasks.append(scheduler.schedule(after: TimeInterval(attempt) + max(0.5, configuration.restoreCompletionGrace)) { [weak self] in
                self?.finishRestore(for: device)
            })
            publish(
                primary: "正在重试恢复音量…",
                secondary: "耳机音量尚未稳定，正在重新应用记忆值。",
                currentVolume: volume,
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
            return
        }

        let wasManual = isManualRestore
        let isConnectionRestore = !wasManual && connectionNotificationPending
        isRestoreInProgress = false
        isManualRestore = false
        restoreTarget = nil
        pendingRestoreTasks.forEach { $0.cancel() }
        pendingRestoreTasks.removeAll()
        if onlyIfVerified {
            pendingSettlingTask?.cancel()
            pendingSettlingTask = nil
            isConnectionSettling = false
        }

        func mark(_ outcome: RestoreHistoryOutcome, _ restoredVolume: Float?) {
            if !wasManual {
                markCurrentHistory(outcome: outcome, restoredVolume: restoredVolume)
            }
            if isConnectionRestore {
                connectionNotificationPending = false
                onConnectionNotification?(ConnectionNotificationEvent(
                    deviceUID: device.uid, deviceName: device.name, volume: restoredVolume,
                    rememberedVolume: target, outcome: outcome
                ))
            }
        }

        do {
            let currentVolume = try observed.get()
            if volumesMatch(currentVolume, target) {
                recordSuccessfulRestore(for: device, volume: currentVolume)
                mark(.restored, currentVolume)
                onRestoreNotification?(
                    RestoreNotificationEvent(
                        deviceName: device.name,
                        volume: currentVolume,
                        succeeded: true,
                        isConnectionRestore: isConnectionRestore
                    )
                )
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "已恢复记忆音量并验证成功。"
                )
            } else {
                if !wasManual, deferVolumeIfWaitingForPlayback(target, observed: currentVolume, device: device, automatic: true) {
                    return
                }
                mark(.failed, currentVolume)
                onRestoreNotification?(
                    RestoreNotificationEvent(
                        deviceName: device.name,
                        volume: currentVolume,
                        succeeded: false,
                        isConnectionRestore: isConnectionRestore
                    )
                )
                publish(
                    primary: "记忆音量未能保持。",
                    secondary: "请选择“恢复记忆音量”重试。",
                    currentVolume: currentVolume,
                    canAdjustVolume: true,
                    hasRememberedVolume: true,
                    problem: "记忆音量没有生效，可拖动滑块重新设置"
                )
            }
        } catch {
            mark(.failed, nil)
            onRestoreNotification?(
                RestoreNotificationEvent(
                    deviceName: device.name,
                    volume: nil,
                    succeeded: false,
                    isConnectionRestore: isConnectionRestore
                )
            )
            publishError(primary: "无法验证恢复后的音量。", error: error)
        }
    }

    private enum RestoreRouteError: Error { case outputChanged }

    private var isAutomaticRestoreInProgress: Bool {
        isRestoreInProgress && !isManualRestore
    }

    private func cancelRestore() {
        let wasAutomaticRestoreInProgress = isAutomaticRestoreInProgress
        pendingRestoreTasks.forEach { $0.cancel() }
        pendingRestoreTasks.removeAll()
        restoreTarget = nil
        isRestoreInProgress = false
        isManualRestore = false
        // Callers that know a more specific reason (pause, restore off) overwrite this.
        if wasAutomaticRestoreInProgress {
            markCurrentHistory(outcome: .interrupted, restoredVolume: nil)
        }
    }

    private func volumeChanged() {
        pendingSaveTask?.cancel()
        let maySave = !isRestoreInProgress && !isConnectionSettling
        pendingSaveTask = scheduler.schedule(after: configuration.saveDebounceDelay) { [weak self] in
            self?.saveChangedVolumeIfNeeded(maySave: maySave)
        }
    }

    private func saveChangedVolumeIfNeeded(maySave: Bool) {
        pendingSaveTask = nil
        guard let device = currentDevice, device.isAirPods,
              let active = try? audioHardware.defaultOutputDevice(), sameEndpoint(active, device) else {
            return
        }

        do {
            let volume = normalizedVolume(try audioHardware.outputVolume(for: device))
            if pendingManualVolumeVerification != nil || deferredVolume != nil, volumesMatch(volume, 0.5) { return }
            guard !isRestoreInProgress, !isConnectionSettling else {
                publish(
                    primary: "正在稳定：\(device.name) 于 \(percent(restoreTarget ?? volume)).",
                    secondary: "重连时的临时音量变化不会覆盖记忆值。",
                    currentVolume: volume,
                    canAdjustVolume: true,
                    hasRememberedVolume: savedVolume(for: device) != nil
                )
                return
            }
            // A debounced reconnect event can arrive here after restoration finished.
            guard maySave else { return }

            if fixedRestoreEnabled {
                publishTrackingStatus(for: device, currentVolume: volume, note: nil)
                return
            }
            if let saved = savedVolume(for: device), volumesMatch(saved, volume) {
                publishTrackingStatus(for: device, currentVolume: volume, note: "音量已同步。")
                return
            }

            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "已保存新音量。")
        } catch {
            publishError(primary: "无法保存更改后的音量。", error: error)
        }
    }

    private func publishCurrentStatus(for device: AudioDevice, note: String?) {
        let currentVolume = try? normalizedVolume(audioHardware.outputVolume(for: device))
        publishTrackingStatus(for: device, currentVolume: currentVolume, note: note)
    }

    private func publishTrackingStatus(for device: AudioDevice, currentVolume: Float?, note: String?) {
        lastTrackingNote = note
        let saved = preferredRestoreVolume(for: device)
        let displayed = currentVolume ?? (fixedRestoreEnabled ? nil : saved)
        publish(
            primary: note ?? "正在记忆：\(device.name).",
            secondary: saved.map { "下次连接将恢复为：\(percent($0))." }
                ?? "调整音量即可保存记忆值。",
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
            primary: "当前没有可用的输出设备。",
            secondary: "连接 AirPods 即可开始记忆音量。",
            currentVolume: nil,
            canAdjustVolume: false,
            hasRememberedVolume: false
        )
    }

    private func publishWaitingForAirPods() {
        let deviceName = currentDevice?.name
        publish(
            primary: deviceName.map { "当前输出：\($0)" } ?? "等待 AirPods 连接。",
            secondary: "自动识别 AirPods 和苹果蓝牙耳机。",
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
        let hasRememberedVolume = currentDevice.flatMap(preferredRestoreVolume(for:)) != nil
        publish(
            primary: primary,
            secondary: error.localizedDescription,
            currentVolume: nil,
            canAdjustVolume: canAdjustVolume,
            hasRememberedVolume: hasRememberedVolume,
            problem: primary.trimmingCharacters(in: CharacterSet(charactersIn: "。."))
        )
    }

    private func publish(
        primary: String,
        secondary: String,
        currentVolume: Float?,
        canAdjustVolume: Bool,
        hasRememberedVolume: Bool,
        problem: String? = nil
    ) {
        let airPods = currentDevice?.isAirPods == true ? currentDevice : nil
        if !isRestoreInProgress, !isConnectionSettling, airPods != nil, let currentVolume,
           pendingManualVolumeVerification == nil || !volumesMatch(currentVolume, 0.5) {
            lastStableVolume = currentVolume
        }
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
                currentDeviceName: airPods?.name,
                restoresPaused: restoresPaused,
                pauseDescription: pauseDescription,
                isSettling: isRestoreInProgress || isConnectionSettling,
                rememberedVolume: airPods.flatMap(preferredRestoreVolume(for:)),
                fixedRestoreEnabled: fixedRestoreEnabled,
                deviceAutomaticRestoreEnabled: airPods.map { deviceAutomaticRestoreEnabled($0.uid) } ?? true,
                problem: problem
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
