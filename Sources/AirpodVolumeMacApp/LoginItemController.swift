import AppKit
import Combine
import Foundation
import ServiceManagement

enum NativeLoginStatus: String {
    case enabled, requiresApproval, notRegistered, notFound
}

struct LoginStartupSnapshot: Equatable {
    let nativeStatus: NativeLoginStatus
    let legacyInstalled: Bool
    let legacyLoaded: Bool
    let legacyDisabled: Bool

    var legacyEnabled: Bool { (legacyInstalled || legacyLoaded) && !legacyDisabled }
    var isEnabled: Bool { nativeStatus == .enabled || legacyEnabled }
    var requiresApproval: Bool { nativeStatus == .requiresApproval }
    var summary: String {
        if legacyEnabled {
            return nativeStatus == .enabled
                ? "已开启（旧启动项等待完成迁移）" : "已开启（旧启动项，待迁移）"
        }
        switch nativeStatus {
        case .enabled: return "已开启"
        case .requiresApproval: return "等待系统批准"
        case .notRegistered, .notFound: return "已关闭"
        }
    }
}

protocol LoginStartupBackend {
    func snapshot() -> LoginStartupSnapshot
    func registerNative() throws
    func unregisterNative() throws
    func disableLegacy() throws
    func openSystemSettings()
}

final class SystemLoginStartupBackend: LoginStartupBackend {
    static let legacyLabel = "local.airpods-volume-memory"
    private let fileManager = FileManager.default
    private var legacyURL: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.legacyLabel).plist")
    }
    private var domain: String { "gui/\(getuid())" }

    func snapshot() -> LoginStartupSnapshot {
        let native: NativeLoginStatus
        switch SMAppService.mainApp.status {
        case .enabled: native = .enabled
        case .requiresApproval: native = .requiresApproval
        case .notFound: native = .notFound
        default: native = .notRegistered
        }
        let disabledText = (try? launchctl(["print-disabled", domain]).output) ?? ""
        let disabled = disabledText.range(
            of: "\"\(Self.legacyLabel)\" => true", options: .literal
        ) != nil
        let loaded = (try? launchctl(["print", "\(domain)/\(Self.legacyLabel)"]).status) == 0
        return LoginStartupSnapshot(
            nativeStatus: native,
            legacyInstalled: fileManager.fileExists(atPath: legacyURL.path),
            legacyLoaded: loaded,
            legacyDisabled: disabled
        )
    }

    func registerNative() throws { try SMAppService.mainApp.register() }
    func unregisterNative() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func disableLegacy() throws {
        // Only touch the precise legacy service we installed, never other jobs.
        if fileManager.fileExists(atPath: legacyURL.path) {
            let data = try Data(contentsOf: legacyURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["Label"] as? String == Self.legacyLabel,
                  let arguments = plist["ProgramArguments"] as? [String],
                  arguments.first == "/Applications/AirpodVolumeMacApp.app/Contents/MacOS/AirpodVolumeMacApp" else {
                throw NSError(domain: "LoginStartup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "旧启动项内容与预期不符，未更改。"
                ])
            }
        }
        let result = try launchctl(["disable", "\(domain)/\(Self.legacyLabel)"])
        guard result.status == 0 else {
            throw NSError(domain: "LoginStartup", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "无法禁用旧启动项：\(result.output)"
            ])
        }
        if fileManager.fileExists(atPath: legacyURL.path) {
            let archive = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AirPodsVolumeMemory/StartupBackups")
            try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacyURL, to: archive.appendingPathComponent("\(UUID().uuidString).plist"))
        }
        // Do not bootout our own job here. It may own this process. The running
        // process stays available; exit(0) will not trigger its old KeepAlive.
        // The external update script removes the loaded job during migration.
    }

    private func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

final class LoginItemController: ObservableObject {
    @Published private(set) var state: LoginStartupSnapshot
    @Published private(set) var lastError: String?
    private let backend: LoginStartupBackend
    private var refreshGeneration = 0

    init(backend: LoginStartupBackend = SystemLoginStartupBackend()) {
        self.backend = backend
        state = backend.snapshot()
    }

    func refresh() {
        refreshGeneration += 1
        state = backend.snapshot()
    }

    /// Reads the startup state on a background queue. A newer synchronous refresh
    /// (e.g. after a toggle) wins over this result if it arrives first.
    func refreshInBackground(completion: @escaping () -> Void) {
        refreshGeneration += 1
        let generation = refreshGeneration
        let backend = self.backend
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = backend.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.state = snapshot
                completion()
            }
        }
    }

    /// Registration success alone is not approval: always read back the status.
    func prepareLegacyMigration() {
        refresh()
        guard state.legacyEnabled, state.nativeStatus != .enabled,
              state.nativeStatus != .requiresApproval else { return }
        do {
            try backend.registerNative()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) throws {
        lastError = nil
        do {
            if enabled {
                if state.requiresApproval { backend.openSystemSettings() }
                else if state.nativeStatus != .enabled { try backend.registerNative() }
            } else {
                if state.nativeStatus == .enabled || state.requiresApproval {
                    try backend.unregisterNative()
                }
                if state.legacyInstalled || state.legacyLoaded { try backend.disableLegacy() }
            }
        } catch {
            lastError = error.localizedDescription
            refresh()
            throw error
        }
        refresh()
    }

    func openSettings() { backend.openSystemSettings() }
}
