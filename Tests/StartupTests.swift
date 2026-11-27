import Foundation

private enum TestError: Error { case failed(String), registration }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestError.failed(message) }
}

private final class FakeLoginBackend: LoginStartupBackend {
    var native: NativeLoginStatus = .notRegistered
    var installed = true
    var loaded = true
    var disabled = false
    var registrationFails = false
    var registrationNeedsApproval = false
    var registrations = 0
    var unregisters = 0
    var legacyDisables = 0
    var settingsOpens = 0
    func snapshot() -> LoginStartupSnapshot {
        LoginStartupSnapshot(nativeStatus: native, legacyInstalled: installed, legacyLoaded: loaded, legacyDisabled: disabled)
    }
    func registerNative() throws {
        registrations += 1
        if registrationFails { throw TestError.registration }
        native = registrationNeedsApproval ? .requiresApproval : .enabled
    }
    func unregisterNative() throws { unregisters += 1; native = .notRegistered }
    func disableLegacy() throws { legacyDisables += 1; disabled = true; installed = false }
    func openSystemSettings() { settingsOpens += 1 }
}

@main
enum StartupTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--try-lock" {
            let lock = try SingleInstance(lockURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            exit(try lock.acquire() ? 0 : 42)
        }
        try testSingleInstanceAcrossProcesses()
        try testMigrationSuccessKeepsLegacyUntilInstaller()
        try testApprovalKeepsLegacyFallback()
        try testRegistrationFailureKeepsLegacyFallback()
        try testTurningOffDisablesBothMechanisms()
        try testDisabledLegacyIsNotReportedAsEnabled()
        try testBackgroundRefresh()
        print("7 startup tests passed")
    }

    static func testSingleInstanceAcrossProcesses() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("instance.lock")
        var first: SingleInstance? = try SingleInstance(lockURL: url)
        try expect(try first!.acquire(), "first instance acquires lock")
        func probe() throws -> Int32 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--try-lock", url.path]
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus
        }
        try expect(try probe() == 42, "another process must not acquire held lock")
        first = nil
        try expect(try probe() == 0, "normal exit releases lock without deleting lock file")
        try expect(FileManager.default.fileExists(atPath: url.path), "lock inode must remain stable")
        print("✓ single-instance lock works across processes and releases on exit")
    }
    static func testMigrationSuccessKeepsLegacyUntilInstaller() throws {
        let backend = FakeLoginBackend()
        let controller = LoginItemController(backend: backend)
        controller.prepareLegacyMigration()
        try expect(controller.state.nativeStatus == .enabled, "read back enabled state")
        try expect(backend.installed && backend.legacyDisables == 0, "installer owns legacy removal")
        print("✓ successful migration defers old-job removal to installer")
    }
    static func testApprovalKeepsLegacyFallback() throws {
        let backend = FakeLoginBackend()
        backend.registrationNeedsApproval = true
        let controller = LoginItemController(backend: backend)
        controller.prepareLegacyMigration()
        controller.prepareLegacyMigration()
        try expect(controller.state.isEnabled && controller.state.requiresApproval, "pending approval retains actual legacy startup")
        try expect(backend.registrations == 1 && backend.installed, "do not repeatedly register or remove fallback")
        print("✓ pending approval preserves existing startup")
    }
    static func testRegistrationFailureKeepsLegacyFallback() throws {
        let backend = FakeLoginBackend()
        backend.registrationFails = true
        let controller = LoginItemController(backend: backend)
        controller.prepareLegacyMigration()
        try expect(controller.state.isEnabled && controller.lastError != nil && backend.installed, "failed registration must keep fallback and report error")
        print("✓ registration failure preserves existing startup and reports error")
    }
    static func testTurningOffDisablesBothMechanisms() throws {
        let backend = FakeLoginBackend()
        backend.native = .enabled
        let controller = LoginItemController(backend: backend)
        try controller.setEnabled(false)
        try expect(backend.unregisters == 1 && backend.legacyDisables == 1, "turning off handles both startup mechanisms")
        try expect(!controller.state.isEnabled && backend.loaded, "disabled legacy may keep current process running without future startup")
        print("✓ turning off disables native and legacy startup without killing current process")
    }
    static func testDisabledLegacyIsNotReportedAsEnabled() throws {
        let backend = FakeLoginBackend()
        backend.disabled = true
        let controller = LoginItemController(backend: backend)
        controller.prepareLegacyMigration()
        try expect(!controller.state.isEnabled && backend.registrations == 0, "do not silently re-enable startup after user disabled it")
        print("✓ disabled old startup remains disabled")
    }
    static func testBackgroundRefresh() throws {
        let backend = FakeLoginBackend()
        let controller = LoginItemController(backend: backend)
        backend.native = .enabled
        var completions = 0
        controller.refreshInBackground { completions += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try expect(completions == 1 && controller.state.nativeStatus == .enabled, "background refresh applies its result")

        controller.refreshInBackground { completions += 1 }
        backend.native = .notRegistered
        controller.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try expect(completions == 1 && controller.state.nativeStatus == .notRegistered, "a newer synchronous refresh must win")
        print("✓ background refresh never overwrites a newer state")
    }
}
