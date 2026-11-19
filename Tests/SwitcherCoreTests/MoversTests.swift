import Foundation
import Testing
@testable import SwitcherCore

/// A keychain whose writes silently do nothing.
final class LyingKeychain: KeychainStore, @unchecked Sendable {
    let inner = InMemoryKeychain()
    func read(service: String, account: String) throws -> Data? { try inner.read(service: service, account: account) }
    func exists(service: String, account: String) throws -> Bool { try inner.exists(service: service, account: account) }
    func write(service: String, account: String, secret: Data) throws {}
    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}

@Suite struct MoversTests {
    let fx = Fixture()
    var live: URL { fx.root.appendingPathComponent("live") }
    var parked: URL { fx.root.appendingPathComponent("parked/deep") }
    var stray: URL { fx.root.appendingPathComponent("stray") }
    var items: ItemMover { ItemMover(ops: OpCounter()) }
    var keys: KeyMover { KeyMover(ops: OpCounter()) }

    @Test func itemMovesFileAndFolder() throws {
        fx.write("c", to: live.appendingPathComponent("Cookies"))
        fx.write("x", to: live.appendingPathComponent("Local Storage/a/b"))
        #expect(try items.move("Cookies", from: live, to: parked, live: .source, strayRoot: stray) == .moved)
        #expect(try items.move("Local Storage", from: live, to: parked, live: .source, strayRoot: stray) == .moved)
        #expect(fx.read(parked.appendingPathComponent("Cookies")) == "c")
        #expect(fx.read(parked.appendingPathComponent("Local Storage/a/b")) == "x")
        #expect(!fx.fm.fileExists(atPath: live.appendingPathComponent("Cookies").path))
    }

    @Test func itemMoveTwiceSkips() throws {
        fx.write("c", to: live.appendingPathComponent("Cookies"))
        _ = try items.move("Cookies", from: live, to: parked, live: .source, strayRoot: stray)
        #expect(try items.move("Cookies", from: live, to: parked, live: .source, strayRoot: stray) == .skipped)
        #expect(fx.read(parked.appendingPathComponent("Cookies")) == "c")
    }

    @Test func parkCollisionSendsLiveToStray() throws {
        fx.write("new", to: live.appendingPathComponent("Cookies"))
        fx.write("saved", to: parked.appendingPathComponent("Cookies"))
        #expect(try items.move("Cookies", from: live, to: parked, live: .source, strayRoot: stray) == .collisionToStray)
        #expect(fx.read(parked.appendingPathComponent("Cookies")) == "saved")
        #expect(fx.read(stray.appendingPathComponent("Cookies")) == "new")
        #expect(!fx.fm.fileExists(atPath: live.appendingPathComponent("Cookies").path))
    }

    @Test func unparkCollisionSendsLiveToStrayThenMoves() throws {
        fx.write("new", to: live.appendingPathComponent("Cookies"))
        fx.write("saved", to: parked.appendingPathComponent("Cookies"))
        #expect(try items.move("Cookies", from: parked, to: live, live: .destination, strayRoot: stray) == .collisionToStray)
        #expect(fx.read(live.appendingPathComponent("Cookies")) == "saved")
        #expect(fx.read(stray.appendingPathComponent("Cookies")) == "new")
        #expect(!fx.fm.fileExists(atPath: parked.appendingPathComponent("Cookies").path))
    }

    @Test func strayNamesDoNotOverwrite() throws {
        fx.write("old-stray", to: stray.appendingPathComponent("Cookies"))
        fx.write("new", to: live.appendingPathComponent("Cookies"))
        fx.write("saved", to: parked.appendingPathComponent("Cookies"))
        _ = try items.move("Cookies", from: live, to: parked, live: .source, strayRoot: stray)
        #expect(fx.read(stray.appendingPathComponent("Cookies")) == "old-stray")
        #expect(fx.read(stray.appendingPathComponent("Cookies-2")) == "new")
    }

    var liveFile: URL { fx.root.appendingPathComponent("config.json") }
    var parkedFile: URL { fx.root.appendingPathComponent("acc/app-login.json") }

