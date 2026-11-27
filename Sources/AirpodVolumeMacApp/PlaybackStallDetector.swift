import Foundation

/// Recognises an AirPods takeover from another Apple device while a player starts.
///
/// Playback first starts on Bluetooth's placeholder device. When macOS takes the
/// AirPods over, the device stops within a fraction of a second and starts again
/// on the real profile, while the player still reports output. Some players
/// (Apple Music among them) then stay silent until paused and resumed, but not
/// every time, and nothing public tells the two apart. So the nudge happens at
/// that stop, before any sound reaches the AirPods: when the player would have
/// worked anyway, the only cost is a slightly later start. A normal start on
/// AirPods already owned by this Mac never stops this quickly.
final class PlaybackStallDetector {
    struct Timing {
        /// The takeover stops the device within this long after playback starts.
        var maxRunBeforeStop: TimeInterval = 1.0
        /// Ignore the device restarting while the player is being nudged.
        var cooldown: TimeInterval = 3.0
    }

    var onStall: (() -> Void)?

    private let timing: Timing
    private let now: () -> Date
    private var startedAt: Date?
    private var quietUntil: Date?

    init(timing: Timing = Timing(), now: @escaping () -> Date = Date.init) {
        self.timing = timing
        self.now = now
    }

    func reset() {
        startedAt = nil
    }

    /// - Parameter outputStillActive: whether an app still reports output on the
    ///   device, or nil when the system cannot tell.
    func deviceRunningChanged(_ running: Bool, outputStillActive: Bool?) {
        let time = now()
        if let quietUntil, time < quietUntil {
            startedAt = nil
            return
        }
        if running {
            startedAt = startedAt ?? time
            return
        }
        defer { startedAt = nil }
        // A player the user paused no longer reports output; only a takeover keeps it.
        guard let startedAt,
              time.timeIntervalSince(startedAt) <= timing.maxRunBeforeStop,
              outputStillActive != false else {
            return
        }
        quietUntil = time.addingTimeInterval(timing.cooldown)
        onStall?()
    }
}
