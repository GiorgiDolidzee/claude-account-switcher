import Darwin
import Foundation

public protocol Backupper: Sendable {
    func backup(paths: Paths, loginSet: LoginSet, to dir: URL) throws
}

/// The one-time safety copy before the first switch. On APFS the clone is instant and takes no extra space.
public struct CloneBackupper: Backupper {
    public init() {}

    static let skipped: Set<String> = ["vm_bundles"]

    public func backup(paths: Paths, loginSet: LoginSet, to dir: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: paths.appData.path) {
                // Clone each top-level entry. The VM disk is left out: it is huge, is rewritten all the
                // time (so the clone would grow to full size), and is never part of a login.
                let target = dir.appendingPathComponent("Claude")
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                for name in try fm.contentsOfDirectory(atPath: paths.appData.path) where !Self.skipped.contains(name) {
                    let source = paths.appData.appendingPathComponent(name)
                    if clonefile(source.path, target.appendingPathComponent(name).path, UInt32(CLONE_NOFOLLOW)) != 0 {
                        let code = errno
                        var st = stat()
                        let kind = lstat(source.path, &st) == 0 ? st.st_mode & S_IFMT : 0
                        // Sockets and other special files cannot be cloned and do not matter.
                        if kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK {
                            throw SwitchError.backupFailed("could not copy \(name) (errno \(code))")
                        }
                    }
                }
            }
            if fm.fileExists(atPath: paths.claudeJSON.path) {
                try fm.copyItem(at: paths.claudeJSON, to: dir.appendingPathComponent("claude.json"))
            }
            for item in loginSet.cli.claudeHomeItems {
                let source = paths.claudeHome.appendingPathComponent(item)
                guard fm.fileExists(atPath: source.path) else { continue }
                let home = dir.appendingPathComponent("claude-home")
                try fm.createDirectory(at: home, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: home.appendingPathComponent(item))
            }
        } catch let error as SwitchError {
            throw error
        } catch {
            throw SwitchError.backupFailed(error.localizedDescription)
        }
    }
}
