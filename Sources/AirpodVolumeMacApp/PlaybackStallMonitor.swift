import AppKit
import ApplicationServices
import CoreAudio

/// Watches the AirPods output for the takeover pattern PlaybackStallDetector
/// recognises and restarts the player with the play/pause media key, which is
/// what the user would otherwise do by hand.
final class PlaybackStallMonitor {
    /// Checked when a stall is detected, so the setting applies immediately.
    var isEnabled: () -> Bool = { true }

    private let detector = PlaybackStallDetector()
    private var defaultOutputListener: AudioPropertyListening?
    private var runningListener: AudioPropertyListening?
    private var deviceID: AudioDeviceID?
    private var lastRunning = false

    init() {
        detector.onStall = { [weak self] in
            guard let self, self.isEnabled(), AXIsProcessTrusted() else { return }
            MediaKeys.restartPlayback()
        }
    }

    func start() {
        stop()
        defaultOutputListener = try? AudioHardware.makeDefaultOutputDeviceListener { [weak self] in
            self?.attachToDefaultOutput()
        }
        attachToDefaultOutput()
    }

    func stop() {
        defaultOutputListener?.invalidate()
        runningListener?.invalidate()
        defaultOutputListener = nil
        runningListener = nil
        deviceID = nil
        detector.reset()
    }

    private func attachToDefaultOutput() {
        guard let device = try? AudioHardware.defaultOutputDevice(), device.isAirPods else {
            runningListener?.invalidate()
            runningListener = nil
            deviceID = nil
            detector.reset()
            return
        }
        guard device.id != deviceID else { return }
        runningListener?.invalidate()
        deviceID = device.id
        lastRunning = AudioHardware.isRunningSomewhere(device.id)
        detector.reset()
        runningListener = try? AudioHardware.makeRunningListener(for: device.id) { [weak self] in
            self?.runningChanged()
        }
    }

    private func runningChanged() {
        guard let deviceID else { return }
        let running = AudioHardware.isRunningSomewhere(deviceID)
        let output = AudioHardware.anyProcessOutputting(on: deviceID)
        if !running && !lastRunning {
            // The takeover can start and stop the device within ~70 ms, before this
            // callback reads the property. A change we did not see was that start.
            detector.deviceRunningChanged(true, outputStillActive: output)
        }
        detector.deviceRunningChanged(running, outputStillActive: output)
        lastRunning = running
    }
}

enum MediaKeys {
    /// Pause, then play again shortly after: the player reopens its audio output.
    static func restartPlayback() {
        pressPlayPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pressPlayPause() }
    }

    private static func pressPlayPause() {
        post(keyDown: true)
        post(keyDown: false)
    }

    private static func post(keyDown: Bool) {
        // NX_KEYTYPE_PLAY from IOKit's ev_keymap.h; subtype 8 is the media-key event.
        let playKey = 16
        let state = keyDown ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (playKey << 16) | (state << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt, which offers to open the Accessibility settings.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
