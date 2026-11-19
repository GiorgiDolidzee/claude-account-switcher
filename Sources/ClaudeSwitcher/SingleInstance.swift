import Foundation

/// Only one copy of the switcher may run. The lock is held until the app quits.
enum SingleInstance {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func acquire(lockFile: URL) -> Bool {
        fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
