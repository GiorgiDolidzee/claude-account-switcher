import Foundation

public enum AccountError: Error, Equatable {
    case active
    case unknown
}

public struct SavedLogins: Equatable, Sendable {
    public var app: Bool
    public var cli: Bool
    public var side: Bool
    public init(app: Bool, cli: Bool, side: Bool) { self.app = app; self.cli = cli; self.side = side }
}

func defaultAccountName(_ id: AccountID, email: String?) -> String {
    if let email, !email.isEmpty { return email }
    return "Account " + id.raw.prefix(8)
}

/// The list of saved accounts. Accounts are added only when the user asks.
public struct AccountRegistry: Sendable {
    let paths: Paths
    let store: StateStore
    let keychain: KeychainStore
    let switcher: Switcher
    let trash: @Sendable (URL) throws -> Void

    public init(paths: Paths, store: StateStore, keychain: KeychainStore, switcher: Switcher,
                trash: @escaping @Sendable (URL) throws -> Void) {
        self.paths = paths; self.store = store; self.keychain = keychain; self.switcher = switcher; self.trash = trash
    }

    private func knownEmail(_ id: AccountID, live: LiveState?) -> String? {
        if let live, live.cliAccount == id, let email = live.cliEmail { return email }
        for file in [paths.cliAccountFile(id), paths.sideHome(id).appendingPathComponent(".claude.json")] {
            let account = ((try? JSONFile.readObject(file)) ?? nil)?["oauthAccount"] as? [String: Any]
            if (account?["accountUuid"] as? String)?.lowercased() == id.raw, let email = account?["emailAddress"] as? String {
                return email
            }
        }
        return nil
    }

    private func fill(_ record: inout AccountRecord, email: String?) {
        if let email, !email.isEmpty { record.email = email }
        if !record.nameIsCustom { record.name = defaultAccountName(record.id, email: record.email) }
    }

    /// Updates names and emails. Adds a new account only after "Add account…" (`pendingAdd`).
    @discardableResult
    public func refresh(live: LiveState) throws -> SwitcherState {
        try switcher.updateState { state in
            if state.pendingAdd {
                for id in [live.appAccount, live.cliAccount].compactMap({ $0 }) where !state.isSaved(id) {
                    state.accounts.append(AccountRecord(id: id, name: "", nameIsCustom: false, email: nil, lastUsed: nil))
                }
                if let app = live.appAccount, state.isSaved(app) { state.pendingAdd = false }
            }
            for i in state.accounts.indices {
                fill(&state.accounts[i], email: knownEmail(state.accounts[i].id, live: live))
            }
        }
        return try store.load()
    }

    /// "Save this account": adds it to the list. Nothing moves.
    public func save(_ id: AccountID, email: String?) throws {
        try switcher.updateState { state in
            if !state.isSaved(id) {
                state.accounts.append(AccountRecord(id: id, name: "", nameIsCustom: false, email: nil, lastUsed: nil))
            }
            let i = state.accounts.firstIndex { $0.id == id }!
            fill(&state.accounts[i], email: email ?? knownEmail(id, live: nil))
        }
    }

    public func rename(_ id: AccountID, to name: String) throws {
        try switcher.updateState { state in
            guard let i = state.accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.unknown }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            state.accounts[i].nameIsCustom = !trimmed.isEmpty
            state.accounts[i].name = trimmed.isEmpty ? defaultAccountName(id, email: state.accounts[i].email) : trimmed
        }
    }

    /// Deletes an account's saved logins. Claude's own data for the account is not touched.
    public func remove(_ id: AccountID, live: LiveState) throws {
        guard id != live.appAccount, id != live.cliAccount else { throw AccountError.active }
        guard try switcher.pendingJournal() == nil else { throw AccountError.active }
        for dir in [paths.accountDir(id), paths.sideHome(id)] where pathExists(dir) {
            try trash(dir)
        }
        try keychain.delete(service: KeychainNames.parked, account: id.raw)
        try keychain.delete(service: KeychainNames.sideService(configDir: paths.sideHome(id).path), account: paths.userName)
        try switcher.updateState { $0.accounts.removeAll { $0.id == id } }
    }

    public func savedLogins(_ id: AccountID) -> SavedLogins {
        let side = (try? keychain.exists(service: KeychainNames.sideService(configDir: paths.sideHome(id).path),
                                         account: paths.userName)) ?? false
        return SavedLogins(app: switcher.hasSavedAppLogin(id), cli: switcher.hasSavedCLILogin(id), side: side)
    }
}

/// What the menu shows at the top.
public struct MenuSummary: Equatable, Sendable {
    public var lines: [String]
    public var badge: Bool
    /// Live accounts that are not saved (app first).
    public var unsaved: [AccountID]
    public init(lines: [String], badge: Bool, unsaved: [AccountID]) { self.lines = lines; self.badge = badge; self.unsaved = unsaved }
}

public func accountLabel(_ id: AccountID, state: SwitcherState, live: LiveState) -> String {
    if let record = state.account(id) { return record.name }
    return defaultAccountName(id, email: live.cliAccount == id ? live.cliEmail : nil)
}

public func summarize(state: SwitcherState, live: LiveState, loginSet: LoginSet?, installedAppVersion: String?,
                      sideWrong: [AccountID]) -> MenuSummary {
    func shown(_ id: AccountID?, unknown: Bool) -> String {
        guard let id else { return unknown ? "Unknown account" : "Logged out" }
        return accountLabel(id, state: state, live: live) + (state.isSaved(id) ? "" : " (not saved)")
    }
    var lines = ["App: \(shown(live.appAccount, unknown: live.appOwnerUnknown)) · CLI: \(shown(live.cliAccount, unknown: live.cliOwnerUnknown))"]
    if live.mismatch { lines.append("App and CLI use different accounts") }
    if !live.appLoggedIn {
        if let last = state.accounts.filter({ $0.lastUsed != nil }).max(by: { $0.lastUsed! < $1.lastUsed! }) {
            lines.append("Log in to \(last.name) in the Claude app")
        } else {
            lines.append("Log in in the Claude app")
        }
    }
    if !live.cliLoggedIn { lines.append("CLI: run claude, then /login") }
    if let loginSet {
        if let installedAppVersion, installedAppVersion != loginSet.claudeAppVersion {
            lines.append("Claude updated — test a switch, or re-measure")
        }
    } else {
        lines.append("Switching is off until Step 0 is done")
    }
    for id in sideWrong {
        lines.append("Terminal for \(accountLabel(id, state: state, live: live)) is logged in to a different account")
    }
    var unsaved: [AccountID] = []
    for id in [live.appAccount, live.cliAccount].compactMap({ $0 }) where !state.isSaved(id) && !unsaved.contains(id) {
        unsaved.append(id)
    }
    return MenuSummary(lines: lines, badge: live.mismatch, unsaved: unsaved)
}
