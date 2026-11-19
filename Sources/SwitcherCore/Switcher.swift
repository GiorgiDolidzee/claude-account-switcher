import Foundation

public enum SideResult: Equatable, Sendable { case unchanged, restored, loggedOut }

public struct SwitchResult: Equatable, Sendable {
    public var target: AccountID?
    public var app: SideResult
    public var cli: SideResult
    public var backup: URL?
}

/// Swaps the logins. Everything it does is written in a journal first, and every step can be run again,
/// so an interrupted switch is finished by `recover()`.
public final class Switcher: @unchecked Sendable {
    public let paths: Paths
    public let loginSet: LoginSet
    let keychain: KeychainStore
    let processes: ProcessInspector
    let backupper: Backupper
    let trash: @Sendable (URL) throws -> Void
    let now: @Sendable () -> Date
    let ownPID: Int32
    let ops: OpCounter
    let store: StateStore
    private let lock = NSLock()

    public init(paths: Paths, loginSet: LoginSet, keychain: KeychainStore, processes: ProcessInspector,
                backupper: Backupper = CloneBackupper(),
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                now: @escaping @Sendable () -> Date = { Date() }, ownPID: Int32 = getpid(), ops: OpCounter = OpCounter()) {
        self.paths = paths; self.loginSet = loginSet; self.keychain = keychain; self.processes = processes
        self.backupper = backupper; self.trash = trash; self.now = now; self.ownPID = ownPID; self.ops = ops
        store = StateStore(paths: paths)
    }

    // MARK: Questions

    public func currentBlockers() -> Blockers {
        blockers(in: processes.list(), paths: paths, ownPID: ownPID)
    }

    public func liveState() throws -> LiveState {
        try LiveStateReader(paths: paths, loginSet: loginSet, keychain: keychain).read()
    }

    public func hasSavedAppLogin(_ id: AccountID) -> Bool {
        if !Self.entries(paths.appLoginDir(id)).isEmpty { return true }
        return ((try? JSONFile.readRaw(paths.appLoginKeysFile(id))) ?? nil)?.isEmpty == false
    }

    public func hasSavedCLILogin(_ id: AccountID) -> Bool {
        if (try? keychain.exists(service: KeychainNames.parked, account: id.raw)) == true { return true }
        return FileManager.default.fileExists(atPath: paths.cliAccountFile(id).path)
    }

    public func pendingJournal() throws -> Journal? { try store.load().journal }

    /// Names in a folder, without Finder's dot files.
    static func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Every change to state.json outside a switch goes through here, so it cannot race a switch.
    /// The journal belongs to the switch engine and is always kept as it is.
    public func updateState(_ body: (inout SwitcherState) throws -> Void) throws {
        try lock.withLock {
            let before = try store.load()
            var state = before
            try body(&state)
            state.journal = before.journal
            if state != before { try store.save(state) }
        }
    }

    // MARK: Operations

    /// Switches both sides to a saved account.
    public func switchTo(_ target: AccountID, discardUnsaved: Bool = false) throws -> SwitchResult {
        try lock.withLock { try start(target: target, discardUnsaved: discardUnsaved, markPendingAdd: false) }
    }

    /// Parks both sides and leaves them logged out ("Add account…").
    public func parkAll(discardUnsaved: Bool = false, markPendingAdd: Bool = true) throws -> SwitchResult {
        try lock.withLock { try start(target: nil, discardUnsaved: discardUnsaved, markPendingAdd: markPendingAdd) }
    }

    /// Finishes an interrupted switch. Returns nil when there is nothing to finish.
    public func recover() throws -> SwitchResult? {
        try lock.withLock {
            guard let journal = try store.load().journal else { return nil }
            let busy = currentBlockers()
            guard busy.isEmpty else { throw SwitchError.busy(busy) }
            return try finish(journal, backup: nil, markPendingAdd: false)
        }
    }

