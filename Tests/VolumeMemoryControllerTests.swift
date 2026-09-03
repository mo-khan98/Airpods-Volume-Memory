import CoreAudio
import Foundation

@main
enum VolumeMemoryControllerTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("restore retries and verifies", testRestoreUsesMultipleAttemptsAndVerifiesTheResult),
            ("reconnect noise preserves memory", testReconnectNoiseDoesNotOverwriteRememberedVolume),
            ("slider cancels pending restore", testSliderChangeCancelsPendingReconnectRestore),
            ("refresh and reconnect notifications differ", testRefreshAndReconnectNotificationBehavior),
            ("device switch cancels restore", testDeviceSwitchCancelsRestore),
            ("manual restore works while automatic restore is off", testManualRestoreWhenAutomaticRestoreIsOff),
            ("exact volume values are preserved", testExactVolumeValuesArePreserved),
            ("temporary pause protects memory and can resume", testTemporaryPauseProtectsMemoryAndCanResume),
            ("multiple devices are managed independently", testMultipleDevicesAreManagedIndependently),
            ("history records and deduplicates restore results", testHistoryRecordsAndDeduplicatesRestoreResults),
            ("appearance and notification preferences persist", testPreferencesPersist),
            ("renamed Apple Bluetooth device detection", testRenamedAppleBluetoothDeviceIsRecognized)
        ]

        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                print("✗ \(name): \(error)")
                throw error
            }
        }

        print("\n\(tests.count) tests passed")
    }

    private static func testRestoreUsesMultipleAttemptsAndVerifiesTheResult() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            var latestStatus: VolumeMemoryStatus?
            controller.onStatusChanged = { latestStatus = $0 }

            controller.start()

            try expect(hardware.setVolumes.isEmpty, "restore should not run before its first delay")
            scheduler.advance(to: 1)
            hardware.volume = 0.5 // CoreAudio overwrites the first reconnect attempt.
            scheduler.advance(to: 2)
            hardware.volume = 0.5 // It happens again while Bluetooth is still settling.
            scheduler.advance(to: 4)
            scheduler.advance(to: 4.5)

            try expect(hardware.setVolumes == [0.25, 0.25, 0.25], "expected three restore passes")
            try expect(hardware.volume == 0.25, "final volume should match memory")
            try expect(
                latestStatus?.primaryText == "Restored and verified the remembered volume.",
                "successful verification should be reported"
            )
        }
    }

    private static func testReconnectNoiseDoesNotOverwriteRememberedVolume() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            defaults.set(0.25, forKey: key)
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            hardware.volume = 0.5
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 0.2)
            try expect(defaults.double(forKey: key) == 0.25, "reconnect noise overwrote memory")

            scheduler.advance(to: 4.5)
            hardware.volume = 0.75
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 4.7)
            try expect(defaults.double(forKey: key) == 0.75, "later intentional change was not saved")
        }
    }

    private static func testSliderChangeCancelsPendingReconnectRestore() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            defaults.set(0.25, forKey: key)
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            controller.setCurrentAirPodsVolume(0.75)
            scheduler.advance(to: 10)

            try expect(hardware.setVolumes == [0.75], "a stale restore ran after the slider change")
            try expect(defaults.double(forKey: key) == 0.75, "slider value was not remembered")
        }
    }

    private static func testRefreshAndReconnectNotificationBehavior() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()
            let scheduledCount = scheduler.pendingTaskCount

            controller.refresh()
            try expect(
                scheduler.totalScheduledTaskCount == scheduledCount,
                "opening the menu scheduled duplicate restore passes"
            )

            hardware.notifyDefaultOutputChanged()
            try expect(
                scheduler.totalScheduledTaskCount == scheduledCount * 2,
                "a real reconnect notification did not restart restore for a reused endpoint ID"
            )
        }
    }

    private static func testDeviceSwitchCancelsRestore() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            hardware.device = AudioDevice(
                id: 99,
                uid: "built-in-output",
                name: "Mac Speakers",
                manufacturer: "Apple Inc.",
                modelUID: "MacSpeakers",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            hardware.notifyDefaultOutputChanged()
            scheduler.advance(to: 10)

            try expect(hardware.setVolumes.isEmpty, "restore continued after the active output changed")
        }
    }

    private static func testManualRestoreWhenAutomaticRestoreIsOff() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            defaults.set(false, forKey: "automaticRestoreEnabled")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            scheduler.advance(to: 10)
            try expect(hardware.setVolumes.isEmpty, "disabled automatic restore still changed volume")

            controller.restoreRememberedVolumeNow()
            scheduler.advance(to: 11)
            try expect(hardware.setVolumes == [0.25], "manual restore did not run while automatic restore was off")
        }
    }

    private static func testExactVolumeValuesArePreserved() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            let hardware = FakeAudioHardware(device: device, volume: 0.371)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            try expect(
                abs(defaults.double(forKey: key) - 0.371) < 0.000_001,
                "initial Control Center volume was quantized"
            )

            scheduler.advance(to: 4.5)
            hardware.volume = 0.427
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 4.7)
            try expect(
                abs(defaults.double(forKey: key) - 0.427) < 0.000_001,
                "changed Control Center volume was quantized"
            )
        }
    }

    private static func testTemporaryPauseProtectsMemoryAndCanResume() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            defaults.set(0.25, forKey: key)
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)

            controller.pauseRestores(for: 15 * 60)
            controller.start()
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 1)

            try expect(hardware.setVolumes.isEmpty, "a paused connection restored automatically")
            try expect(defaults.double(forKey: key) == 0.25, "paused reconnect noise overwrote memory")
            try expect(controller.dataSnapshot().history.first?.outcome == .paused, "paused connection was not recorded")

            controller.resumeRestores()
            scheduler.advance(to: 2)
            try expect(hardware.setVolumes == [0.25], "resuming did not restore the current device")

            controller.pauseRestores(for: 0.5)
            try expect(controller.restoresPaused, "timed pause did not become active")
            scheduler.advance(to: 2.5)
            try expect(!controller.restoresPaused, "timed pause did not expire")
        }
    }

    private static func testMultipleDevicesAreManagedIndependently() throws {
        try withDefaults { defaults in
            let first = makeAirPods()
            let second = AudioDevice(
                id: 43,
                uid: "second-airpods",
                name: "Travel AirPods",
                manufacturer: "Apple Inc.",
                modelUID: "TravelAirPods",
                transportType: kAudioDeviceTransportTypeBluetooth
            )
            let hardware = FakeAudioHardware(device: first, volume: 0.31)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            hardware.device = second
            hardware.volume = 0.62
            hardware.notifyDefaultOutputChanged()

            var snapshot = controller.dataSnapshot()
            try expect(snapshot.devices.count == 2, "unique AirPods were not stored separately")
            try expect(snapshot.history.count == 2, "each unique connection was not recorded")

            controller.updateRememberedVolume(for: first.uid, volume: 0.44)
            controller.setAutomaticRestore(false, for: first.uid)
            snapshot = controller.dataSnapshot()
            let firstRecord = snapshot.devices.first { $0.uid == first.uid }
            let secondRecord = snapshot.devices.first { $0.uid == second.uid }
            try expect(abs((firstRecord?.rememberedVolume ?? 0) - 0.44) < 0.000_001, "offline device volume was not updated")
            try expect(firstRecord?.automaticRestoreEnabled == false, "per-device restore preference was not saved")
            try expect(abs((secondRecord?.rememberedVolume ?? 0) - 0.62) < 0.000_001, "second device memory was changed")
            try expect(hardware.setVolumes.isEmpty, "editing an offline device changed the active device")
        }
    }

    private static func testHistoryRecordsAndDeduplicatesRestoreResults() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()
            scheduler.advance(to: 4.5)

            var history = controller.dataSnapshot().history
            try expect(history.count == 1, "initial connection history entry is missing")
            try expect(history[0].connectedVolume == 0.5, "connected volume was not recorded")
            try expect(history[0].restoredVolume == 0.25, "restored volume was not recorded")
            try expect(history[0].outcome == .restored, "successful result was not recorded")

            hardware.notifyDefaultOutputChanged()
            history = controller.dataSnapshot().history
            try expect(history.count == 1, "duplicate CoreAudio notifications created duplicate history")
        }
    }

    private static func testPreferencesPersist() throws {
        try withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.menuBarDisplayMode = .deviceName
            preferences.restoreNotificationMode = .failuresOnly

            let reloaded = AppPreferences(defaults: defaults)
            try expect(reloaded.menuBarDisplayMode == .deviceName, "menu-bar display preference was not persisted")
            try expect(
                reloaded.restoreNotificationMode == .failuresOnly,
                "notification preference was not persisted"
            )
        }
    }

    private static func testRenamedAppleBluetoothDeviceIsRecognized() throws {
        let renamedAirPods = AudioDevice(
            id: 1,
            uid: "renamed",
            name: "Ayesha's Earbuds",
            manufacturer: "Apple Inc.",
            modelUID: nil,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let unrelatedBluetoothDevice = AudioDevice(
            id: 2,
            uid: "other",
            name: "Portable Speaker",
            manufacturer: "Example Audio",
            modelUID: nil,
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        try expect(renamedAirPods.isAirPods, "renamed Apple Bluetooth audio should be recognized")
        try expect(!unrelatedBluetoothDevice.isAirPods, "unrelated Bluetooth hardware should be ignored")
    }

    private static func makeController(
        defaults: UserDefaults,
        hardware: FakeAudioHardware,
        scheduler: ManualScheduler
    ) -> VolumeMemoryController {
        VolumeMemoryController(
            defaults: defaults,
            audioHardware: hardware,
            scheduler: scheduler,
            configuration: VolumeMemoryConfiguration(
                restoreAttemptDelays: [1, 2, 4],
                restoreCompletionGrace: 0.5,
                saveDebounceDelay: 0.2
            )
        )
    }

    private static func makeAirPods() -> AudioDevice {
        AudioDevice(
            id: 42,
            uid: "test-airpods",
            name: "Test AirPods Pro",
            manufacturer: "Apple Inc.",
            modelUID: "TestAirPodsPro",
            transportType: kAudioDeviceTransportTypeBluetooth
        )
    }

    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "VolumeMemoryControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure("could not create isolated UserDefaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class FakeAudioHardware: AudioHardwareControlling {
    var device: AudioDevice?
    var volume: Float
    var setVolumes: [Float] = []
    private var defaultOutputHandler: (() -> Void)?
    private var volumeHandler: (() -> Void)?

    init(device: AudioDevice?, volume: Float) {
        self.device = device
        self.volume = volume
    }

    func defaultOutputDevice() throws -> AudioDevice? { device }
    func outputVolume(for device: AudioDevice) throws -> Float { volume }

    func setOutputVolume(_ volume: Float, for device: AudioDevice) throws {
        setVolumes.append(volume)
        self.volume = volume
    }

    func makeDefaultOutputDeviceListener(handler: @escaping () -> Void) throws -> AudioPropertyListening {
        defaultOutputHandler = handler
        return FakeListener()
    }

    func makeVolumeListener(
        for deviceID: AudioDeviceID,
        handler: @escaping () -> Void
    ) throws -> AudioPropertyListening {
        volumeHandler = handler
        return FakeListener()
    }

    func notifyDefaultOutputChanged() { defaultOutputHandler?() }
    func notifyVolumeChanged() { volumeHandler?() }
}

private final class FakeListener: AudioPropertyListening {
    func invalidate() {}
}

private final class ManualScheduler: VolumeMemoryScheduling {
    private final class Task: VolumeMemoryScheduledTask {
        let deadline: TimeInterval
        let action: () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping () -> Void) {
            self.deadline = deadline
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private var now: TimeInterval = 0
    private var tasks: [Task] = []

    var pendingTaskCount: Int {
        tasks.filter { !$0.isCancelled }.count
    }

    private(set) var totalScheduledTaskCount = 0

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> VolumeMemoryScheduledTask {
        totalScheduledTaskCount += 1
        let task = Task(deadline: now + delay, action: action)
        tasks.append(task)
        return task
    }

    func advance(to target: TimeInterval) {
        while let nextIndex = tasks.indices
            .filter({ tasks[$0].deadline <= target })
            .min(by: { tasks[$0].deadline < tasks[$1].deadline }) {
            let task = tasks.remove(at: nextIndex)
            now = task.deadline
            if !task.isCancelled {
                task.action()
            }
        }
        now = target
    }
}
