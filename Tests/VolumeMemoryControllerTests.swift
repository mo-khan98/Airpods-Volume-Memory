import CoreAudio
import Foundation

@main
enum VolumeMemoryControllerTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("high volume threshold crossings", testHighVolumeWarning),
            ("late Bluetooth reset is recovered", testLateReset),
            ("recovery stops when the device keeps rejecting writes", testBoundedRecovery),
            ("stale restore cannot write after output switch", testStaleRestore),
            ("restore retries and verifies", testRestoreUsesMultipleAttemptsAndVerifiesTheResult),
            ("reconnect noise preserves memory", testReconnectNoiseDoesNotOverwriteRememberedVolume),
            ("slider cancels pending restore", testSliderChangeCancelsPendingReconnectRestore),
            ("handoff reset preserves the slider choice", testHandoffResetsVolumeAfterSliderChange),
            ("keyboard volume recovers after a handoff reset", testKeyboardHandoffVolume),
            ("volume rejected while idle is restored when Mac playback resumes", testDeferredVolumeForPlayback),
            ("refresh and reconnect notifications differ", testRefreshAndReconnectNotificationBehavior),
            ("device switch cancels restore", testDeviceSwitchCancelsRestore),
            ("manual restore works while automatic restore is off", testManualRestoreWhenAutomaticRestoreIsOff),
            ("exact volume values are preserved", testExactVolumeValuesArePreserved),
            ("temporary pause protects memory and can resume", testTemporaryPauseProtectsMemoryAndCanResume),
            ("multiple devices are managed independently", testMultipleDevicesAreManagedIndependently),
            ("history records and deduplicates restore results", testHistoryRecordsAndDeduplicatesRestoreResults),
            ("appearance and notification preferences persist", testPreferencesPersist),
            ("renamed Apple Bluetooth device detection", testRenamedAppleBluetoothDeviceIsRecognized),
            ("interrupted restores leave no pending history", testInterruptedRestoresLeaveNoPendingHistory),
            ("manual restore keeps the connection outcome", testManualRestoreKeepsConnectionOutcome),
            ("status reports settling until the volume is final", testStatusReportsSettling),
            ("fixed restore survives iPhone handoff and manual changes", testFixedRestore),
            ("stable restore finishes early and cancels remaining writes", testEarlyStableRestore),
            ("connection notification waits for final verification", testConnectionNotification),
            ("connection notification reports only final failure", testConnectionNotificationCorrection),
            ("notification text leads with the volume", testNotificationText),
            ("takeover blip nudges the player once", testPlaybackStallDetector),
            ("menu status is plain language", testMenuStatusText),
            ("reconnect selects the intended Bluetooth output", testReconnectOutputMatching),
            ("AirPods handoff correlates the iPhone banner with audio ownership", testAirPodsHandoffOwnership)
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

    private static func testAirPodsHandoffOwnership() throws {
        let address = "00:11:22:33:44:55"
        let otherAddress = "00:11:22:33:44:66"
        let iPhonePeer = "_shouldAllowRelinquishOwnership _myModel Mac otherTipiName iPhone otherTipiVersion 2.000000"
        let release = "Setting ownership via BTHAL for Wx \(address) no"
        let banner = "PostingBanner: Type ReverseRoute, Name AirPods, Addr \(address), PID 0x2027, Timeout 20.000"
        var state = AirPodsHandoffState()

        state.consume("Setting ownership via BTHAL for Wx \(address) yes", at: 0)
        try expect(state.owner(for: address) == .mac, "Mac ownership must be recognized without playback")
        state.consume(iPhonePeer, at: 1)
        state.consume(release, at: 1.01)
        try expect(state.owner(for: address) == nil, "discovery or relinquish alone does not confirm the phone")
        state.consume(banner.replacingOccurrences(of: address, with: otherAddress), at: 1.02)
        try expect(state.owner(for: otherAddress) == nil, "ignore a banner for another device")
        state.consume(banner, at: 1.03)
        state.consume("OwnershipChanged: Received AACP message. Wx \(address) isOwned no", at: 1.09)
        try expect(state.owner(for: "00-11-22-33-44-55") == .iPhone, "confirm iPhone even when Mac retains Bluetooth")
        state.consume("OwnershipChanged: Received AACP message. Wx \(address) isOwned yes", at: 3)
        try expect(state.owner(for: address) == .mac, "Mac recovery overrides the previous phone handoff")

        state.consume(iPhonePeer, at: 4)
        state.consume(release, at: 4.01)
        state.consume(banner, at: 6)
        try expect(state.owner(for: address) == nil, "ignore a stale peer identification")
        state.consume(iPhonePeer.replacingOccurrences(of: "iPhone", with: "iPad"), at: 7)
        state.consume(release, at: 7.01)
        state.consume(banner, at: 7.02)
        try expect(state.owner(for: address) == nil, "do not label a different peer as iPhone")
    }

    private static func testReconnectOutputMatching() throws {
        let headphones = PairedHeadphones(address: "00:11:22:33:44:55", name: "AirPods", allowsNameMatch: true)
        let duplicate = PairedHeadphones(address: "00:11:22:33:44:55", name: "AirPods", allowsNameMatch: false)
        func output(
            _ uid: String, name: String = "AirPods", transport: UInt32 = kAudioDeviceTransportTypeBluetooth
        ) -> AudioDevice {
            AudioDevice(id: 1, uid: uid, name: name, manufacturer: nil, modelUID: nil, transportType: transport)
        }

        try expect(duplicate.matchesOutput(output("00-11-22-33-44-55:output", name: "Renamed")), "address identifies renamed headphones")
        try expect(!headphones.matchesOutput(output("00-11-22-33-44-66:output")), "same name cannot override a different address")
        try expect(headphones.matchesOutput(output("opaque UID")), "unique name matches when UID omits the address")
        try expect(!duplicate.matchesOutput(output("opaque UID")), "ambiguous name is insufficient")
        try expect(!headphones.matchesOutput(output("opaque UID", transport: kAudioDeviceTransportTypeBuiltIn)), "built-in output is excluded")
    }

    private static func testHighVolumeWarning() throws {
        var gate = HighVolumeWarningGate()
        func check(_ volume: Float?, _ uid: String? = "A", _ enabled: Bool = true) -> Bool {
            gate.shouldWarn(deviceUID: uid, volume: volume, enabled: enabled, threshold: 60)
        }
        try expect(!check(0.6), "equal threshold must not warn")
        try expect(check(0.61), "crossing above threshold must warn")
        try expect(!check(0.8), "remaining high must not repeat")
        try expect(!check(0.9), "refresh must not repeat")
        try expect(!check(0.5), "lowering must rearm silently")
        try expect(check(0.7), "new crossing must warn")
        try expect(check(0.7, "B"), "different device must warn independently")
        try expect(!check(0.9, nil), "non-AirPods must not warn")
        try expect(!check(0.9, "A", false), "disabled must not warn")
        try expect(!check(nil), "unavailable volume must not warn")
        try expect(!check(.nan), "invalid volume must not warn")
        try withDefaults { defaults in
            let prefs = AppPreferences(defaults: defaults)
            try expect(prefs.highVolumeWarningEnabled && prefs.highVolumeThreshold == 60, "warning defaults")
            prefs.highVolumeThreshold = 35
            prefs.highVolumeWarningEnabled = false
            let restored = AppPreferences(defaults: defaults)
            try expect(!restored.highVolumeWarningEnabled && restored.highVolumeThreshold == 35, "warning preferences must persist")
        }
    }

    private static func testLateReset() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            defaults.set(0.21, forKey: key)
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            var results: [Bool] = []
            controller.onRestoreNotification = { results.append($0.succeeded) }
            controller.start()
            scheduler.advance(to: 4.4)
            hardware.volume = 0.5 // System changes volume after the last scheduled write.
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 4.7)
            try expect(defaults.double(forKey: key) < 0.22, "late system reset replaced the remembered level")
            try expect(results.isEmpty, "failure was announced before a recovery attempt")
            scheduler.advance(to: 10)
            try expect(hardware.volume == 0.21, "late reset was not corrected")
            try expect(results == [true], "restore must report one verified result")
        }
    }

    private static func testBoundedRecovery() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            defaults.set(0.21, forKey: key)
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            hardware.ignoresVolumeWrites = true
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            var results: [Bool] = []
            controller.onRestoreNotification = { results.append($0.succeeded) }
            controller.start()
            scheduler.advance(to: 30)
            try expect(hardware.setVolumes.count == 5, "permanent failure did not stop after bounded retries")
            try expect(results == [false], "permanent failure must report only one final result")
            try expect(defaults.double(forKey: key) == 0.21, "permanent failure changed the remembered level")
        }
    }

    private static func testStaleRestore() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.21, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()
            hardware.device = nil // The system route changed but its callback is still queued.
            scheduler.advance(to: 10)
            try expect(hardware.setVolumes.isEmpty, "restore wrote to a device that was no longer the output")
        }
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
                latestStatus?.primaryText == "已恢复记忆音量并验证成功。",
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

    private static func testHandoffResetsVolumeAfterSliderChange() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(true, forKey: "fixedRestoreEnabled")
            defaults.set(15, forKey: "fixedRestorePercent")
            let hardware = FakeAudioHardware(device: device, volume: 0.15)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            controller.setCurrentAirPodsVolume(0.27)
            hardware.volume = 0.5
            hardware.notifyDefaultOutputChanged()
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 10)
            try expect(hardware.setVolumes == [0.27, 0.27], "handoff must not overwrite the slider choice")
            try expect(controller.fixedRestorePercent == 15, "current volume must not change the fixed restore setting")

            controller.setCurrentAirPodsVolume(0.31)
            hardware.volume = 0.4
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 12)
            try expect(hardware.volume == 0.4, "a different volume change must be honored")

            controller.setCurrentAirPodsVolume(0.36)
            hardware.device = nil
            hardware.volume = 0.5
            hardware.notifyDefaultOutputChanged()
            scheduler.advance(to: 20)
            try expect(hardware.setVolumes.last == 0.36, "must not correct another output")
            try expect(hardware.setVolumes.count == 4, "a disconnected route must receive no verification write")
        }
    }

    private static func testKeyboardHandoffVolume() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(true, forKey: "fixedRestoreEnabled")
            defaults.set(15, forKey: "fixedRestorePercent")
            let hardware = FakeAudioHardware(device: device, volume: 0.15)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            // The switch can land at 50% before the passive key event arrives.
            hardware.volume = 0.5
            controller.handleVolumeKey(increase: true, fine: false)
            hardware.notifyDefaultOutputChanged()
            scheduler.advance(to: 8)
            try expect(hardware.setVolumes == [0.1875], "volume up should use the pre-handoff volume")
            try expect(controller.fixedRestorePercent == 15, "the key should only change the current volume")

            // Bluetooth and the selected route may both remain unchanged.
            hardware.volume = 0.5
            controller.handleVolumeKey(increase: false, fine: false)
            scheduler.advance(to: 9)
            try expect(hardware.setVolumes.last == 0.125, "volume down must not jump to 50%")

            hardware.volume = 0.484375
            controller.handleVolumeKey(increase: true, fine: true)
            hardware.volume = 0.5
            scheduler.advance(to: 10)
            try expect(hardware.setVolumes.count == 2, "a deliberate fine step to 50% should pass through")

            hardware.volume = 0.25
            controller.handleVolumeKey(increase: false, fine: false)
            hardware.volume = 0.1875
            scheduler.advance(to: 11)
            try expect(hardware.setVolumes.count == 2, "a normal macOS volume change should pass through")

            controller.handleVolumeKey(increase: true, fine: false)
            controller.handleMuteKey()
            hardware.volume = 0.5
            scheduler.advance(to: 12)
            try expect(hardware.setVolumes.count == 2, "mute should cancel the correction")

            hardware.volume = 0.2
            controller.handleVolumeKey(increase: true, fine: false)
            hardware.device = nil
            hardware.volume = 0.5
            scheduler.advance(to: 13)
            try expect(hardware.setVolumes.count == 2, "must not correct a different audio route")
        }
    }

    private static func testDeferredVolumeForPlayback() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(true, forKey: "fixedRestoreEnabled")
            defaults.set(15, forKey: "fixedRestorePercent")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            hardware.outputActive = false
            hardware.ignoresVolumeWrites = true
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()
            scheduler.advance(to: 20)
            try expect(hardware.volume == 0.5, "fixture must emulate an offline volume control")

            controller.handleVolumeKey(increase: false, fine: false)
            scheduler.advance(to: 21)
            try expect(hardware.volume == 0.5, "changing volume while the Mac is idle still fails")
            hardware.ignoresVolumeWrites = false
            hardware.outputActive = true
            hardware.notifyOutputActivityChanged()
            scheduler.advance(to: 25)
            try expect(hardware.volume == 0.125, "playback should apply the requested step down from 15%")
            try expect(controller.fixedRestorePercent == 15, "keep the user's fixed restore setting")
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

    private static func testInterruptedRestoresLeaveNoPendingHistory() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.start()

            hardware.device = nil
            hardware.notifyDefaultOutputChanged()
            try expect(
                controller.dataSnapshot().history.first?.outcome == .interrupted,
                "a disconnect during restore left the entry pending"
            )

            hardware.device = device
            hardware.notifyDefaultOutputChanged()
            controller.setCurrentAirPodsVolume(0.6)
            try expect(
                controller.dataSnapshot().history.first?.outcome == .interrupted,
                "a slider change during restore left the entry pending"
            )
            controller.stop()

            let stale = AirPodsConnectionHistoryEntry(
                id: UUID(), deviceUID: device.uid, deviceName: device.name,
                connectedAt: Date(), connectedVolume: 0.5, restoredVolume: nil, outcome: .pending
            )
            defaults.set(try JSONEncoder().encode([stale]), forKey: "airPodsConnectionHistory.v1")
            let relaunched = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            try expect(
                relaunched.dataSnapshot().history.first?.outcome == .interrupted,
                "a restore pending from the previous launch was not cleaned up"
            )
        }
    }

    private static func testManualRestoreKeepsConnectionOutcome() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            controller.pauseRestores(for: nil)
            controller.start()
            scheduler.advance(to: 5)

            controller.restoreRememberedVolumeNow()
            try expect(controller.dataSnapshot().history.first?.outcome == .paused, "manual restore marked the connection pending")
            scheduler.advance(to: 10)
            try expect(hardware.volume == 0.25, "manual restore did not apply")
            try expect(controller.dataSnapshot().history.first?.outcome == .paused, "manual restore rewrote the connection outcome")
        }
    }

    private static func testStatusReportsSettling() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.9)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            var statuses: [VolumeMemoryStatus] = []
            controller.onStatusChanged = { statuses.append($0) }
            controller.start()

            try expect(
                statuses.filter({ ($0.currentVolume ?? 0) > 0.8 }).allSatisfy(\.isSettling),
                "the temporary reconnect volume was reported as settled"
            )
            scheduler.advance(to: 10)
            try expect(statuses.last?.isSettling == false, "the final restored status is still settling")
            try expect(statuses.last?.currentVolume == 0.25, "the final status has the wrong volume")

            // Without a restore, the end of settling must still publish a settled status.
            controller.pauseRestores(for: nil)
            hardware.volume = 0.9
            hardware.notifyDefaultOutputChanged()
            try expect(statuses.last?.isSettling == true, "a paused reconnect is not settling")
            scheduler.advance(to: 20)
            try expect(statuses.last?.isSettling == false, "no settled status after a paused reconnect")
            try expect(statuses.last?.currentVolume == 0.9, "the settled status has the wrong volume")
        }
    }

    private static func testConnectionNotification() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            var connections: [ConnectionNotificationEvent] = []
            var restores: [RestoreNotificationEvent] = []
            controller.onConnectionNotification = { connections.append($0) }
            controller.onRestoreNotification = { restores.append($0) }

            controller.start()
            try expect(connections.isEmpty, "notified before the volume settled")
            hardware.notifyDefaultOutputChanged() // Duplicate CoreAudio notification.
            controller.refresh()
            scheduler.advance(to: 1)
            try expect(connections.isEmpty && restores.isEmpty, "initial readback must not notify before final verification")
            scheduler.advance(to: 10)
            try expect(connections.count == 1, "expected exactly one notification, got \(connections.count)")
            try expect(connections[0].outcome == .restored, "banner must report final success")
            try expect(connections[0].volume == 0.25, "connection notification has the wrong volume")
            try expect(restores.count == 1 && restores[0].isConnectionRestore, "restore was not flagged as the connection restore")

            controller.restoreRememberedVolumeNow()
            scheduler.advance(to: 20)
            try expect(connections.count == 1, "a manual restore sent another connection notification")
            try expect(restores.count == 2 && !restores[1].isConnectionRestore, "manual restore was flagged as a connection restore")

            hardware.device = nil
            hardware.notifyDefaultOutputChanged()
            let second = AudioDevice(
                id: 43, uid: "new-airpods", name: "New AirPods", manufacturer: "Apple Inc.",
                modelUID: "NewAirPods", transportType: kAudioDeviceTransportTypeBluetooth
            )
            hardware.device = second
            hardware.volume = 0.4
            hardware.notifyDefaultOutputChanged()
            scheduler.advance(to: 30)
            try expect(connections.count == 1, "a connection without a restore must not send a restore result")

            let preferences = AppPreferences(defaults: defaults)
            try expect(preferences.connectionNotificationEnabled, "connection notifications should default to on")
            preferences.connectionNotificationEnabled = false
            try expect(!AppPreferences(defaults: defaults).connectionNotificationEnabled, "connection notification preference was not persisted")
        }
    }

    private static func testFixedRestore() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            let key = "savedOutputVolume.\(device.uid)"
            let hardware = FakeAudioHardware(device: nil, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = VolumeMemoryController(defaults: defaults, audioHardware: hardware, scheduler: scheduler)
            var notifications: [ConnectionNotificationEvent] = []
            controller.onConnectionNotification = { notifications.append($0) }
            controller.setFixedRestore(enabled: true, percent: 15)
            controller.start()
            hardware.device = device
            hardware.notifyDefaultOutputChanged()
            scheduler.advance(to: 3)
            try expect(notifications.isEmpty, "fixed restore must keep checking during handoff")
            hardware.volume = 0.5
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 6)
            try expect(hardware.volume == 0.15 && notifications.map(\.outcome) == [.restored],
                       "late handoff reset should be corrected before notification")
            controller.setCurrentAirPodsVolume(0.42)
            hardware.volume = 0.37
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 7)
            try expect(defaults.object(forKey: key) == nil, "fixed mode must not save session volume")
            hardware.device = nil
            hardware.notifyDefaultOutputChanged()
            hardware.device = device
            hardware.notifyDefaultOutputChanged()
            scheduler.advance(to: 14)
            try expect(hardware.volume == 0.15 && notifications.count == 2, "next connection uses fixed target")
            try expect(VolumeMemoryController(defaults: defaults).fixedRestoreEnabled, "mode persists")
        }
    }

    private static func testEarlyStableRestore() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.25)
            let scheduler = ManualScheduler()
            let controller = VolumeMemoryController(defaults: defaults, audioHardware: hardware, scheduler: scheduler)
            var connections: [ConnectionNotificationEvent] = []
            var status: VolumeMemoryStatus?
            controller.onConnectionNotification = { connections.append($0) }
            controller.onStatusChanged = { status = $0 }
            controller.start()
            scheduler.advance(to: 2.19)
            try expect(connections.isEmpty, "must wait for a second read")
            scheduler.advance(to: 2.2)
            try expect(connections.map(\.outcome) == [.restored], "stable restore should finish at 2.2 seconds")
            try expect(status?.isSettling == false, "early completion should settle the status")
            hardware.volume = 0.32
            hardware.notifyVolumeChanged()
            scheduler.advance(to: 10)
            try expect(hardware.setVolumes == [0.25], "early completion must cancel later writes")
            try expect(connections.count == 1, "only one final notification")
            try expect(abs(defaults.double(forKey: "savedOutputVolume.\(device.uid)") - 0.32) < 0.001,
                       "later volume changes should be remembered")
        }
    }

    private static func testConnectionNotificationCorrection() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.25, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.5)
            let scheduler = ManualScheduler()
            let controller = VolumeMemoryController(defaults: defaults, audioHardware: hardware, scheduler: scheduler)
            var connections: [ConnectionNotificationEvent] = []
            controller.onConnectionNotification = { connections.append($0) }
            controller.start()
            scheduler.advance(to: 0.2)
            try expect(connections.isEmpty, "first readback must not send a banner")
            hardware.volume = 0.5
            hardware.ignoresVolumeWrites = true
            scheduler.advance(to: 6)
            try expect(connections.isEmpty, "a retryable mismatch must not notify")
            scheduler.advance(to: 30)
            try expect(connections.map(\.outcome) == [.failed],
                       "only the final failure may send a banner")
            try expect(connections.last?.volume == 0.5, "correction should show actual volume")
        }
    }

    private static func testNotificationText() throws {
        func event(_ volume: Float?, _ outcome: RestoreHistoryOutcome, remembered: Float? = 0.35) -> ConnectionNotificationEvent {
            ConnectionNotificationEvent(deviceUID: "a", deviceName: "Pods", volume: volume,
                                        rememberedVolume: remembered, outcome: outcome)
        }
        try expect(
            NotificationText.connection(event(0.4, .restored), muted: false)
                == NotificationText(title: "恢复到 40%", body: "✅✅✅✅✅✅✅✅"),
            "restored connection text"
        )
        let warningMarks = "✅✅✅✅⚠️⚠️⚠️⚠️"
        try expect(NotificationText.connection(event(0.4, .restored), muted: false, warningThreshold: 35).body == warningMarks,
                   "restored connection above threshold uses mixed marks")
        try expect(NotificationText.connection(event(0.4, .restored), muted: false, warningThreshold: 40).body == "✅✅✅✅✅✅✅✅",
                   "equal to threshold is not above threshold")
        let manual = RestoreNotificationEvent(deviceName: "Pods", volume: 0.4, succeeded: true, isConnectionRestore: false)
        try expect(NotificationText.restore(manual, warningThreshold: 35).body == warningMarks,
                   "manual restore above threshold uses mixed marks")
        try expect(
            NotificationText.connection(event(0.62, .failed), muted: false).body == "❌❌❌❌❌❌❌❌",
            "failed connection body uses the failure mark"
        )
        try expect(
            NotificationText.connection(event(0.4, .paused), muted: true).title == "AirPods 已静音 · 40%",
            "muted title keeps the level"
        )
        try expect(NotificationText.connection(event(nil, .pending), muted: false).title == "AirPods 已连接", "unknown volume title")
        try expect(
            NotificationText.highVolume(deviceName: "Pods", volume: 0.8, threshold: 60).title == "音量过高 · 80%",
            "high-volume title"
        )
        try expect(NotificationText.connection(event(0.62, .failed), muted: false).title == "恢复失败 · 当前 62%",
                   "correction headline shows current volume")
    }

    private static func testPlaybackStallDetector() throws {
        var clock: TimeInterval = 0
        let detector = PlaybackStallDetector(now: { Date(timeIntervalSinceReferenceDate: clock) })
        var nudges: [TimeInterval] = []
        detector.onStall = { nudges.append(clock) }
        func at(_ time: TimeInterval, _ running: Bool, output: Bool? = true) {
            clock = time
            detector.deviceRunningChanged(running, outputStillActive: output)
        }

        // Recorded takeover from iPhone: start, stop 0.22 s later while Music still outputs, restart.
        at(0, true); at(0.22, false); at(0.65, true)
        try expect(nudges == [0.22], "takeover was not nudged at the stop, before sound: \(nudges)")
        // Our own pause/play right after must not trigger again.
        at(0.7, false, output: false); at(1.0, true); at(1.2, false)
        try expect(nudges.count == 1, "the nudge retriggered itself")

        // Normal start and pause on AirPods already owned by this Mac.
        at(10, false, output: false); at(20, true); at(30, false, output: false); at(40, true)
        try expect(nudges.count == 1, "a normal start or pause triggered a nudge")

        // Quick pause by the user: the player no longer reports output.
        at(50, false, output: false); at(60, true); at(60.5, false, output: false)
        try expect(nudges.count == 1, "a quick user pause triggered a nudge")

        // Unknown per-app state (macOS before 14.2) still detects the takeover.
        at(70, true); at(70.3, false, output: nil)
        try expect(nudges.count == 2, "takeover was missed without per-app state")

        // A missed start delivered as an immediate start/stop pair.
        at(80, true); at(80, false)
        try expect(nudges.count == 3, "a takeover too short to observe was missed")
    }

    private static func testMenuStatusText() throws {
        try withDefaults { defaults in
            let device = makeAirPods()
            defaults.set(0.22, forKey: "savedOutputVolume.\(device.uid)")
            let hardware = FakeAudioHardware(device: device, volume: 0.22)
            let scheduler = ManualScheduler()
            let controller = makeController(defaults: defaults, hardware: hardware, scheduler: scheduler)
            var status: VolumeMemoryStatus?
            controller.onStatusChanged = { status = $0 }
            controller.start()
            scheduler.advance(to: 10)

            guard let settled = status else { throw TestFailure("no status") }
            var lines = MenuStatusText.lines(for: settled, muted: false)
            try expect(lines.title == "Test AirPods Pro", "title should be the device name, got \(lines.title)")
            try expect(lines.detail == "下次连接时恢复到 22%", "detail: \(lines.detail)")
            try expect(MenuStatusText.lines(for: settled, muted: true).detail == "已静音", "muted detail")

            controller.pauseRestores(for: nil)
            lines = MenuStatusText.lines(for: status!, muted: false)
            try expect(lines.detail == "自动恢复已暂停，直到手动恢复", "paused detail: \(lines.detail)")

            hardware.device = nil
            hardware.notifyDefaultOutputChanged()
            lines = MenuStatusText.lines(for: status!, muted: false)
            try expect(lines.title == "当前没有可用的输出设备", "no-device title: \(lines.title)")
        }
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
                saveDebounceDelay: 0.2,
                earlyVerificationDelay: nil
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
    var ignoresVolumeWrites = false
    var outputActive: Bool?
    private var outputActivityHandler: (() -> Void)?
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
        if !ignoresVolumeWrites { self.volume = volume }
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

    func isOutputActive(for device: AudioDevice) -> Bool? { outputActive }

    func makeOutputActivityListener(
        for device: AudioDevice, handler: @escaping () -> Void
    ) throws -> AudioPropertyListening {
        outputActivityHandler = handler
        return FakeListener()
    }

    func notifyOutputActivityChanged() { outputActivityHandler?() }
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
