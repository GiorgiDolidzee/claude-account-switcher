import Foundation
import Testing
@testable import SwitcherCore

struct FakeBackupper: Backupper {
    var fail = false
    func backup(paths: Paths, loginSet: LoginSet, to dir: URL) throws {
        if fail { throw SwitchError.backupFailed("test") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

extension Fixture {
    static let ignored = ["stray-", "backup-", "state.json", "app-login-last-restored", "Trash/"]

    var trashDir: URL { root.appendingPathComponent("Trash") }

    func state() -> SwitcherState { try! StateStore(paths: paths).load() }

    func saveAccounts(_ ids: [AccountID]) {
        var s = state()
        for id in ids where !s.isSaved(id) {
            s.accounts.append(AccountRecord(id: id, name: id.raw, nameIsCustom: false, email: nil, lastUsed: nil))
        }
        try! StateStore(paths: paths).save(s)
    }

    func switcher(procs: [ProcInfo] = [], ops: OpCounter = OpCounter(), backupper: Backupper = FakeBackupper()) -> Switcher {
        let trash = trashDir
        return Switcher(paths: paths, loginSet: standardLoginSet(), keychain: keychain,
                        processes: FakeInspector(procs: procs), backupper: backupper,
                        trash: { url in
                            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
                        },
                        now: { Date(timeIntervalSince1970: 1_800_000_000) }, ownPID: 1, ops: ops)
    }

    /// P's logins are saved and parked; T is live on both sides.
    func parkedPLiveT() throws {
        saveAccounts([idW, idP])
        loginApp(idP, marker: "p")
        loginCLI(idP, marker: "p")
        _ = try switcher().parkAll(markPendingAdd: false)
        loginApp(idW, marker: "t")
        loginCLI(idW, marker: "t")
    }

    func liveSecret() -> String? {
        (try? keychain.read(service: KeychainNames.liveCLI, account: paths.userName)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    func parkedSecret(_ id: AccountID) -> String? {
        (try? keychain.read(service: KeychainNames.parked, account: id.raw)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    func liveState() -> LiveState {
        try! LiveStateReader(paths: paths, loginSet: standardLoginSet(), keychain: keychain).read()
    }

    func trashedNames() -> [String] {
        guard let walker = fm.enumerator(at: trashDir, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL)?.lastPathComponent }
    }
}

@Suite struct SwitcherTests {
    let fx = Fixture()

    @Test func firstRunMismatchParksOnlyCLI() throws {
        fx.saveAccounts([idW, idP])
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idP, marker: "p")
        let result = try fx.switcher().switchTo(idW)
        #expect(result.app == .unchanged && result.cli == .loggedOut && result.target == idW)
        #expect(fx.liveSecret() == nil)
        #expect(fx.parkedSecret(idP) == "secret-p")
        let parked = try JSONFile.readObject(fx.paths.cliAccountFile(idP))
        #expect((parked?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == idP.raw)
        #expect(fx.claudeJSON()["oauthAccount"] == nil)
        #expect(fx.claudeJSON()["projects"] != nil)
        #expect(fx.read(fx.paths.cliFilesDir(idP).appendingPathComponent("remote-settings.json")) == "org-p")
        #expect(fx.liveState().appAccount == idW)
        #expect(fx.state().journal == nil)
    }

    @Test func roundTripRestoresExactBytes() throws {
        try fx.parkedPLiveT()
        let liveT = fx.fingerprint(ignoring: Fixture.ignored + ["ClaudeSwitcher/"])
        let toP = try fx.switcher().switchTo(idP)
        #expect(toP.app == .restored && toP.cli == .restored)
        #expect(fx.liveState().appAccount == idP && fx.liveState().cliAccount == idP)
        #expect(fx.liveSecret() == "secret-p")
        #expect(fx.config()["oauth:tokenCache"] as? String == "token-p")
        #expect(fx.read(fx.paths.appData.appendingPathComponent("Local Storage/leveldb/000.log")) == "ls-p")
        #expect(fx.read(fx.paths.claudeHome.appendingPathComponent("remote-settings.json")) == "org-p")
        #expect(fx.parkedSecret(idW) == "secret-t" && fx.parkedSecret(idP) == nil)
        #expect(!fx.fm.fileExists(atPath: fx.paths.appLoginDir(idP).path))

        let back = try fx.switcher().switchTo(idW)
        #expect(back.app == .restored && back.cli == .restored)
        #expect(fx.fingerprint(ignoring: Fixture.ignored + ["ClaudeSwitcher/"]) == liveT)
        #expect(fx.parkedSecret(idP) == "secret-p")
        #expect(fx.state().account(idW)?.lastUsed != nil)
        #expect(!fx.fm.fileExists(atPath: fx.paths.switcherHome.path + "/stray-20270115-080000"))
    }

    @Test func protectedDataNeverChanges() throws {
        fx.writeProtectedData()
        try fx.parkedPLiveT()
        func protected() -> [String: String] {
            fx.fingerprint().filter { key, _ in
                ["claude-code-sessions", "vm_bundles", "claude_desktop_config.json", "config.json#locale",
                 "skills/", ".claude/settings.json", ".claude.json#projects"].contains { key.contains($0) }
            }
        }
        let before = protected()
        #expect(before.count == 7)
        _ = try fx.switcher().switchTo(idP)
        _ = try fx.switcher().switchTo(idW)
        _ = try fx.switcher().parkAll()
        #expect(protected() == before)
    }

    @Test func switchRefusesWhileAppProcessAlive() throws {
        try fx.parkedPLiveT()
        let before = fx.fingerprint()
        let helper = ProcInfo(pid: 50, executablePath: fx.paths.appData.path + "/claude-code/2.1/claude.app/Contents/MacOS/claude",
                              configDir: nil, envReadable: true)
        #expect(throws: SwitchError.busy(Blockers(app: [helper], mainCLIs: []))) { try fx.switcher(procs: [helper]).switchTo(idP) }
        #expect(fx.fingerprint() == before)
        #expect(fx.state().journal == nil)
    }

    @Test func switchRefusesWhileMainCLIAlive() throws {
        try fx.parkedPLiveT()
        let cli = ProcInfo(pid: 51, executablePath: "/opt/homebrew/Caskroom/claude-code/2.1.311/claude", configDir: nil, envReadable: true)
        #expect(throws: SwitchError.self) { try fx.switcher(procs: [cli]).switchTo(idP) }
        #expect(throws: SwitchError.self) { try fx.switcher(procs: [cli]).parkAll() }
        #expect(fx.liveState().cliAccount == idW)
    }

    @Test func sideCLIDoesNotBlock() throws {
        try fx.parkedPLiveT()
        let side = ProcInfo(pid: 52, executablePath: "/opt/homebrew/Caskroom/claude-code/2.1.311/claude",
                            configDir: fx.paths.sideHome(idP).path, envReadable: true)
        #expect(try fx.switcher(procs: [side]).switchTo(idP).app == .restored)
    }

    @Test func switchToActiveAccountIsNoOp() throws {
        try fx.parkedPLiveT()
        let before = fx.fingerprint()
        let result = try fx.switcher().switchTo(idW)
        #expect(result.app == .unchanged && result.cli == .unchanged && result.backup == nil)
        #expect(fx.fingerprint() == before)
    }

    @Test func targetWithoutSavedLoginLeavesSideLoggedOut() throws {
        fx.saveAccounts([idW, idP])
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idW, marker: "t")
        let result = try fx.switcher().switchTo(idP)
        #expect(result.app == .loggedOut && result.cli == .loggedOut)
        #expect(!fx.liveState().appLoggedIn && !fx.liveState().cliLoggedIn)
        #expect(fx.fm.fileExists(atPath: fx.paths.appLoginDir(idW).appendingPathComponent("Cookies").path))
        #expect(fx.config()["locale"] as? String == "en")
        #expect(fx.config()["lastKnownAccountUuid"] == nil)
    }

    @Test func invalidConfigJSONChangesNothing() throws {
        try fx.parkedPLiveT()
        fx.write("{", to: fx.paths.configJSON)
        let before = fx.fingerprint()
        #expect(throws: (any Error).self) { try fx.switcher().switchTo(idP) }
        #expect(fx.fingerprint() == before)
        #expect(fx.state().journal == nil)
    }

    @Test func unknownOwnerStops() throws {
        try fx.parkedPLiveT()
        var c = fx.config(); c["lastKnownAccountUuid"] = nil; fx.writeConfig(c)
        let before = fx.fingerprint()
        #expect(throws: SwitchError.unknownAppOwner) { try fx.switcher().switchTo(idP) }
        #expect(fx.fingerprint() == before)
        fx.loginApp(idW, marker: "t")
        var j = fx.claudeJSON(); j["oauthAccount"] = nil; fx.writeClaudeJSON(j)
        #expect(throws: SwitchError.unknownCLIOwner) { try fx.switcher().switchTo(idP) }
    }

    @Test func longSecretLeavesLiveCLILoginInPlace() throws {
        let fx = Fixture(keychain: InMemoryKeychain(maxSecretBytes: 5))
        fx.saveAccounts([idW, idP])
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idW, marker: "t")   // seeded: "secret-t" is longer than 5 bytes
        #expect(throws: KeychainError.secretTooLong(bytes: 8)) { try fx.switcher().switchTo(idP) }
        #expect(fx.liveSecret() == "secret-t")
        #expect(fx.state().journal != nil)
        #expect(throws: KeychainError.secretTooLong(bytes: 8)) { try fx.switcher().recover() }
        #expect(fx.liveSecret() == "secret-t")
        #expect(fx.parkedSecret(idW) == nil)
    }

    @Test func lastRestoredCopyKept() throws {
        try fx.parkedPLiveT()
        _ = try fx.switcher().switchTo(idP)
        #expect(fx.fm.fileExists(atPath: fx.paths.lastRestoredDir(idP).appendingPathComponent("app-login/Cookies").path))
        #expect(fx.fm.fileExists(atPath: fx.paths.lastRestoredDir(idP).appendingPathComponent("app-login.json").path))
    }

    // Amendment A: accounts are saved only on request.

    @Test func unsavedLiveAccountStopsSwitch() throws {
        fx.saveAccounts([idP])
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idW, marker: "t")
        let before = fx.fingerprint()
        #expect(throws: SwitchError.unsavedAccount(app: idW, cli: idW)) { try fx.switcher().switchTo(idP) }
        #expect(throws: SwitchError.unsavedAccount(app: idW, cli: idW)) { try fx.switcher().parkAll() }
        #expect(fx.fingerprint() == before)
        #expect(fx.state().journal == nil && !fx.state().backupDone)
    }

    @Test func discardThrowsLoginAway() throws {
        fx.saveAccounts([idP])
        fx.loginApp(idP, marker: "p")
        fx.loginCLI(idP, marker: "p")
        _ = try fx.switcher().parkAll(markPendingAdd: false)
        fx.loginApp(idW, marker: "t")      // T is not saved
        fx.loginCLI(idW, marker: "t")
        let result = try fx.switcher().switchTo(idP, discardUnsaved: true)
        #expect(result.app == .restored && result.cli == .restored)
        #expect(fx.liveSecret() == "secret-p")
        #expect(fx.config()["oauth:tokenCache"] as? String == "token-p")
        #expect(fx.parkedSecret(idW) == nil)
        #expect(!fx.fm.fileExists(atPath: fx.paths.accountDir(idW).path))
        #expect(fx.trashedNames().contains("Cookies"))
        #expect(fx.trashedNames().contains("remote-settings.json"))
        let stray = try fx.fm.contentsOfDirectory(atPath: fx.paths.switcherHome.path).filter { $0.hasPrefix("stray-") }
        for s in stray { #expect(!fx.fm.fileExists(atPath: fx.paths.switcherHome.appendingPathComponent(s + "/discarded").path)) }
        #expect(fx.state().journal == nil)
    }

    @Test func switchToUnsavedTargetRefused() throws {
        fx.saveAccounts([idW])
        fx.loginApp(idW, marker: "t")
        #expect(throws: SwitchError.unexpected("account is not saved")) { try fx.switcher().switchTo(idP) }
    }

    @Test func parkAllSetsPendingAdd() throws {
        fx.saveAccounts([idW])
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idW, marker: "t")
        let result = try fx.switcher().parkAll()
        #expect(result.app == .loggedOut && result.cli == .loggedOut && result.target == nil)
        #expect(fx.state().pendingAdd)
        #expect(!fx.liveState().appLoggedIn && !fx.liveState().cliLoggedIn)
        #expect(fx.parkedSecret(idW) == "secret-t")
        // Already logged out: still marks the add.
        var s = fx.state(); s.pendingAdd = false; try StateStore(paths: fx.paths).save(s)
        _ = try fx.switcher().parkAll()
        #expect(fx.state().pendingAdd)
    }
}

@Suite struct BackupTests {
    let fx = Fixture()

    @Test func firstSwitchBacksUpOnce() throws {
        fx.writeProtectedData()
        try fx.parkedPLiveT()
        var s = fx.state(); s.backupDone = false; s.backupPath = nil; try StateStore(paths: fx.paths).save(s)
        func appFiles(_ root: URL) -> [String] {
            ((try? fx.fm.subpathsOfDirectory(atPath: root.path)) ?? []).map { "/" + $0 }.sorted()
        }
        // The VM disk (11 GB, rewritten all the time) is left out of the safety copy.
        let before = appFiles(fx.paths.appData).filter { !$0.hasPrefix("/vm_bundles") }
        #expect(before.count < appFiles(fx.paths.appData).count)
        let result = try fx.switcher(backupper: CloneBackupper()).switchTo(idP)
        let backup = try #require(result.backup)
        #expect(backup.path.hasPrefix(fx.paths.switcherHome.path + "/backup-"))
        #expect(appFiles(backup.appendingPathComponent("Claude")) == before)
        #expect(fx.fm.fileExists(atPath: backup.appendingPathComponent("claude.json").path))
        #expect(fx.read(backup.appendingPathComponent("claude-home/remote-settings.json")) == "org-t")
        #expect(fx.state().backupDone && fx.state().backupPath == backup.path)
        #expect(try fx.switcher(backupper: CloneBackupper()).switchTo(idW).backup == nil)
        #expect(try fx.fm.contentsOfDirectory(atPath: fx.paths.switcherHome.path).filter { $0.hasPrefix("backup-") }.count == 1)
    }

    @Test func backupFailureMovesNothing() throws {
        try fx.parkedPLiveT()
        var s = fx.state(); s.backupDone = false; try StateStore(paths: fx.paths).save(s)
        let before = fx.fingerprint()
        #expect(throws: SwitchError.backupFailed("test")) { try fx.switcher(backupper: FakeBackupper(fail: true)).switchTo(idP) }
        #expect(fx.fingerprint() == before)
        #expect(fx.state().journal == nil)
    }
}