    @Test func keysMoveAndOthersStayByteForByte() throws {
        fx.write(#"{"locale":"en","n":1.1,"tok":{"a":0.1},"id":"x"}"#, to: liveFile)
        try keys.move(keys: ["tok", "id", "absent"], from: liveFile, to: parkedFile, srcIsLive: true)
        #expect(fx.read(liveFile) == #"{"locale":"en","n":1.1}"#)
        #expect(fx.read(parkedFile) == #"{"tok":{"a":0.1},"id":"x"}"#)
        try keys.move(keys: nil, from: parkedFile, to: liveFile, srcIsLive: false)
        #expect(fx.read(liveFile) == #"{"locale":"en","n":1.1,"tok":{"a":0.1},"id":"x"}"#)
        #expect(!fx.fm.fileExists(atPath: parkedFile.path))
    }

    @Test func keysEqualInBothFinishesMove() throws {
        fx.write(#"{"locale":"en","tok": {"a":1}}"#, to: liveFile)
        fx.write(#"{"tok":{"a":1}}"#, to: parkedFile)
        try keys.move(keys: ["tok"], from: liveFile, to: parkedFile, srcIsLive: true)
        #expect(fx.read(liveFile) == #"{"locale":"en"}"#)
        #expect(fx.read(parkedFile) == #"{"tok":{"a":1}}"#)
    }

    @Test func keysDifferentThrowsAndWritesNothing() throws {
        fx.write(#"{"locale":"en","tok":"A","id":"x"}"#, to: liveFile)
        fx.write(#"{"tok":"B"}"#, to: parkedFile)
        #expect(throws: SwitchError.self) { try keys.move(keys: ["id", "tok"], from: liveFile, to: parkedFile, srcIsLive: true) }
        #expect(fx.read(liveFile) == #"{"locale":"en","tok":"A","id":"x"}"#)
        #expect(fx.read(parkedFile) == #"{"tok":"B"}"#)
    }

    @Test func liveFileIsNeverDeletedAndMissingFilesAreFine() throws {
        fx.write(#"{"tok":"A"}"#, to: liveFile)
        try keys.move(keys: ["tok"], from: liveFile, to: parkedFile, srcIsLive: true)
        #expect(fx.read(liveFile) == "{}")
        try fx.fm.removeItem(at: liveFile)
        try keys.move(keys: ["tok"], from: liveFile, to: parkedFile, srcIsLive: true)   // nothing to do
        #expect(!fx.fm.fileExists(atPath: liveFile.path))
        try keys.move(keys: nil, from: parkedFile, to: liveFile, srcIsLive: false)      // creates the live file
        #expect(fx.read(liveFile) == #"{"tok":"A"}"#)
        #expect(try fx.fm.attributesOfItem(atPath: liveFile.path)[.posixPermissions] as? Int == 0o600)
    }

    let a = (service: "live", account: "u")
    let b = (service: "parked", account: "id")

    @Test func secretMoves() throws {
        let kc = InMemoryKeychain()
        let mover = SecretMover(keychain: kc, ops: OpCounter())
        #expect(try mover.move(from: a, to: b) == .skipped)
        kc.seed(service: "live", account: "u", secret: Data("s".utf8))
        #expect(try mover.move(from: a, to: b) == .moved)
        #expect(try kc.read(service: "parked", account: "id") == Data("s".utf8))
        #expect(try kc.read(service: "live", account: "u") == nil)
    }

    @Test func secretEqualFinishesMove() throws {
        let kc = InMemoryKeychain()
        kc.seed(service: "live", account: "u", secret: Data("s".utf8))
        kc.seed(service: "parked", account: "id", secret: Data("s".utf8))
        #expect(try SecretMover(keychain: kc, ops: OpCounter()).move(from: a, to: b) == .moved)
        #expect(try kc.read(service: "live", account: "u") == nil)
        #expect(try kc.read(service: "parked", account: "id") == Data("s".utf8))
    }

    @Test func secretDifferentThrows() throws {
        let kc = InMemoryKeychain()
        kc.seed(service: "live", account: "u", secret: Data("s1".utf8))
        kc.seed(service: "parked", account: "id", secret: Data("s2".utf8))
        #expect(throws: SwitchError.self) { try SecretMover(keychain: kc, ops: OpCounter()).move(from: a, to: b) }
        #expect(try kc.read(service: "live", account: "u") == Data("s1".utf8))
        #expect(try kc.read(service: "parked", account: "id") == Data("s2".utf8))
    }

    @Test func secretVerifyFailureKeepsSource() throws {
        let kc = LyingKeychain()
        kc.inner.seed(service: "live", account: "u", secret: Data("s".utf8))
        #expect(throws: SwitchError.keychainVerifyFailed) { try SecretMover(keychain: kc, ops: OpCounter()).move(from: a, to: b) }
        #expect(try kc.read(service: "live", account: "u") == Data("s".utf8))
    }

    @Test func secretDiscardDeletes() throws {
        let kc = InMemoryKeychain()
        kc.seed(service: "live", account: "u", secret: Data("s".utf8))
        try SecretMover(keychain: kc, ops: OpCounter()).discard(service: "live", account: "u")
        #expect(try kc.read(service: "live", account: "u") == nil)
        try SecretMover(keychain: kc, ops: OpCounter()).discard(service: "live", account: "u")
    }

    @Test func opCounterFaults() throws {
        let ops = OpCounter(failAfter: 2)
        try ops.tick()
        #expect(throws: SwitchError.injectedFault) { try ops.tick() }
        #expect(ops.count == 2)
        fx.write("c", to: live.appendingPathComponent("Cookies"))
        #expect(throws: SwitchError.injectedFault) {
            _ = try ItemMover(ops: OpCounter(failAfter: 1)).move("Cookies", from: live, to: parked, live: .source, strayRoot: stray)
        }
        #expect(fx.read(live.appendingPathComponent("Cookies")) == "c")
    }
}
