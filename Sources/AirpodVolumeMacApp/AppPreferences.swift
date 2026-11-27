import Combine
import Foundation
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly
    case iconAndPercentage
    case compactText
    case deviceName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .iconAndPercentage: return "图标和百分比"
        case .compactText: return "AirPods 和百分比"
        case .deviceName: return "设备名称和百分比"
        }
    }
}

enum RestoreNotificationMode: String, CaseIterable, Identifiable {
    case off
    case failuresOnly
    case allResults

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .failuresOnly: return "仅失败时通知"
        case .allResults: return "所有恢复结果"
        }
    }
}

final class AppPreferences: ObservableObject {
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            defaults.set(menuBarDisplayMode.rawValue, forKey: menuBarDisplayModeKey)
            onMenuBarDisplayModeChanged?()
        }
    }

    @Published var restoreNotificationMode: RestoreNotificationMode {
        didSet {
            defaults.set(restoreNotificationMode.rawValue, forKey: restoreNotificationModeKey)
            onRestoreNotificationModeChanged?(restoreNotificationMode)
        }
    }

    @Published var highVolumeWarningEnabled: Bool {
        didSet {
            defaults.set(highVolumeWarningEnabled, forKey: "highVolumeWarningEnabled")
            onHighVolumeWarningChanged?()
        }
    }

    @Published var highVolumeThreshold: Double {
        didSet {
            defaults.set(highVolumeThreshold, forKey: "highVolumeThreshold")
            onHighVolumeWarningChanged?()
        }
    }

    @Published var connectionNotificationEnabled: Bool {
        didSet {
            defaults.set(connectionNotificationEnabled, forKey: connectionNotificationEnabledKey)
            onConnectionNotificationChanged?()
        }
    }

    @Published var fixSilentSwitchEnabled: Bool {
        didSet {
            defaults.set(fixSilentSwitchEnabled, forKey: fixSilentSwitchEnabledKey)
            onFixSilentSwitchChanged?()
        }
    }

    var onHighVolumeWarningChanged: (() -> Void)?
    var onFixSilentSwitchChanged: (() -> Void)?
    var onConnectionNotificationChanged: (() -> Void)?
    var onMenuBarDisplayModeChanged: (() -> Void)?
    var onRestoreNotificationModeChanged: ((RestoreNotificationMode) -> Void)?

    private let defaults: UserDefaults
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let restoreNotificationModeKey = "restoreNotificationMode"
    private let connectionNotificationEnabledKey = "connectionNotificationEnabled"
    private let fixSilentSwitchEnabledKey = "fixSilentSwitchEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        highVolumeWarningEnabled = defaults.object(forKey: "highVolumeWarningEnabled") == nil
            ? true : defaults.bool(forKey: "highVolumeWarningEnabled")
        let threshold = defaults.object(forKey: "highVolumeThreshold") == nil
            ? 60 : defaults.double(forKey: "highVolumeThreshold")
        highVolumeThreshold = threshold.isFinite ? min(max(threshold, 1), 100) : 60
        menuBarDisplayMode = MenuBarDisplayMode(
            rawValue: defaults.string(forKey: menuBarDisplayModeKey) ?? ""
        ) ?? .compactText
        restoreNotificationMode = RestoreNotificationMode(
            rawValue: defaults.string(forKey: restoreNotificationModeKey) ?? ""
        ) ?? .off
        connectionNotificationEnabled = defaults.object(forKey: connectionNotificationEnabledKey) == nil
            ? true : defaults.bool(forKey: connectionNotificationEnabledKey)
        // Opt-in: it presses media keys, which not every setup needs.
        fixSilentSwitchEnabled = defaults.bool(forKey: fixSilentSwitchEnabledKey)
    }

    var anyNotificationEnabled: Bool {
        highVolumeWarningEnabled || connectionNotificationEnabled || restoreNotificationMode != .off
    }
}

