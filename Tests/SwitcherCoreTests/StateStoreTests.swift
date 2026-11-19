import Foundation
import Testing
@testable import SwitcherCore

@Suite struct StateStoreTests {
    let fx = Fixture()
    var store: StateStore { StateStore(paths: fx.paths) }

    @Test func missingStateIsDefault() throws {
        #expect(try store.load() == SwitcherState())
    }

    @Test func saveLoadRoundTrip() throws {
        var s = SwitcherState()
        s.accounts = [AccountRecord(id: idW, name: "Work", nameIsCustom: true, email: "t@example.com", lastUsed: Date(timeIntervalSince1970: 100)),
                      AccountRecord(id: idP, name: "p@example.com", nameIsCustom: false, email: nil, lastUsed: nil)]
        s.journal = Journal(op: .switch, to: idP, appFrom: idW, cliFrom: nil, appSide: true, cliSide: false,
                            appDiscard: false, cliDiscard: true, stamp: "20261116-000000", startedAt: Date(timeIntervalSince1970: 200))
        s.backupDone = true
        s.pendingAdd = true
        try store.save(s)
        #expect(try store.load() == s)
    }

    @Test func homeIs0700AndStateIs0600() throws {
        try FileManager.default.createDirectory(at: fx.paths.switcherHome, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try store.save(SwitcherState())
        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: fx.paths.switcherHome.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: fx.paths.stateFile.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func invalidStateThrows() throws {
        fx.write("{", to: fx.paths.stateFile)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func oldJournalWithoutDiscardFieldsDecodes() throws {
        fx.write(#"{"schemaVersion":1,"accounts":[],"backupDone":false,"launchAtLoginConfigured":false,"journal":{"op":"park","appSide":true,"cliSide":false,"stamp":"s","startedAt":"2026-11-16T00:00:00Z"}}"#, to: fx.paths.stateFile)
        let s = try store.load()
        #expect(s.journal?.appDiscard == false)
        #expect(s.pendingAdd == false)
    }
}
