import Foundation

public enum SwitchError: Error, Equatable {
    case injectedFault
    case valueConflict(key: String, files: [String])
    case keychainVerifyFailed
    case busy(Blockers)
    case unknownAppOwner
    case unknownCLIOwner
    case unsavedAccount(app: AccountID?, cli: AccountID?)
    case recoveryNeeded
    case unexpected(String)
    case backupFailed(String)
    case loginSetMissing
}

/// Counts changing operations. Tests use `failAfter` to stop in the middle, like a crash.
public final class OpCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private let failAfter: Int?

    public init(failAfter: Int? = nil) { self.failAfter = failAfter }

    public var count: Int { lock.withLock { _count } }

    public func tick() throws {
        let now = lock.withLock { _count += 1; return _count }
        if let failAfter, now >= failAfter { throw SwitchError.injectedFault }
    }
}

public enum LiveSide: Sendable { case source, destination }
public enum MoveOutcome: Equatable, Sendable { case moved, skipped, collisionToStray }

func pathExists(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

/// Moves one file or folder by rename. Safe to run again after a crash.
public struct ItemMover: Sendable {
    let ops: OpCounter
    public init(ops: OpCounter) { self.ops = ops }

    public func move(_ name: String, from srcRoot: URL, to dstRoot: URL, live: LiveSide, strayRoot: URL) throws -> MoveOutcome {
        let src = srcRoot.appendingPathComponent(name)
        let dst = dstRoot.appendingPathComponent(name)
        guard pathExists(src) else { return .skipped }
        if !pathExists(dst) {
            try rename(src, dst)
            return .moved
        }
        // Both exist: something re-created the live one. Keep it in the stray folder, never delete it.
        let liveURL = live == .source ? src : dst
        var strayURL = strayRoot.appendingPathComponent(name)
        var n = 2
        while pathExists(strayURL) {
            strayURL = strayRoot.appendingPathComponent("\(name)-\(n)")
            n += 1
        }
        try rename(liveURL, strayURL)
        if live == .destination { try rename(src, dst) }
        return .collisionToStray
    }

    private func rename(_ from: URL, _ to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ops.tick()
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw SwitchError.unexpected("could not move \(from.lastPathComponent): errno \(errno)")
        }
    }
}

/// Moves top-level keys between two JSON files. Other keys stay byte-for-byte the same.
public struct KeyMover: Sendable {
    let ops: OpCounter
    public init(ops: OpCounter) { self.ops = ops }

    /// Throws if a key is in both files with different values. Changes nothing.
    public func check(keys: [String]?, from srcFile: URL, to dstFile: URL) throws {
        guard let src = try JSONFile.readRaw(srcFile), let dst = try JSONFile.readRaw(dstFile) else { return }
        for key in keys ?? src.keys {
            if let here = src[key], let there = dst[key], !JSONFile.sameValue(here, there) {
                throw SwitchError.valueConflict(key: key, files: [srcFile.lastPathComponent, dstFile.lastPathComponent])
            }
        }
    }

    /// `keys == nil` means every key in the source file.
    public func move(keys: [String]?, from srcFile: URL, to dstFile: URL, srcIsLive: Bool) throws {
        guard var src = try JSONFile.readRaw(srcFile) else { return }
        var dst = try JSONFile.readRaw(dstFile) ?? RawJSONObject()
        let wanted = (keys ?? src.keys).filter { src[$0] != nil }
        if wanted.isEmpty {
            if !srcIsLive, src.isEmpty { try remove(srcFile) }
            return
        }
        // Look first, write later: a conflict must change nothing.
        for key in wanted {
            if let there = dst[key], !JSONFile.sameValue(there, src[key]!) {
                throw SwitchError.valueConflict(key: key, files: [srcFile.lastPathComponent, dstFile.lastPathComponent])
            }
        }
        var dstChanged = false
        for key in wanted where dst[key] == nil {
            dst.set(key, src[key]!)
            dstChanged = true
        }
        if dstChanged {
            try FileManager.default.createDirectory(at: dstFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try ops.tick()
            try JSONFile.writeRaw(dst, to: dstFile)
        }
        for key in wanted { src.remove(key) }
        if !srcIsLive, src.isEmpty {
            try remove(srcFile)
        } else {
            try ops.tick()
            try JSONFile.writeRaw(src, to: srcFile)
        }
    }

    private func remove(_ file: URL) throws {
        try ops.tick()
        try FileManager.default.removeItem(at: file)
    }
}

/// Moves one Keychain secret: copy, read back, then delete the original.
public struct SecretMover: Sendable {
    let keychain: KeychainStore
    let ops: OpCounter
    public init(keychain: KeychainStore, ops: OpCounter) { self.keychain = keychain; self.ops = ops }

    public func move(from: (service: String, account: String), to: (service: String, account: String)) throws -> MoveOutcome {
        guard let secret = try keychain.read(service: from.service, account: from.account) else { return .skipped }
        if let there = try keychain.read(service: to.service, account: to.account) {
            guard there == secret else {
                throw SwitchError.valueConflict(key: "keychain", files: [from.service, to.service])
            }
        } else {
            try ops.tick()
            try keychain.write(service: to.service, account: to.account, secret: secret)
            guard try keychain.read(service: to.service, account: to.account) == secret else {
                throw SwitchError.keychainVerifyFailed
            }
        }
        try ops.tick()
        try keychain.delete(service: from.service, account: from.account)
        return .moved
    }

    /// Throws if both places hold different secrets. Changes nothing.
    public func check(from: (service: String, account: String), to: (service: String, account: String)) throws {
        guard let secret = try keychain.read(service: from.service, account: from.account),
              let there = try keychain.read(service: to.service, account: to.account) else { return }
        if there != secret { throw SwitchError.valueConflict(key: "keychain", files: [from.service, to.service]) }
    }

    /// Throws a login away (the user chose "Don't save").
    public func discard(service: String, account: String) throws {
        guard try keychain.exists(service: service, account: account) else { return }
        try ops.tick()
        try keychain.delete(service: service, account: account)
    }
}