final class RestoreNotificationManager: NSObject, UNUserNotificationCenterDelegate {

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Always ask for every option at once: macOS shows the prompt only the first
    /// time, so options requested later are never granted.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliverConnection(_ event: ConnectionNotificationEvent, muted: Bool, warningThreshold: Double? = nil) {
        let text = NotificationText.connection(event, muted: muted, warningThreshold: warningThreshold)
        // One banner per device: a quick reconnect replaces the previous one.
        add(identifier: "airpods-connected-\(event.deviceUID)", text: text,
            sound: event.outcome == .failed)
    }

    func deliverHighVolumeWarning(deviceName: String, volume: Float, threshold: Int) {
        // Silent banner: the warning itself should not add a loud sound.
        add(identifier: "airpods-high-volume-warning",
            text: NotificationText.highVolume(deviceName: deviceName, volume: volume, threshold: threshold),
            sound: false)
    }

    func modeChanged(_ mode: RestoreNotificationMode) {
        guard mode != .off else {
            return
        }
        requestAuthorization()
    }

    func deliver(_ event: RestoreNotificationEvent, mode: RestoreNotificationMode, warningThreshold: Double? = nil) {
        guard mode == .allResults || (mode == .failuresOnly && !event.succeeded) else {
            return
        }
        add(identifier: "airpods-volume-restore-\(UUID().uuidString)", text: NotificationText.restore(event, warningThreshold: warningThreshold),
            sound: !event.succeeded)
    }

    private func add(identifier: String, text: NotificationText, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Notification wording: the volume is the headline, the device and what
/// happened go on the second line.
struct NotificationText: Equatable {
    let title: String
    let body: String

    private static let successMarks = String(repeating: "✅", count: 8)
    private static let failureMarks = String(repeating: "❌", count: 8)

    static func connection(_ event: ConnectionNotificationEvent, muted: Bool, warningThreshold: Double? = nil) -> NotificationText {
        let title: String
        if let volume = event.volume, event.outcome == .restored {
            title = "恢复到 \(percent(volume))" + (muted ? " · 静音" : "")
        } else if event.outcome == .failed {
            title = event.volume.map { "恢复失败 · 当前 \(percent($0))" } ?? "恢复失败"
        } else {
            title = headline(volume: event.volume, muted: muted)
        }
        let body: String
        switch event.outcome {
        case .restored: body = successBody(volume: event.volume, warningThreshold: muted ? nil : warningThreshold)
        case .failed: body = failureMarks
        default: body = event.deviceName
        }
        return NotificationText(title: title, body: body)
    }

    static func restore(_ event: RestoreNotificationEvent, warningThreshold: Double? = nil) -> NotificationText {
        let title = event.succeeded
            ? (event.volume.map { "恢复到 \(percent($0))" } ?? "音量已恢复")
            : (event.volume.map { "恢复失败 · 当前 \(percent($0))" } ?? "恢复失败")
        return NotificationText(title: title, body: event.succeeded ? successBody(volume: event.volume, warningThreshold: warningThreshold) : failureMarks)
    }

    static func highVolume(deviceName: String, volume: Float, threshold: Int) -> NotificationText {
        NotificationText(
            title: "音量过高 · \(percent(volume))",
            body: "\(deviceName) · 已超过提醒阈值 \(threshold)%，可适当调低"
        )
    }

    private static func successBody(volume: Float?, warningThreshold: Double?) -> String {
        guard let volume, let warningThreshold,
              exceedsWarningThreshold(volume, threshold: warningThreshold) else { return successMarks }
        return "✅✅✅✅⚠️⚠️⚠️⚠️"
    }

    static func exceedsWarningThreshold(_ volume: Float, threshold: Double) -> Bool {
        volume.isFinite && Double(volume) * 100 > threshold + 0.0001
    }

    private static func headline(volume: Float?, muted: Bool) -> String {
        guard let volume else { return "AirPods 已连接" }
        return muted ? "AirPods 已静音 · \(percent(volume))" : "AirPods 音量 \(percent(volume))"
    }

    private static func percent(_ volume: Float) -> String {
        "\(Int((min(max(volume, 0), 1) * 100).rounded()))%"
    }
}

/// Tracks threshold crossings independently of UI rendering frequency.
struct HighVolumeWarningGate {
    private var warnedDevice: String?

    mutating func shouldWarn(deviceUID: String?, volume: Float?, enabled: Bool, threshold: Double) -> Bool {
        guard enabled, let uid = deviceUID, let volume, volume.isFinite else {
            warnedDevice = nil
            return false
        }
        guard NotificationText.exceedsWarningThreshold(volume, threshold: threshold) else {
            warnedDevice = nil
            return false
        }
        guard warnedDevice != uid else { return false }
        warnedDevice = uid
        return true
    }
}
