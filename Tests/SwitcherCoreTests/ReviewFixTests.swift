import Foundation
import Testing
@testable import SwitcherCore

/// Says "nothing running" for the first calls, then reports a process.
final class LateInspector: ProcessInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let quietCalls: Int
    let proc: ProcInfo
    init(quietCalls: Int, proc: ProcInfo) { self.quietCalls = quietCalls; self.proc = proc }
    func list() -> [ProcInfo] {
        lock.withLock {
            calls += 1
            return calls > quietCalls ? [proc] : []
        }
    }
}

@Suite struct ReviewFixTests {
    let fx = Fixture()

    @Test func liveLoginReplacesAnOlderSavedCopyOfTheSameAccount() throws {
        try fx.parkedPLiveT()                 // P saved (old), T live
        _ = try fx.switcher().switchTo(idP)   // P live, T saved
        _ = try fx.switcher().parkAll(markPendingAdd: false)   // P saved again, logged out
        // The owner logs in to P again by hand: a newer P login is live while an older one is saved.
        fx.loginApp(idP, marker: "p2")
        fx.loginCLI(idP, marker: "p2")
        let result = try fx.switcher().switchTo(idW)
        #expect(result.app == .restored && result.cli == .restored)
        #expect(fx.parkedSecret(idP) == "secret-p2")
        #expect((try JSONFile.readObject(fx.paths.appLoginKeysFile(idP)))?["oauth:tokenCache"] as? String == "token-p2")
        #expect(fx.read(fx.paths.appLoginDir(idP).appendingPathComponent("Local Storage/leveldb/000.log")) == "ls-p2")
        #expect(fx.read(fx.paths.cliFilesDir(idP).appendingPathComponent("remote-settings.json")) == "org-p2")
        let stamp = Paths.stamp(Date(timeIntervalSince1970: 1_800_000_000))
        let old = fx.paths.strayDir(stamp: stamp).appendingPathComponent("superseded")
        #expect(fx.read(old.appendingPathComponent("app-login/Local Storage/leveldb/000.log")) == "ls-p")
        #expect(fx.fm.fileExists(atPath: old.appendingPathComponent("app-login.json").path))
        #expect(fx.fm.fileExists(atPath: old.appendingPathComponent("cli-account.json").path))
        // And back again without trouble.
        #expect(try fx.switcher().switchTo(idP).app == .restored)
        #expect(fx.liveSecret() == "secret-p2")
    }

    @Test func processThatStartsDuringTheBackupStopsTheSwitch() throws {
        try fx.parkedPLiveT()
        let before = fx.fingerprint(ignoring: Fixture.ignored)
        let app = ProcInfo(pid: 7, executablePath: fx.paths.appBundle.path + "/Contents/MacOS/Claude", configDir: nil, envReadable: true)
        let late = Switcher(paths: fx.paths, loginSet: fx.standardLoginSet(), keychain: fx.keychain,
                            processes: LateInspector(quietCalls: 1, proc: app), backupper: FakeBackupper(),
                            trash: { _ in }, ownPID: 1)
        #expect(throws: SwitchError.busy(Blockers(app: [app], mainCLIs: []))) { try late.switchTo(idP) }
        #expect(fx.fingerprint(ignoring: Fixture.ignored) == before)
        #expect(fx.state().journal == nil)
    }

    @Test func stateUpdatesKeepTheJournal() throws {
        try fx.parkedPLiveT()
        #expect(throws: SwitchError.injectedFault) { try fx.switcher(ops: OpCounter(failAfter: 3)).switchTo(idP) }
        let journal = fx.state().journal
        #expect(journal != nil)
        let sw = fx.switcher()
        let registry = AccountRegistry(paths: fx.paths, store: StateStore(paths: fx.paths), keychain: fx.keychain, switcher: sw, trash: { _ in })
        try registry.rename(idW, to: "Work")
        try registry.save(idP, email: "p@example.com")
        _ = try registry.refresh(live: fx.liveState())
        #expect(fx.state().journal == journal)
        #expect(fx.state().account(idW)?.name == "Work")
        try sw.updateState { $0.journal = nil; $0.accounts = [] }   // a closure cannot drop the journal
        #expect(fx.state().journal == journal)
    }

    @Test func pendingAddIsClearedByANormalSwitch() throws {
        try fx.parkedPLiveT()
        _ = try fx.switcher().parkAll()
        #expect(fx.state().pendingAdd)
        _ = try fx.switcher().switchTo(idP)
        #expect(!fx.state().pendingAdd)
    }

    @Test func finderFilesAreNotALogin() throws {
        fx.saveAccounts([idW, idP])
        fx.loginApp(idW, marker: "t")
        fx.write("finder", to: fx.paths.appLoginDir(idP).appendingPathComponent(".DS_Store"))
        #expect(!fx.switcher().hasSavedAppLogin(idP))
        fx.write("x", to: fx.paths.appLoginDir(idP).appendingPathComponent("Cookies"))
        _ = try fx.switcher().switchTo(idP)
        #expect(!fx.fm.fileExists(atPath: fx.paths.appData.appendingPathComponent(".DS_Store").path))
    }

    @Test func writingThroughASymlinkKeepsTheLink() throws {
        let real = fx.root.appendingPathComponent("real.json")
        let link = fx.root.appendingPathComponent("link.json")
        fx.write(#"{"a":1}"#, to: real)
        try fx.fm.createSymbolicLink(at: link, withDestinationURL: real)
        try JSONFile.writeObject(["b": 2], to: link)
        #expect(try fx.fm.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(fx.read(real) == #"{"b":2}"#)
    }
}
