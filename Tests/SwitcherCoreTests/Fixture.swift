import CryptoKit
import Foundation
import SQLite3
@testable import SwitcherCore

let idW = AccountID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
let idP = AccountID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

struct FakeInspector: ProcessInspector {
    var procs: [ProcInfo] = []
    func list() -> [ProcInfo] { procs }
}

/// A throw-away fake home folder. Nothing here touches the real Claude folders or Keychain.
final class Fixture {
    let root: URL
    let paths: Paths
    let keychain: InMemoryKeychain
    let fm = FileManager.default

    init(keychain: InMemoryKeychain = InMemoryKeychain()) {
        self.keychain = keychain
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("switcher tests \(UUID().uuidString)")
            .resolvingSymlinksInPath()
        paths = Paths.under(root: root)
        for dir in [paths.appData, paths.claudeHome, paths.appBundle] {
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit { try? fm.removeItem(at: root) }

    func standardLoginSet() -> LoginSet {
        LoginSet(
            schemaVersion: 1, measuredAt: "2026-11-16T00:00:00Z", claudeAppVersion: "1.0", claudeCliVersion: "2.0",
            app: .init(items: ["Cookies", "Local Storage"],
                       configKeys: ["lastKnownAccountUuid", "oauth:tokenCache"],
                       accountIdKey: "lastKnownAccountUuid", tokenKeys: ["oauth:tokenCache"],
                       loginCookie: .init(hostSuffix: "claude.ai", name: "sessionKey")),
            cli: .init(keychainService: "Claude Code-credentials", claudeJsonKeys: ["oauthAccount"],
                       claudeHomeItems: ["remote-settings.json"]))
    }

    func write(_ text: String, to url: URL) {
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    func writeConfig(_ obj: [String: Any]) { try! JSONFile.writeObject(obj, to: paths.configJSON) }
    func writeClaudeJSON(_ obj: [String: Any]) { try! JSONFile.writeObject(obj, to: paths.claudeJSON) }
    func config() -> [String: Any] { (try? JSONFile.readObject(paths.configJSON)) ?? [:] }
    func claudeJSON() -> [String: Any] { (try? JSONFile.readObject(paths.claudeJSON)) ?? [:] }

    /// A real SQLite Cookies file. `marker` makes each account's file different.
    func writeCookies(loggedIn: Bool, marker: String = "m") {
        let url = paths.appData.appendingPathComponent("Cookies")
        try? fm.removeItem(at: url)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        var sql = "CREATE TABLE cookies(host_key, name, value, encrypted_value);"
        sql += "INSERT INTO cookies VALUES ('.claude.ai','theme','\(marker)','x');"
        if loggedIn { sql += "INSERT INTO cookies VALUES ('.claude.ai','sessionKey','\(marker)','x');" }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
    }

    /// Makes the live side look like `id` is logged in to the app.
    func loginApp(_ id: AccountID, marker: String) {
        writeCookies(loggedIn: true, marker: marker)
        write("ls-\(marker)", to: paths.appData.appendingPathComponent("Local Storage/leveldb/000.log"))
        var c = config()
        c["lastKnownAccountUuid"] = id.raw
        c["oauth:tokenCache"] = "token-\(marker)"
        if c["locale"] == nil { c["locale"] = "en" }
        writeConfig(c)
    }

    /// Makes the live side look like `id` is logged in to the main CLI.
    func loginCLI(_ id: AccountID, marker: String, email: String? = nil) {
        keychain.seed(service: KeychainNames.liveCLI, account: paths.userName, secret: Data("secret-\(marker)".utf8))
        var j = claudeJSON()
        var account: [String: Any] = ["accountUuid": id.raw]
        account["emailAddress"] = email ?? "\(marker)@example.com"
        j["oauthAccount"] = account
        if j["projects"] == nil { j["projects"] = ["/x": ["trusted": true]] }
        writeClaudeJSON(j)
        write("org-\(marker)", to: paths.claudeHome.appendingPathComponent("remote-settings.json"))
    }

    /// Data that must never move.
    func writeProtectedData() {
        write(#"{"k":1}"#, to: paths.appData.appendingPathComponent("claude-code-sessions/a/s.json"))
        write("vm", to: paths.appData.appendingPathComponent("vm_bundles/y"))
        write(#"{"k":1}"#, to: paths.appData.appendingPathComponent("claude_desktop_config.json"))
        write("skill", to: paths.claudeHome.appendingPathComponent("skills/s/SKILL.md"))
        write(#"{"k":1}"#, to: paths.claudeHome.appendingPathComponent("settings.json"))
    }

    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Everything that matters, as path/key -> hash. `ignoring` drops paths with these prefixes (relative to root).
    func fingerprint(ignoring: [String] = []) -> [String: String] {
        var out: [String: String] = [:]
        let marker = root.lastPathComponent + "/"
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in walker {
                guard let cut = url.path.range(of: marker) else { continue }
                let rel = String(url.path[cut.upperBound...])
                if ignoring.contains(where: { rel.hasPrefix($0) || rel.contains("/" + $0) }) { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, let data = try? Data(contentsOf: url) {
                    if rel.hasSuffix(".json"), !rel.hasSuffix("state.json"),
                       let obj = try? JSONFile.readObject(url) {
                        for (k, v) in obj { out[rel + "#" + k] = sha((try? JSONFile.canonical(v)) ?? Data()) }
                    } else {
                        out[rel] = sha(data)
                    }
                }
            }
        }
        for (k, v) in keychain.allEntries { out["keychain:" + k.replacingOccurrences(of: "\u{0}", with: "/")] = sha(v) }
        return out
    }
}