    private func start(target: AccountID?, discardUnsaved: Bool, markPendingAdd: Bool) throws -> SwitchResult {
        var state = try store.load()
        guard state.journal == nil else { throw SwitchError.recoveryNeeded }
        let busy = currentBlockers()
        guard busy.isEmpty else { throw SwitchError.busy(busy) }
        if let target, !state.isSaved(target) { throw SwitchError.unexpected("account is not saved") }

        let live = try liveState()
        if live.appOwnerUnknown { throw SwitchError.unknownAppOwner }
        if live.cliOwnerUnknown { throw SwitchError.unknownCLIOwner }

        let appSide: Bool, cliSide: Bool
        if let target {
            appSide = target != live.appAccount && (live.appAccount != nil || hasSavedAppLogin(target))
            cliSide = target != live.cliAccount && (live.cliAccount != nil || hasSavedCLILogin(target))
        } else {
            appSide = live.appAccount != nil
            cliSide = live.cliAccount != nil
        }
        guard appSide || cliSide else {
            if target == nil, markPendingAdd, !state.pendingAdd {
                state.pendingAdd = true
                try store.save(state)
            }
            return SwitchResult(target: target, app: .unchanged, cli: .unchanged, backup: nil)
        }

        // Accounts are saved only when the user asks. An unsaved login is never parked silently.
        let appUnsaved = appSide ? live.appAccount.flatMap { state.isSaved($0) ? nil : $0 } : nil
        let cliUnsaved = cliSide ? live.cliAccount.flatMap { state.isSaved($0) ? nil : $0 } : nil
        if (appUnsaved != nil || cliUnsaved != nil), !discardUnsaved {
            throw SwitchError.unsavedAccount(app: appUnsaved, cli: cliUnsaved)
        }

        let stamp = Paths.stamp(now())
        var backup: URL?
        if !state.backupDone {
            let dir = paths.backupDir(stamp: stamp)
            try store.ensureHome()
            try backupper.backup(paths: paths, loginSet: loginSet, to: dir)
            state.backupDone = true
            state.backupPath = dir.path
            try store.save(state)
            backup = dir
        }

        if appSide, let target, hasSavedAppLogin(target) { keepLastRestoredCopy(of: target) }

        // The backup can take a moment. Make sure nothing was started meanwhile.
        let busyNow = currentBlockers()
        guard busyNow.isEmpty else { throw SwitchError.busy(busyNow) }

        // The live login is newer than any saved copy of the same account: set the old copy aside.
        if appSide, appUnsaved == nil, let from = live.appAccount {
            setAside([(paths.appLoginDir(from), "app-login"), (paths.appLoginKeysFile(from), "app-login.json")], stamp: stamp)
        }
        if cliSide, cliUnsaved == nil, let from = live.cliAccount {
            setAside([(paths.cliFilesDir(from), "cli-files"), (paths.cliAccountFile(from), "cli-account.json")], stamp: stamp)
            if try keychain.exists(service: liveCLI.service, account: liveCLI.account) {
                try keychain.delete(service: KeychainNames.parked, account: from.raw)
            }
        }

        let journal = Journal(op: target == nil ? .park : .switch, to: target,
                              appFrom: live.appAccount, cliFrom: live.cliAccount,
                              appSide: appSide, cliSide: cliSide,
                              appDiscard: appUnsaved != nil, cliDiscard: cliUnsaved != nil,
                              stamp: stamp, startedAt: now())
        state.journal = journal
        try store.save(state)
        return try finish(journal, backup: backup, markPendingAdd: markPendingAdd)
    }

    private func finish(_ journal: Journal, backup: URL?, markPendingAdd: Bool) throws -> SwitchResult {
        try run(journal)

        var state = try store.load()
        state.journal = nil
        if let to = journal.to, let i = state.accounts.firstIndex(where: { $0.id == to }) {
            state.accounts[i].lastUsed = now()
        }
        if journal.op == .park, markPendingAdd { state.pendingAdd = true }
        if journal.to != nil { state.pendingAdd = false }
        try store.save(state)

        // "Don't save": the thrown-away login goes to the Trash. A failure here leaves it in the stray folder.
        let discarded = discardDir(journal.stamp)
        if FileManager.default.fileExists(atPath: discarded.path) { try? trash(discarded) }

        let live = try? liveState()
        func side(_ active: Bool, _ account: AccountID?) -> SideResult {
            guard active else { return .unchanged }
            return journal.to != nil && account == journal.to ? .restored : .loggedOut
        }
        return SwitchResult(target: journal.to, app: side(journal.appSide, live?.appAccount),
                            cli: side(journal.cliSide, live?.cliAccount), backup: backup)
    }

    // MARK: The moves

    private func discardDir(_ stamp: String) -> URL { paths.strayDir(stamp: stamp).appendingPathComponent("discarded") }
    private func collisions(_ stamp: String) -> URL { paths.strayDir(stamp: stamp).appendingPathComponent("collisions") }

    private struct Parking {
        var items: URL
        var keys: URL
    }

    /// Where the live app login goes: the account's folder, the Trash-bound folder, or the stray folder.
    private func appParking(_ j: Journal) -> Parking {
        if j.appDiscard {
            return Parking(items: discardDir(j.stamp).appendingPathComponent("app-login"),
                           keys: discardDir(j.stamp).appendingPathComponent("app-login.json"))
        }
        if let from = j.appFrom { return Parking(items: paths.appLoginDir(from), keys: paths.appLoginKeysFile(from)) }
        let stray = paths.strayDir(stamp: j.stamp)
        return Parking(items: stray.appendingPathComponent("app-login"), keys: stray.appendingPathComponent("app-login.json"))
    }

