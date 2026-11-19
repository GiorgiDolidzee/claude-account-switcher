import Foundation

public struct AccountRecord: Codable, Equatable, Sendable {
    public var id: AccountID
    public var name: String
    public var nameIsCustom: Bool
    public var email: String?
    public var lastUsed: Date?
    public init(id: AccountID, name: String, nameIsCustom: Bool, email: String?, lastUsed: Date?) {
        self.id = id; self.name = name; self.nameIsCustom = nameIsCustom; self.email = email; self.lastUsed = lastUsed
    }
}

/// Written before anything moves, cleared when the switch is finished.
public struct Journal: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case `switch`, park }
    public var op: Op
    public var to: AccountID?
    public var appFrom: AccountID?
    public var cliFrom: AccountID?
    public var appSide: Bool
    public var cliSide: Bool
    public var appDiscard: Bool
    public var cliDiscard: Bool
    /// True once the old logins are parked; recovery then only finishes the restore.
    public var parked = false
    public var stamp: String
    public var startedAt: Date

    public init(op: Op, to: AccountID?, appFrom: AccountID?, cliFrom: AccountID?, appSide: Bool, cliSide: Bool,
                appDiscard: Bool = false, cliDiscard: Bool = false, stamp: String, startedAt: Date) {
        self.op = op; self.to = to; self.appFrom = appFrom; self.cliFrom = cliFrom
        self.appSide = appSide; self.cliSide = cliSide; self.appDiscard = appDiscard; self.cliDiscard = cliDiscard
        self.stamp = stamp; self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(Op.self, forKey: .op)
        to = try c.decodeIfPresent(AccountID.self, forKey: .to)
        appFrom = try c.decodeIfPresent(AccountID.self, forKey: .appFrom)
        cliFrom = try c.decodeIfPresent(AccountID.self, forKey: .cliFrom)
        appSide = try c.decode(Bool.self, forKey: .appSide)
        cliSide = try c.decode(Bool.self, forKey: .cliSide)
        appDiscard = try c.decodeIfPresent(Bool.self, forKey: .appDiscard) ?? false
        cliDiscard = try c.decodeIfPresent(Bool.self, forKey: .cliDiscard) ?? false
        parked = try c.decodeIfPresent(Bool.self, forKey: .parked) ?? false
        stamp = try c.decode(String.self, forKey: .stamp)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
    }
}

public struct SwitcherState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var accounts: [AccountRecord] = []
    public var journal: Journal?
    public var backupDone = false
    public var backupPath: String?
    public var launchAtLoginConfigured = false
    public var pendingAdd = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accounts = try c.decodeIfPresent([AccountRecord].self, forKey: .accounts) ?? []
        journal = try c.decodeIfPresent(Journal.self, forKey: .journal)
        backupDone = try c.decodeIfPresent(Bool.self, forKey: .backupDone) ?? false
        backupPath = try c.decodeIfPresent(String.self, forKey: .backupPath)
        launchAtLoginConfigured = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginConfigured) ?? false
        pendingAdd = try c.decodeIfPresent(Bool.self, forKey: .pendingAdd) ?? false
    }

    public func account(_ id: AccountID) -> AccountRecord? { accounts.first { $0.id == id } }
    public func isSaved(_ id: AccountID) -> Bool { account(id) != nil }
}

/// Reads and writes state.json. It never holds secrets.
public struct StateStore: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func ensureHome() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.switcherHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.switcherHome.path)
    }

    public func load() throws -> SwitcherState {
        guard FileManager.default.fileExists(atPath: paths.stateFile.path) else { return SwitcherState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SwitcherState.self, from: Data(contentsOf: paths.stateFile))
    }

    public func save(_ state: SwitcherState) throws {
        try ensureHome()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try JSONFile.writeData(try encoder.encode(state), to: paths.stateFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateFile.path)
    }
}
