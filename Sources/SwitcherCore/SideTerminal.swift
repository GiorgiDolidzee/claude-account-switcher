import Foundation

/// A side-by-side terminal: its own CLAUDE_CONFIG_DIR with its own login,
/// sharing skills, plugins, CLAUDE.md, settings and projects with ~/.claude through links.
public struct SideTerminal: Sendable {
    let paths: Paths
    let loginSet: LoginSet

    public init(paths: Paths, loginSet: LoginSet) { self.paths = paths; self.loginSet = loginSet }

    /// Single-quote shell quoting.
    static func q(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func shellQuote(_ text: String) -> String { q(text) }

    /// Makes the side folder ready and writes the file Terminal will run. Returns that file.
    public func prepare(_ id: AccountID, displayName: String, claudeBinary: String) throws -> URL {
        let fm = FileManager.default
        let home = paths.sideHome(id)
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)

        for item in LoginSet.sharedClaudeHomeItems {
            let source = paths.claudeHome.appendingPathComponent(item)
            let link = home.appendingPathComponent(item)
            if pathExists(source), !pathExists(link) {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
            }
        }

        let ownJSON = home.appendingPathComponent(".claude.json")
        if !pathExists(ownJSON) {
            var copy = try JSONFile.readRaw(paths.claudeJSON) ?? RawJSONObject()
            for key in Set(loginSet.cli.claudeJsonKeys).union(["oauthAccount"]) { copy.remove(key) }
            try JSONFile.writeRaw(copy, to: ownJSON)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownJSON.path)
        }

        let command = home.appendingPathComponent("open-terminal.command")
        try writeCommand(command, configDir: home.path, displayName: displayName, claudeBinary: claudeBinary)
        return command
    }

    /// A terminal that uses the main login (for the account the main CLI is already on). No side folder.
    public func prepareMain(displayName: String, claudeBinary: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.switcherHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = paths.switcherHome.appendingPathComponent("open-main-terminal.command")
        try writeCommand(command, configDir: nil, displayName: displayName, claudeBinary: claudeBinary)
        return command
    }

    /// Runs the same `claude` the user's Terminal would run; the full path is only a fallback.
    private func writeCommand(_ file: URL, configDir: String?, displayName: String, claudeBinary: String) throws {
        let environment = configDir.map { "export CLAUDE_CONFIG_DIR=\(Self.q($0))" } ?? "unset CLAUDE_CONFIG_DIR"
        let script = """
        #!/bin/bash
        \(environment)
        printf '\\033]0;%s\\007' \(Self.q("Claude — " + displayName))
        cd "$HOME"
        if command -v claude >/dev/null 2>&1; then
          claude
        else
          \(Self.q(claudeBinary))
        fi
        exec "${SHELL:-/bin/zsh}" -l

        """
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }

    /// True when the side folder is logged in to some other account.
    public func isWrongAccount(_ id: AccountID) -> Bool {
        let file = paths.sideHome(id).appendingPathComponent(".claude.json")
        let account = ((try? JSONFile.readObject(file)) ?? nil)?["oauthAccount"] as? [String: Any]
        guard let uuid = account?["accountUuid"] as? String else { return false }
        return uuid.lowercased() != id.raw
    }

    public func keychainService(_ id: AccountID) -> String {
        KeychainNames.sideService(configDir: paths.sideHome(id).path)
    }

    public static func resolveClaudeBinary(home: URL, exists: (String) -> Bool) -> String {
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home.appendingPathComponent(".npm-global/bin/claude").path, home.appendingPathComponent(".bun/bin/claude").path,
                          home.appendingPathComponent(".claude/local/claude").path]
        return candidates.first(where: exists) ?? "claude"
    }
}
