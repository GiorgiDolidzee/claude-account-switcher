import Foundation
import Testing
@testable import SwitcherCore

@Suite struct RecoveryTests {
    /// Runs `action` once cleanly, then again with a "crash" before every single changing step.
    func crashEverywhere(setup: (Fixture) throws -> Void, action: (Switcher) throws -> Void) throws {
        let clean = Fixture()
        try setup(clean)
        let counter = OpCounter()
        try action(clean.switcher(ops: counter))
        let expected = clean.fingerprint(ignoring: Fixture.ignored)
        #expect(counter.count >= 6)
        for n in 1...counter.count {
            let fx = Fixture()
            try setup(fx)
            #expect(throws: SwitchError.injectedFault, "step \(n)") { try action(fx.switcher(ops: OpCounter(failAfter: n))) }
            #expect(fx.state().journal != nil, "step \(n)")
            #expect(throws: SwitchError.recoveryNeeded, "step \(n)") { try action(fx.switcher()) }
            _ = try fx.switcher().recover()
            let got = fx.fingerprint(ignoring: Fixture.ignored)
            let diff = Set(got.keys).symmetricDifference(expected.keys).sorted() + got.filter { expected[$0.key] != nil && expected[$0.key] != $0.value }.keys.sorted()
            #expect(diff.isEmpty, "step \(n): \(diff)")
            #expect(fx.state().journal == nil, "step \(n)")
            #expect(try fx.switcher().recover() == nil)
        }
    }

    @Test func crashAtEveryOperationRecovers() throws {
        try crashEverywhere(setup: { try $0.parkedPLiveT() }, action: { _ = try $0.switchTo(idP) })
    }

    @Test func discardSurvivesCrashAtEveryOperation() throws {
        try crashEverywhere(setup: { fx in
            fx.saveAccounts([idP])
            fx.loginApp(idP, marker: "p")
            fx.loginCLI(idP, marker: "p")
            _ = try fx.switcher().parkAll(markPendingAdd: false)
            fx.loginApp(idW, marker: "t")
            fx.loginCLI(idW, marker: "t")
        }, action: { _ = try $0.switchTo(idP, discardUnsaved: true) })
    }

    @Test func parkAllSurvivesCrashAtEveryOperation() throws {
        try crashEverywhere(setup: { try $0.parkedPLiveT() }, action: { _ = try $0.parkAll() })
    }

    @Test func recreatedLiveItemGoesToStray() throws {
        let fx = Fixture()
        try fx.parkedPLiveT()
        // Stop right after the first move (Cookies is parked), then something re-creates it.
        #expect(throws: SwitchError.injectedFault) { try fx.switcher(ops: OpCounter(failAfter: 2)).switchTo(idP) }
        #expect(!fx.fm.fileExists(atPath: fx.paths.appData.appendingPathComponent("Cookies").path))
        fx.write("re-created", to: fx.paths.appData.appendingPathComponent("Cookies"))
        _ = try fx.switcher().recover()
        let stamp = Paths.stamp(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(fx.read(fx.paths.strayDir(stamp: stamp).appendingPathComponent("collisions/Cookies")) == "re-created")
        #expect(fx.liveState().appAccount == idP)
        #expect(fx.fm.fileExists(atPath: fx.paths.appLoginDir(idW).appendingPathComponent("Cookies").path))
    }

    @Test func conflictingValuesStopAndChangeNothing() throws {
        let fx = Fixture()
        try fx.parkedPLiveT()
        #expect(throws: SwitchError.injectedFault) { try fx.switcher(ops: OpCounter(failAfter: 1)).switchTo(idP) }
        try JSONFile.writeObject(["oauth:tokenCache": "different"], to: fx.paths.appLoginKeysFile(idW))
        let before = fx.fingerprint()
        #expect(throws: SwitchError.valueConflict(key: "oauth:tokenCache", files: ["config.json", "app-login.json"])) {
            try fx.switcher().recover()
        }
        #expect(fx.fingerprint() == before)
        #expect(fx.config()["oauth:tokenCache"] as? String == "token-t")
        #expect(fx.state().journal != nil)

        // Same for a Keychain secret that differs.
        try fx.fm.removeItem(at: fx.paths.appLoginKeysFile(idW))
        fx.keychain.seed(service: KeychainNames.parked, account: idW.raw, secret: Data("other".utf8))
        let before2 = fx.fingerprint()
        #expect(throws: SwitchError.valueConflict(key: "keychain", files: [KeychainNames.liveCLI, KeychainNames.parked])) {
            try fx.switcher().recover()
        }
        #expect(fx.fingerprint() == before2)
    }

    @Test func recoverRefusesWhileBusy() throws {
        let fx = Fixture()
        try fx.parkedPLiveT()
        #expect(throws: SwitchError.injectedFault) { try fx.switcher(ops: OpCounter(failAfter: 3)).switchTo(idP) }
        let app = ProcInfo(pid: 9, executablePath: fx.paths.appBundle.path + "/Contents/MacOS/Claude", configDir: nil, envReadable: true)
        let before = fx.fingerprint()
        #expect(throws: SwitchError.self) { try fx.switcher(procs: [app]).recover() }
        #expect(fx.fingerprint() == before)
    }
}
