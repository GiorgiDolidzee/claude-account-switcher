import Foundation

public enum LoginSetError: Error, Equatable {
    case invalid(String)
}

/// The measured list of what makes up a login (written by Step 0).
public struct LoginSet: Codable, Sendable, Equatable {
    public struct LoginCookie: Codable, Sendable, Equatable {
        public var hostSuffix: String
        public var name: String
        public init(hostSuffix: String, name: String) { self.hostSuffix = hostSuffix; self.name = name }
    }

    public struct App: Codable, Sendable, Equatable {
        public var items: [String]
        public var configKeys: [String]
        public var accountIdKey: String
        public var tokenKeys: [String]
        public var loginCookie: LoginCookie
        public init(items: [String], configKeys: [String], accountIdKey: String, tokenKeys: [String], loginCookie: LoginCookie) {
            self.items = items; self.configKeys = configKeys; self.accountIdKey = accountIdKey
            self.tokenKeys = tokenKeys; self.loginCookie = loginCookie
        }
    }

    public struct CLI: Codable, Sendable, Equatable {
        public var keychainService: String
        public var claudeJsonKeys: [String]
        public var claudeHomeItems: [String]
        public init(keychainService: String, claudeJsonKeys: [String], claudeHomeItems: [String]) {
            self.keychainService = keychainService; self.claudeJsonKeys = claudeJsonKeys; self.claudeHomeItems = claudeHomeItems
        }
    }

    public var schemaVersion: Int
    public var measuredAt: String
    public var claudeAppVersion: String
    public var claudeCliVersion: String
    public var app: App
    public var cli: CLI

    public init(schemaVersion: Int, measuredAt: String, claudeAppVersion: String, claudeCliVersion: String, app: App, cli: CLI) {
        self.schemaVersion = schemaVersion; self.measuredAt = measuredAt
        self.claudeAppVersion = claudeAppVersion; self.claudeCliVersion = claudeCliVersion
        self.app = app; self.cli = cli
    }

    /// Things in Claude's folder that are never part of a login.
    public static let protectedAppItems: Set<String> = [
        "config.json", "claude_desktop_config.json", "claude-code-sessions", "local-agent-mode-sessions",
        "plugin-list", "scratch-workspaces", "vm_bundles", "claude-code", "claude-code-vm", "claude-code-spare",
        "side-session-notes", "extensions-blocklist.json",
    ]

    /// Things in ~/.claude that every account shares (also linked into side terminals).
    public static let sharedClaudeHomeItems = [
        "CLAUDE.md", "settings.json", "statusline.sh", "skills", "plugins", "agents", "commands", "hooks",
        "projects", "plans",
    ]

    public static func load(from url: URL) throws -> LoginSet {
        let set = try JSONDecoder().decode(LoginSet.self, from: Data(contentsOf: url))
        try set.validate()
        return set
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    public func validate() throws {
        func fail(_ reason: String) -> LoginSetError { .invalid(reason) }
        guard schemaVersion == 1 else { throw fail("unknown schema version") }
        guard !app.items.isEmpty else { throw fail("no app items") }
        for item in app.items {
            guard Self.isPlainName(item) else { throw fail("bad app item name: \(item)") }
            guard !Self.protectedAppItems.contains(item) else { throw fail("protected app item: \(item)") }
        }
        guard !app.configKeys.isEmpty else { throw fail("no config keys") }
        guard app.configKeys.contains(app.accountIdKey) else { throw fail("account id key is not in config keys") }
        guard !app.tokenKeys.isEmpty, app.tokenKeys.allSatisfy(app.configKeys.contains) else {
            throw fail("token keys must be in config keys")
        }
        guard !app.loginCookie.name.isEmpty, !app.loginCookie.hostSuffix.isEmpty else { throw fail("no login cookie") }
        guard cli.keychainService == KeychainNames.liveCLI else { throw fail("wrong keychain service") }
        guard cli.claudeJsonKeys.contains("oauthAccount") else { throw fail("oauthAccount is missing") }
        for item in cli.claudeHomeItems {
            guard Self.isPlainName(item) else { throw fail("bad ~/.claude item name: \(item)") }
            guard !Self.sharedClaudeHomeItems.contains(item) else { throw fail("shared ~/.claude item: \(item)") }
        }
    }
}
