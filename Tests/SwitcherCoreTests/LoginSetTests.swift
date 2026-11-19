import Foundation
import Testing
@testable import SwitcherCore

@Suite struct LoginSetTests {
    let fx = Fixture()

    func save(_ set: LoginSet) throws -> URL {
        let url = fx.root.appendingPathComponent("login-set.json")
        try JSONEncoder().encode(set).write(to: url)
        return url
    }

    @Test func loadsValidSet() throws {
        let loaded = try LoginSet.load(from: try save(fx.standardLoginSet()))
        #expect(loaded == fx.standardLoginSet())
    }

    @Test func loadsTheMeasuredSet() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data/login-set.json")
        let set = try LoginSet.load(from: url)
        #expect(set.app.items.contains("Cookies"))
        #expect(set.app.loginCookie.name == "sessionKey")
    }

    @Test func rejectsInvalidLoginSets() throws {
        let edits: [(inout LoginSet) -> Void] = [
            { $0.schemaVersion = 2 },
            { $0.app.items = [] },
            { $0.app.items = ["../x"] },
            { $0.app.items = ["a/b"] },
            { $0.app.items = ["vm_bundles"] },
            { $0.app.items = ["config.json"] },
            { $0.app.accountIdKey = "other" },
            { $0.app.tokenKeys = ["other"] },
            { $0.app.configKeys = [] },
            { $0.app.loginCookie.name = "" },
            { $0.cli.keychainService = "Claude Safe Storage" },
            { $0.cli.claudeJsonKeys = ["x"] },
            { $0.cli.claudeHomeItems = ["skills"] },
            { $0.cli.claudeHomeItems = [".."] },
        ]
        for (i, edit) in edits.enumerated() {
            var set = fx.standardLoginSet()
            edit(&set)
            let url = try save(set)
            #expect(throws: LoginSetError.self, "case \(i)") { try LoginSet.load(from: url) }
        }
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) { try LoginSet.load(from: fx.root.appendingPathComponent("none.json")) }
    }

    @Test func pathsUnderRootStayUnderRoot() {
        let p = fx.paths
        let all = [p.appData, p.appBundle, p.claudeHome, p.claudeJSON, p.switcherHome, p.configJSON,
                   p.stateFile, p.loginSetFile, p.lockFile, p.accountDir(idW), p.appLoginDir(idW),
                   p.appLoginKeysFile(idW), p.lastRestoredDir(idW), p.cliAccountFile(idW), p.cliFilesDir(idW),
                   p.sideHome(idW), p.strayDir(stamp: "s"), p.backupDir(stamp: "s")]
        for url in all { #expect(url.path.hasPrefix(fx.root.path + "/"), "\(url.path)") }
        #expect(p.appData.path.hasSuffix("Library/Application Support/Claude"))
        #expect(p.appLoginDir(idW).path.hasSuffix("ClaudeSwitcher/accounts/\(idW.raw)/app-login"))
        #expect(Paths.stamp(Date(timeIntervalSince1970: 0)) == "19700101-000000")
    }
}
