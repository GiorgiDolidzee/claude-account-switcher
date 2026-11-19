import Foundation
import SQLite3
import Testing
@testable import SwitcherCore

@Suite struct LiveStateTests {
    let fx = Fixture()
    func read() throws -> LiveState {
        try LiveStateReader(paths: fx.paths, loginSet: fx.standardLoginSet(), keychain: fx.keychain).read()
    }

    @Test func appLoggedInWithId() throws {
        fx.loginApp(idW, marker: "t")
        let s = try read()
        #expect(s.appLoggedIn && s.appAccount == idW && !s.appOwnerUnknown)
        #expect(!s.cliLoggedIn && s.cliAccount == nil)
    }

    @Test func noSessionCookieMeansLoggedOut() throws {
        fx.loginApp(idW, marker: "t")
        fx.writeCookies(loggedIn: false)
        let s = try read()
        #expect(!s.appLoggedIn && s.appAccount == nil && !s.appOwnerUnknown)
    }

    @Test func missingCookiesFileMeansLoggedOut() throws {
        fx.writeConfig(["lastKnownAccountUuid": idW.raw, "oauth:tokenCache": "x"])
        #expect(try !read().appLoggedIn)
        fx.write("not a database", to: fx.paths.appData.appendingPathComponent("Cookies"))
        #expect(try !read().appLoggedIn)
    }

    @Test func readsCookiesWhileClaudeHoldsTheFileLocked() throws {
        fx.loginApp(idW, marker: "t")
        // Chromium keeps its cookie database locked while the app runs.
        var db: OpaquePointer?
        #expect(sqlite3_open(fx.paths.appData.appendingPathComponent("Cookies").path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(try read().appAccount == idW)
    }

    @Test func sessionCookieWithoutIdIsOwnerUnknown() throws {
        fx.writeCookies(loggedIn: true)
        fx.writeConfig(["locale": "en"])
        let s = try read()
        #expect(s.appLoggedIn && s.appAccount == nil && s.appOwnerUnknown)
    }

    @Test func cliLoggedIn() throws {
        fx.loginCLI(idP, marker: "p", email: "p@example.com")
        let s = try read()
        #expect(s.cliLoggedIn && s.cliAccount == idP && !s.cliOwnerUnknown && s.cliEmail == "p@example.com")
    }

    @Test func keychainWithoutOauthAccountIsOwnerUnknown() throws {
        fx.keychain.seed(service: KeychainNames.liveCLI, account: fx.paths.userName, secret: Data("s".utf8))
        let s = try read()
        #expect(s.cliLoggedIn && s.cliAccount == nil && s.cliOwnerUnknown)
    }

    @Test func oauthAccountWithoutKeychainIsLoggedOut() throws {
        fx.writeClaudeJSON(["oauthAccount": ["accountUuid": idP.raw]])
        let s = try read()
        #expect(!s.cliLoggedIn && s.cliAccount == nil && !s.cliOwnerUnknown)
    }

    @Test func uppercaseIdsNormalized() throws {
        fx.loginApp(idW, marker: "t")
        var c = fx.config(); c["lastKnownAccountUuid"] = idW.raw.uppercased(); fx.writeConfig(c)
        #expect(try read().appAccount == idW)
    }

    @Test func mismatchFlag() throws {
        fx.loginApp(idW, marker: "t")
        fx.loginCLI(idP, marker: "p")
        #expect(try read().mismatch)
        fx.loginCLI(idW, marker: "t")
        #expect(try !read().mismatch)
    }

    @Test func invalidConfigThrows() {
        fx.writeCookies(loggedIn: true)
        fx.write("{", to: fx.paths.configJSON)
        #expect(throws: (any Error).self) { try read() }
    }
}
