import Foundation
import SQLite3

/// Who is logged in right now, read from the live data.
public struct LiveState: Equatable, Sendable {
    public var appLoggedIn = false
    public var appAccount: AccountID?
    public var appOwnerUnknown = false
    public var cliLoggedIn = false
    public var cliAccount: AccountID?
    public var cliOwnerUnknown = false
    public var cliEmail: String?

    public init() {}

    /// Both sides are logged in, to different accounts.
    public var mismatch: Bool {
        if let a = appAccount, let c = cliAccount { return a != c }
        return false
    }
}

public struct LiveStateReader: Sendable {
    public let paths: Paths
    public let loginSet: LoginSet
    public let keychain: KeychainStore

    public init(paths: Paths, loginSet: LoginSet, keychain: KeychainStore) {
        self.paths = paths; self.loginSet = loginSet; self.keychain = keychain
    }

    public func read() throws -> LiveState {
        var state = LiveState()

        // App: logged in when the session cookie is in the Cookies file (measured in Step 0).
        let config = try JSONFile.readObject(paths.configJSON) ?? [:]
        state.appLoggedIn = Self.hasCookie(loginSet.app.loginCookie, in: paths.appData.appendingPathComponent("Cookies"))
        if state.appLoggedIn {
            state.appAccount = (config[loginSet.app.accountIdKey] as? String).flatMap(AccountID.init)
            state.appOwnerUnknown = state.appAccount == nil
        }

        // CLI: logged in when its Keychain item exists.
        let claude = try JSONFile.readObject(paths.claudeJSON) ?? [:]
        let account = claude["oauthAccount"] as? [String: Any]
        state.cliLoggedIn = try keychain.exists(service: KeychainNames.liveCLI, account: paths.userName)
        if state.cliLoggedIn {
            state.cliAccount = (account?["accountUuid"] as? String).flatMap(AccountID.init)
            state.cliOwnerUnknown = state.cliAccount == nil
            state.cliEmail = account?["emailAddress"] as? String
        }
        return state
    }

    /// Looks at cookie names and hosts only. Cookie values are never read.
    static func hasCookie(_ cookie: LoginSet.LoginCookie, in file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var db: OpaquePointer?
        // "immutable" reads without taking locks: Claude keeps this file locked while it runs.
        let uri = file.absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT host_key FROM cookies WHERE name = ?1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, cookie.name, -1, transient)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0), String(cString: text).hasSuffix(cookie.hostSuffix) { return true }
        }
        return false
    }
}
