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
        case .iconOnly: return "Icon only"
        case .iconAndPercentage: return "Icon and percentage"
        case .compactText: return "AirPods and percentage"
        case .deviceName: return "Device name and percentage"
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
        case .off: return "Off"
        case .failuresOnly: return "Failures only"
        case .allResults: return "All restore results"
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

    var onMenuBarDisplayModeChanged: (() -> Void)?
    var onRestoreNotificationModeChanged: ((RestoreNotificationMode) -> Void)?

    private let defaults: UserDefaults
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let restoreNotificationModeKey = "restoreNotificationMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarDisplayMode = MenuBarDisplayMode(
            rawValue: defaults.string(forKey: menuBarDisplayModeKey) ?? ""
        ) ?? .compactText
        restoreNotificationMode = RestoreNotificationMode(
            rawValue: defaults.string(forKey: restoreNotificationModeKey) ?? ""
        ) ?? .off
    }
}

final class RestoreNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func modeChanged(_ mode: RestoreNotificationMode) {
        guard mode != .off else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ event: RestoreNotificationEvent, mode: RestoreNotificationMode) {
        guard mode == .allResults || (mode == .failuresOnly && !event.succeeded) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.succeeded ? "AirPods Volume Restored" : "AirPods Restore Failed"
        if let volume = event.volume {
            let percent = Int((min(max(volume, 0), 1) * 100).rounded())
            content.body = event.succeeded
                ? "\(event.deviceName) was restored to \(percent)%."
                : "\(event.deviceName) remained at \(percent)%. Open AirPods Volume to retry."
        } else {
            content.body = "Could not verify the volume for \(event.deviceName). Open AirPods Volume to retry."
        }
        content.sound = event.succeeded ? nil : .default

        let request = UNNotificationRequest(
            identifier: "airpods-volume-restore-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
