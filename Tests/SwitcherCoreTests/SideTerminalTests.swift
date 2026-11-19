import Foundation
import Testing
@testable import SwitcherCore

@Suite struct SideTerminalTests {
    let fx = Fixture()
    var side: SideTerminal { SideTerminal(paths: fx.paths, loginSet: fx.standardLoginSet()) }
    var home: URL { fx.paths.sideHome(idP) }

    @Test func linksOnlyExistingSharedItems() throws {
        fx.write("md", to: fx.paths.claudeHome.appendingPathComponent("CLAUDE.md"))
        fx.write("s", to: fx.paths.claudeHome.appendingPathComponent("skills/a/SKILL.md"))
        fx.write("h", to: fx.paths.claudeHome.appendingPathComponent("history.jsonl"))
        _ = try side.prepare(idP, displayName: "P", claudeBinary: "/bin/echo")
        #expect(try fx.fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("CLAUDE.md").path) == fx.paths.claudeHome.appendingPathComponent("CLAUDE.md").path)
        #expect(fx.read(home.appendingPathComponent("skills/a/SKILL.md")) == "s")
        #expect(!pathExists(home.appendingPathComponent("plugins")))
        #expect(!pathExists(home.appendingPathComponent("history.jsonl")))
        #expect(try fx.fm.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int == 0o700)
        // An item that appears later is linked on the next open.
        fx.write("p", to: fx.paths.claudeHome.appendingPathComponent("plugins/x"))
        _ = try side.prepare(idP, displayName: "P", claudeBinary: "/bin/echo")
        #expect(fx.read(home.appendingPathComponent("plugins/x")) == "p")
    }

    @Test func existingEntryNotReplaced() throws {
        fx.write("shared", to: fx.paths.claudeHome.appendingPathComponent("settings.json"))
        fx.write("own", to: home.appendingPathComponent("settings.json"))
        _ = try side.prepare(idP, displayName: "P", claudeBinary: "/bin/echo")
        #expect(fx.read(home.appendingPathComponent("settings.json")) == "own")
    }

    @Test func claudeJsonCopiedWithoutAccountKeys() throws {
        fx.write(#"{"numStartups":3,"oauthAccount":{"accountUuid":"x"},"projects":{"/a":{"t":1.1}}}"#, to: fx.paths.claudeJSON)
        _ = try side.prepare(idP, displayName: "P", claudeBinary: "/bin/echo")
        let copy = home.appendingPathComponent(".claude.json")
        #expect(fx.read(copy) == #"{"numStartups":3,"projects":{"/a":{"t":1.1}}}"#)
        #expect(try fx.fm.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
        fx.write(#"{"changed":true}"#, to: fx.paths.claudeJSON)
        _ = try side.prepare(idP, displayName: "P", claudeBinary: "/bin/echo")
        #expect(fx.read(copy) == #"{"numStartups":3,"projects":{"/a":{"t":1.1}}}"#)
        // The main file is never touched.
        #expect(fx.read(fx.paths.claudeJSON) == #"{"changed":true}"#)
    }

    @Test func commandFileExportsExactConfigDir() throws {
        #expect(home.path.contains(" "))
        let out = fx.root.appendingPathComponent("out's file.txt")
        let fake = fx.root.appendingPathComponent("fake 'claude'")
        fx.write("#!/bin/bash\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > \"$OUT\"\n", to: fake)
        try fx.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let command = try side.prepare(idP, displayName: "Bob's \"work\" $HOME `x`", claudeBinary: fake.path)
        #expect(command.lastPathComponent == "open-terminal.command")
        #expect(try fx.fm.attributesOfItem(atPath: command.path)[.posixPermissions] as? Int == 0o700)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [command.path]
        process.environment = ["SHELL": "/usr/bin/true", "OUT": out.path, "HOME": fx.root.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(fx.read(out) == home.path)
        #expect(printed.contains("Claude — Bob's \"work\" $HOME `x`"))
    }

    /// Runs a .command file with a fake `claude` and returns what CLAUDE_CONFIG_DIR it saw ("<unset>" if none).
    func run(_ command: URL, pathDir: URL?, inherited: String?) throws -> String? {
        let out = fx.root.appendingPathComponent("seen-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [command.path]
        var env = ["SHELL": "/usr/bin/true", "OUT": out.path, "HOME": fx.root.path,
                   "PATH": (pathDir.map { $0.path + ":" } ?? "") + "/usr/bin:/bin"]
        env["CLAUDE_CONFIG_DIR"] = inherited
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return fx.read(out)
    }

    func fakeClaude(in dir: URL, tag: String) throws -> URL {
        let file = dir.appendingPathComponent("claude")
        fx.write("#!/bin/bash\nprintf '%s' \"\(tag):${CLAUDE_CONFIG_DIR-<unset>}\" > \"$OUT\"\n", to: file)
        try fx.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test func usesTheClaudeFromThePathFirst() throws {
        let onPath = try fakeClaude(in: fx.root.appendingPathComponent("bin on path"), tag: "path")
        let fallback = try fakeClaude(in: fx.root.appendingPathComponent("other"), tag: "fallback")
        let command = try side.prepare(idP, displayName: "P", claudeBinary: fallback.path)
        #expect(try run(command, pathDir: onPath.deletingLastPathComponent(), inherited: nil) == "path:" + home.path)
        #expect(try run(command, pathDir: nil, inherited: nil) == "fallback:" + home.path)
    }

    @Test func mainTerminalUsesTheNormalLogin() throws {
        let fallback = try fakeClaude(in: fx.root.appendingPathComponent("other"), tag: "fallback")
        let command = try side.prepareMain(displayName: "T's", claudeBinary: fallback.path)
        #expect(command.path.hasPrefix(fx.paths.switcherHome.path))
        #expect(try fx.fm.attributesOfItem(atPath: command.path)[.posixPermissions] as? Int == 0o700)
        // Even when started from a side terminal's environment, it uses the main login.
        #expect(try run(command, pathDir: nil, inherited: "/some/side/dir") == "fallback:<unset>")
        #expect(!pathExists(fx.paths.sideDir))
    }

    @Test func wrongAccountDetected() throws {
        #expect(!side.isWrongAccount(idP))
        fx.write(#"{"oauthAccount":{"accountUuid":"\#(idP.raw.uppercased())"}}"#, to: home.appendingPathComponent(".claude.json"))
        #expect(!side.isWrongAccount(idP))
        fx.write(#"{"oauthAccount":{"accountUuid":"\#(idW.raw)"}}"#, to: home.appendingPathComponent(".claude.json"))
        #expect(side.isWrongAccount(idP))
    }

    @Test func resolveBinaryOrder() {
        let home = URL(fileURLWithPath: "/h")
        #expect(SideTerminal.resolveClaudeBinary(home: home, exists: { _ in true }) == "/h/.local/bin/claude")
        #expect(SideTerminal.resolveClaudeBinary(home: home, exists: { $0 != "/h/.local/bin/claude" }) == "/opt/homebrew/bin/claude")
        #expect(SideTerminal.resolveClaudeBinary(home: home, exists: { $0 == "/usr/local/bin/claude" }) == "/usr/local/bin/claude")
        #expect(SideTerminal.resolveClaudeBinary(home: home, exists: { _ in false }) == "claude")
    }
}