    private func cliParking(_ j: Journal) -> Parking {
        if j.cliDiscard {
            return Parking(items: discardDir(j.stamp).appendingPathComponent("cli-files"),
                           keys: discardDir(j.stamp).appendingPathComponent("cli-account.json"))
        }
        if let from = j.cliFrom { return Parking(items: paths.cliFilesDir(from), keys: paths.cliAccountFile(from)) }
        let stray = paths.strayDir(stamp: j.stamp)
        return Parking(items: stray.appendingPathComponent("cli-files"), keys: stray.appendingPathComponent("cli-account.json"))
    }

    private var liveCLI: (service: String, account: String) { (KeychainNames.liveCLI, paths.userName) }

    private func run(_ journal: Journal) throws {
        var j = journal
        if !j.parked {
            try park(j)
            // From here on the live side holds the new login, so a re-run must not park again.
            j.parked = true
            var state = try store.load()
            state.journal = j
            try store.save(state)
        }
        try unpark(j)
    }

    private func park(_ j: Journal) throws {
        let items = ItemMover(ops: ops), keys = KeyMover(ops: ops), secrets = SecretMover(keychain: keychain, ops: ops)

        // Look before moving: two different values for the same thing stop everything.
        if j.appSide { try keys.check(keys: loginSet.app.configKeys, from: paths.configJSON, to: appParking(j).keys) }
        if j.cliSide {
            if let from = j.cliFrom, !j.cliDiscard { try secrets.check(from: liveCLI, to: (KeychainNames.parked, from.raw)) }
            try keys.check(keys: loginSet.cli.claudeJsonKeys, from: paths.claudeJSON, to: cliParking(j).keys)
        }

        if j.appSide {
            let parking = appParking(j)
            for item in loginSet.app.items {
                _ = try items.move(item, from: paths.appData, to: parking.items, live: .source, strayRoot: collisions(j.stamp))
            }
            try keys.move(keys: loginSet.app.configKeys, from: paths.configJSON, to: parking.keys, srcIsLive: true)
        }

        if j.cliSide {
            let parking = cliParking(j)
            if j.cliDiscard {
                try secrets.discard(service: liveCLI.service, account: liveCLI.account)
            } else if let from = j.cliFrom {
                _ = try secrets.move(from: liveCLI, to: (KeychainNames.parked, from.raw))
            } else if try keychain.exists(service: liveCLI.service, account: liveCLI.account) {
                throw SwitchError.unexpected("a CLI login appeared during the switch")
            }
            try keys.move(keys: loginSet.cli.claudeJsonKeys, from: paths.claudeJSON, to: parking.keys, srcIsLive: true)
            for item in loginSet.cli.claudeHomeItems {
                _ = try items.move(item, from: paths.claudeHome, to: parking.items, live: .source, strayRoot: collisions(j.stamp))
            }
        }

    }

    private func unpark(_ j: Journal) throws {
        let items = ItemMover(ops: ops), keys = KeyMover(ops: ops), secrets = SecretMover(keychain: keychain, ops: ops)
        guard let to = j.to else { return }

        if j.appSide {
            let saved = paths.appLoginDir(to)
            let names = Set(loginSet.app.items).union(Self.entries(saved))
            for item in names.sorted() {
                _ = try items.move(item, from: saved, to: paths.appData, live: .destination, strayRoot: collisions(j.stamp))
            }
            try keys.move(keys: nil, from: paths.appLoginKeysFile(to), to: paths.configJSON, srcIsLive: false)
            rmdir(saved.path)
        }

        if j.cliSide {
            _ = try secrets.move(from: (KeychainNames.parked, to.raw), to: liveCLI)
            try keys.move(keys: nil, from: paths.cliAccountFile(to), to: paths.claudeJSON, srcIsLive: false)
            let saved = paths.cliFilesDir(to)
            let names = Set(loginSet.cli.claudeHomeItems).union(Self.entries(saved))
            for item in names.sorted() {
                _ = try items.move(item, from: saved, to: paths.claudeHome, live: .destination, strayRoot: collisions(j.stamp))
            }
            rmdir(saved.path)
        }
    }

    /// Moves old saved data into `stray-<stamp>/superseded/`. Nothing is deleted.
    private func setAside(_ things: [(from: URL, name: String)], stamp: String) {
        let fm = FileManager.default
        let dir = paths.strayDir(stamp: stamp).appendingPathComponent("superseded")
        for thing in things where pathExists(thing.from) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var target = dir.appendingPathComponent(thing.name)
            var n = 2
            while pathExists(target) { target = dir.appendingPathComponent("\(thing.name)-\(n)"); n += 1 }
            try? fm.moveItem(at: thing.from, to: target)
        }
    }

    /// A copy of the saved app login, kept in case Claude rejects the restored one.
    private func keepLastRestoredCopy(of id: AccountID) {
        let fm = FileManager.default
        let dir = paths.lastRestoredDir(id)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.copyItem(at: paths.appLoginDir(id), to: dir.appendingPathComponent("app-login"))
        try? fm.copyItem(at: paths.appLoginKeysFile(id), to: dir.appendingPathComponent("app-login.json"))
    }
}
