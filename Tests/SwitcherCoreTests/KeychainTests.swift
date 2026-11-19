import Foundation
import Testing
@testable import SwitcherCore

final class RunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(args: [String], stdin: Data?)] = []
    var calls: [(args: [String], stdin: Data?)] { lock.withLock { _calls } }
    func add(_ args: [String], _ stdin: Data?) { lock.withLock { _calls.append((args, stdin)) } }
}

@Suite struct KeychainTests {
    func make(status: Int32 = 0, output: String = "") -> (SecurityCLIKeychain, RunnerLog) {
        let log = RunnerLog()
        let kc = SecurityCLIKeychain(runner: { args, stdin in
            log.add(args, stdin)
            return (status, Data(output.utf8))
        })
        return (kc, log)
    }

    @Test func sideServiceMatchesClaudeCode() {
        #expect(KeychainNames.sideService(configDir: "/Users/you/.claude-work") == "Claude Code-credentials-f7aef36f")
    }

    @Test func forbiddenServiceNeverRunsRunner() {
        let (kc, log) = make()
        let mem = InMemoryKeychain()
        for store in [kc, mem] as [any KeychainStore] {
            for name in ["Claude Safe Storage", " claude safe storage "] {
                #expect(throws: KeychainError.forbiddenService) { _ = try store.read(service: name, account: "a") }
                #expect(throws: KeychainError.forbiddenService) { _ = try store.exists(service: name, account: "a") }
                #expect(throws: KeychainError.forbiddenService) { try store.write(service: name, account: "a", secret: Data("x".utf8)) }
                #expect(throws: KeychainError.forbiddenService) { try store.delete(service: name, account: "a") }
            }
        }
        #expect(log.calls.isEmpty)
    }

    @Test func writeSendsSecretOnlyOnStdin() throws {
        let (kc, log) = make()
        let secret = #"{"accessToken":"sk-test"}"#
        try kc.write(service: "ClaudeSwitcher CLI login", account: "abc", secret: Data(secret.utf8))
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(log.calls.count == 1)
        #expect(log.calls[0].args == ["-i"])
        let joined = log.calls[0].args.joined(separator: " ")
        #expect(!joined.contains(secret) && !joined.contains(hex))
        #expect(log.calls[0].stdin == Data("add-generic-password -U -a \"abc\" -s \"ClaudeSwitcher CLI login\" -X \(hex)\n".utf8))
    }

    @Test func writeRejectsLongSecretWithoutRunning() {
        let (kc, log) = make()
        #expect(throws: KeychainError.secretTooLong(bytes: 2000)) {
            try kc.write(service: "s", account: "a", secret: Data(repeating: 65, count: 2000))
        }
        #expect(log.calls.isEmpty)
    }

    @Test func writeFailsWhenOutputSaysReturned() {
        let (kc, _) = make(status: 0, output: "add-generic-password: returned 45")
        #expect(throws: KeychainError.self) { try kc.write(service: "s", account: "a", secret: Data("x".utf8)) }
    }

    @Test func writeRejectsBadNames() {
        let (kc, log) = make()
        for bad in ["a\"b", "a\\b", "a\nb"] {
            #expect(throws: KeychainError.badName) { try kc.write(service: "s", account: bad, secret: Data("x".utf8)) }
        }
        #expect(log.calls.isEmpty)
    }

    @Test func readStripsOneTrailingNewline() throws {
        let (kc, log) = make(status: 0, output: "abc\n\n")
        #expect(try kc.read(service: "s", account: "a") == Data("abc\n".utf8))
        #expect(log.calls[0].args == ["find-generic-password", "-s", "s", "-a", "a", "-w"])
    }

    @Test func readMissingIsNil() throws {
        let (kc, _) = make(status: 44)
        #expect(try kc.read(service: "s", account: "a") == nil)
        #expect(try kc.exists(service: "s", account: "a") == false)
    }

    @Test func readOtherFailureThrows() {
        let (kc, _) = make(status: 1)
        #expect(throws: KeychainError.self) { _ = try kc.read(service: "s", account: "a") }
    }

    @Test func existsUsesNoDashW() throws {
        let (kc, log) = make(status: 0, output: "attributes")
        #expect(try kc.exists(service: "s", account: "a"))
        #expect(!log.calls[0].args.contains("-w"))
    }

    @Test func deleteToleratesMissing() throws {
        let (kc, log) = make(status: 44)
        try kc.delete(service: "s", account: "a")
        #expect(log.calls[0].args == ["delete-generic-password", "-s", "s", "-a", "a"])
    }

    @Test func inMemoryRoundTrip() throws {
        let mem = InMemoryKeychain()
        #expect(try mem.read(service: "s", account: "a") == nil)
        try mem.write(service: "s", account: "a", secret: Data("x".utf8))
        #expect(try mem.exists(service: "s", account: "a"))
        #expect(try mem.read(service: "s", account: "a") == Data("x".utf8))
        try mem.delete(service: "s", account: "a")
        #expect(try !mem.exists(service: "s", account: "a"))
    }

    @Test func inMemoryMaxSecretBytes() throws {
        let mem = InMemoryKeychain(maxSecretBytes: 3)
        #expect(throws: KeychainError.secretTooLong(bytes: 4)) { try mem.write(service: "s", account: "a", secret: Data("abcd".utf8)) }
        mem.seed(service: "s", account: "a", secret: Data("abcd".utf8))
        #expect(try mem.read(service: "s", account: "a") == Data("abcd".utf8))
    }
}
