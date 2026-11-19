import CryptoKit
import Foundation

public enum KeychainError: Error, Equatable {
    case forbiddenService
    case secretTooLong(bytes: Int)
    case commandFailed(status: Int32, step: String)
    case badName
    case timedOut
}

public protocol KeychainStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func exists(service: String, account: String) throws -> Bool
    func write(service: String, account: String, secret: Data) throws
    func delete(service: String, account: String) throws
}

public enum KeychainNames {
    /// The main CLI's login item (Claude Code's own name for it).
    public static let liveCLI = "Claude Code-credentials"
    /// Where the switcher parks main-CLI logins; account = the Claude account id.
    public static let parked = "ClaudeSwitcher CLI login"
    /// The Claude app's storage key. The switcher must never touch it.
    public static let forbidden = "Claude Safe Storage"

    public static func check(_ service: String) throws {
        if service.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(forbidden) == .orderedSame {
            throw KeychainError.forbiddenService
        }
    }

    /// The item Claude Code uses when CLAUDE_CONFIG_DIR is set to `configDir`.
    public static func sideService(configDir: String) -> String {
        let hex = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return liveCLI + "-" + hex.prefix(8)
    }
}

/// For tests. Never talks to the real Keychain.
public final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private let maxSecretBytes: Int?

    public init(maxSecretBytes: Int? = nil) { self.maxSecretBytes = maxSecretBytes }

    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    public var allEntries: [String: Data] { lock.withLock { items } }

    /// Stores without the size check (to set up a test).
    public func seed(service: String, account: String, secret: Data) {
        lock.withLock { items[key(service, account)] = secret }
    }

    public func read(service: String, account: String) throws -> Data? {
        try KeychainNames.check(service)
        return lock.withLock { items[key(service, account)] }
    }

    public func exists(service: String, account: String) throws -> Bool {
        try read(service: service, account: account) != nil
    }

    public func write(service: String, account: String, secret: Data) throws {
        try KeychainNames.check(service)
        if let max = maxSecretBytes, secret.count > max { throw KeychainError.secretTooLong(bytes: secret.count) }
        lock.withLock { items[key(service, account)] = secret }
    }

    public func delete(service: String, account: String) throws {
        try KeychainNames.check(service)
        lock.withLock { items[key(service, account)] = nil }
    }
}

/// The real Keychain, through /usr/bin/security (the same tool Claude Code uses).
/// Secrets go through pipes only: never in arguments, files or logs.
public struct SecurityCLIKeychain: KeychainStore {
    public typealias Runner = @Sendable (_ args: [String], _ stdin: Data?) throws -> (status: Int32, output: Data)

    /// `security -i` cuts a line at about 4096 bytes, so longer lines are refused.
    public static let maxLineBytes = 4000
    private static let notFound: Int32 = 44

    private let runner: Runner

    public init(runner: @escaping Runner = SecurityCLIKeychain.realRunner) { self.runner = runner }

    public func read(service: String, account: String) throws -> Data? {
        try KeychainNames.check(service)
        let result = try runner(["find-generic-password", "-s", service, "-a", account, "-w"], nil)
        if result.status == Self.notFound { return nil }
        guard result.status == 0 else { throw KeychainError.commandFailed(status: result.status, step: "read") }
        var data = result.output
        if data.last == 0x0A { data.removeLast() }
        return data
    }

    public func exists(service: String, account: String) throws -> Bool {
        try KeychainNames.check(service)
        let result = try runner(["find-generic-password", "-s", service, "-a", account], nil)
        if result.status == Self.notFound { return false }
        guard result.status == 0 else { throw KeychainError.commandFailed(status: result.status, step: "exists") }
        return true
    }

    public func write(service: String, account: String, secret: Data) throws {
        try KeychainNames.check(service)
        for name in [service, account] {
            if name.contains("\"") || name.contains("\\") || name.contains("\n") || name.contains("\r") { throw KeychainError.badName }
        }
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        guard line.utf8.count <= Self.maxLineBytes else { throw KeychainError.secretTooLong(bytes: secret.count) }
        let result = try runner(["-i"], Data(line.utf8))
        let said = String(decoding: result.output, as: UTF8.self)
        guard result.status == 0, !said.contains(": returned ") else {
            throw KeychainError.commandFailed(status: result.status, step: "write")
        }
    }

    public func delete(service: String, account: String) throws {
        try KeychainNames.check(service)
        let result = try runner(["delete-generic-password", "-s", service, "-a", account], nil)
        guard result.status == 0 || result.status == Self.notFound else {
            throw KeychainError.commandFailed(status: result.status, step: "delete")
        }
    }

    public static let realRunner: Runner = { args, stdin in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // For `-i`, failures are reported on stderr ("…: returned N"), so read it too.
        process.standardError = args == ["-i"] ? output : FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        if process.terminationReason == .uncaughtSignal { throw KeychainError.timedOut }
        return (process.terminationStatus, data)
    }
}
