import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AccountsTests {
    let fx = Fixture()

    var registry: AccountRegistry {
        let trash = fx.trashDir
        return AccountRegistry(paths: fx.paths, store: StateStore(paths: fx.paths), keychain: fx.keychain, switcher: fx.switcher(),
                               trash: { url in
                                   try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                                   try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
                               })
    }

    func summary(loginSet: LoginSet? = nil, version: String? = "1.0", sideWrong: [AccountID] = []) -> MenuSummary {
        summarize(state: fx.state(), live: fx.liveState(), loginSet: loginSet ?? fx.standardLoginSet(),
                  installedAppVersion: version, sideWrong: sideWrong)
    }

    @Test func refreshNeverAddsByItself() throws {
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idP, marker: "p", email: "p@example.com")
        let before = fx.fingerprint(ignoring: ["state.json"])
        let state = try registry.refresh(live: fx.liveState())
        #expect(state.accounts.isEmpty)
        #expect(fx.fingerprint(ignoring: ["state.json"]) == before)
        let s = summary()
        #expect(s.unsaved == [idW, idP])
        #expect(s.badge)
        #expect(s.lines.first == "App: Account aaaaaaaa (not saved) · CLI: p@example.com (not saved)")
        #expect(s.lines.contains("App and CLI use different accounts"))
    }

    @Test func pendingAddSavesNewLogin() throws {
        fx.saveAccounts([idW])
        var s = fx.state(); s.pendingAdd = true; try StateStore(paths: fx.paths).save(s)
        // Nobody logged in yet: nothing happens, the flag stays.
        #expect(try registry.refresh(live: fx.liveState()).pendingAdd)
        fx.loginCLI(idP, marker: "p", email: "p@example.com")
        var state = try registry.refresh(live: fx.liveState())
        #expect(state.account(idP)?.name == "p@example.com")
        #expect(state.pendingAdd)                      // app side not logged in yet
        fx.loginApp(idP, marker: "p")
        state = try registry.refresh(live: fx.liveState())
        #expect(!state.pendingAdd)
        #expect(state.accounts.map(\.id) == [idW, idP])
    }

    @Test func saveAddsLiveAccount() throws {
        fx.loginApp(idW, marker: "t")
        try registry.save(idW, email: nil)
        try registry.save(idW, email: "t@example.com")   // twice: still one record, email filled in
        let state = fx.state()
        #expect(state.accounts.count == 1)
        #expect(state.accounts[0].name == "t@example.com" && !state.accounts[0].nameIsCustom)
        #expect(summary().unsaved.isEmpty)
        #expect(summary().lines.first == "App: t@example.com · CLI: Logged out")
    }

    @Test func defaultNameUpgradesToEmailLater() throws {
        fx.loginApp(idW, marker: "t")
        try registry.save(idW, email: nil)
        #expect(fx.state().accounts[0].name == "Account aaaaaaaa")
        fx.loginCLI(idW, marker: "t", email: "t@example.com")
        #expect(try registry.refresh(live: fx.liveState()).accounts[0].name == "t@example.com")
    }

    @Test func customNameIsKeptAndRenameEmptyResets() throws {
        fx.loginCLI(idW, marker: "t", email: "t@example.com")
        try registry.save(idW, email: "t@example.com")
        try registry.rename(idW, to: "  Work ")
        #expect(try registry.refresh(live: fx.liveState()).accounts[0].name == "Work")
        #expect(fx.state().accounts[0].nameIsCustom)
        try registry.rename(idW, to: "   ")
        #expect(fx.state().accounts[0].name == "t@example.com" && !fx.state().accounts[0].nameIsCustom)
    }

    @Test func removeActiveRefused() throws {
        fx.saveAccounts([idW, idP])
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idP, marker: "p")
        #expect(throws: AccountError.active) { try registry.remove(idW, live: fx.liveState()) }
        #expect(throws: AccountError.active) { try registry.remove(idP, live: fx.liveState()) }
        #expect(fx.state().accounts.count == 2)
    }

    @Test func removeInactiveTrashesAndDeletesKeychain() throws {
        try fx.parkedPLiveT()
        let sideService = KeychainNames.sideService(configDir: fx.paths.sideHome(idP).path)
        fx.keychain.seed(service: sideService, account: fx.paths.userName, secret: Data("side".utf8))
        fx.write("{}", to: fx.paths.sideHome(idP).appendingPathComponent(".claude.json"))
        #expect(registry.savedLogins(idP) == SavedLogins(app: true, cli: true, side: true))
        try registry.remove(idP, live: fx.liveState())
        #expect(fx.state().accounts.map(\.id) == [idW])
        #expect(!fx.fm.fileExists(atPath: fx.paths.accountDir(idP).path))
        #expect(!fx.fm.fileExists(atPath: fx.paths.sideHome(idP).path))
        #expect(fx.parkedSecret(idP) == nil)
        #expect(try fx.keychain.read(service: sideService, account: fx.paths.userName) == nil)
        #expect(fx.trashedNames().contains("Cookies"))
        #expect(registry.savedLogins(idP) == SavedLogins(app: false, cli: false, side: false))
        #expect(fx.liveSecret() == "secret-t")
    }

    @Test func summaryLines() throws {
        fx.saveAccounts([idW, idP])
        try registry.rename(idW, to: "Work")
        try registry.rename(idP, to: "Personal")
        // Nobody logged in; Personal was used last.
        var s = fx.state(); s.accounts[1].lastUsed = Date(); try StateStore(paths: fx.paths).save(s)
        var m = summary()
        #expect(m.lines == ["App: Logged out · CLI: Logged out", "Log in to Personal in the Claude app", "CLI: run claude, then /login"])
        #expect(!m.badge)

        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idW, marker: "t")
        #expect(summary().lines == ["App: Work · CLI: Work"])

        fx.loginCLI(idP, marker: "p")
        m = summary(version: "2.0", sideWrong: [idP])
        #expect(m.badge)
        #expect(m.lines == ["App: Work · CLI: Personal", "App and CLI use different accounts",
                            "Claude updated — test a switch, or re-measure",
                            "Terminal for Personal is logged in to a different account"])

        m = summarize(state: fx.state(), live: fx.liveState(), loginSet: nil, installedAppVersion: "1.0", sideWrong: [])
        #expect(m.lines.contains("Switching is off until Step 0 is done"))
    }
}
