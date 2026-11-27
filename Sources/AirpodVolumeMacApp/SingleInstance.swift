import Darwin
import Foundation

/// An advisory lock lives for the entire process. Never unlink the file while it
/// may be locked: a new inode would let another process acquire a second lock.
final class SingleInstance {
    static let showWindowNotification = Notification.Name("com.akhan.AirpodVolumeMacApp.showDeviceManager")
    private let descriptor: Int32

    init(lockURL: URL) throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func acquire() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK || errno == EAGAIN { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    deinit { Darwin.close(descriptor) }

    static var defaultLockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AirPodsVolumeMemory/instance.lock")
    }
}
