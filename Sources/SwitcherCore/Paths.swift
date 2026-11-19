import Foundation

/// Every path the switcher uses. Tests build it under a temp root; the app uses `live()`.
public struct Paths: Sendable, Equatable {
    public let home: URL
    public let appData: URL
    public let appBundle: URL
    public let claudeHome: URL
    public let claudeJSON: URL
    public let switcherHome: URL
    public let userName: String

    public static func live() -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(home: home, appBundle: URL(fileURLWithPath: "/Applications/Claude.app"), userName: NSUserName())
    }

    public static func under(root: URL, userName: String = "tester") -> Paths {
        Paths(home: root, appBundle: root.appendingPathComponent("Applications/Claude.app"), userName: userName)
    }

    private init(home: URL, appBundle: URL, userName: String) {
        self.home = home
        self.appBundle = appBundle
        self.userName = userName
        let support = home.appendingPathComponent("Library/Application Support")
        appData = support.appendingPathComponent("Claude")
        switcherHome = support.appendingPathComponent("ClaudeSwitcher")
        claudeHome = home.appendingPathComponent(".claude")
        claudeJSON = home.appendingPathComponent(".claude.json")
    }

    public var configJSON: URL { appData.appendingPathComponent("config.json") }
    public var stateFile: URL { switcherHome.appendingPathComponent("state.json") }
    public var loginSetFile: URL { switcherHome.appendingPathComponent("login-set.json") }
    public var lockFile: URL { switcherHome.appendingPathComponent(".lock") }
    public var accountsDir: URL { switcherHome.appendingPathComponent("accounts") }
    public var sideDir: URL { switcherHome.appendingPathComponent("side") }

    public func accountDir(_ id: AccountID) -> URL { accountsDir.appendingPathComponent(id.raw) }
    public func appLoginDir(_ id: AccountID) -> URL { accountDir(id).appendingPathComponent("app-login") }
    public func appLoginKeysFile(_ id: AccountID) -> URL { accountDir(id).appendingPathComponent("app-login.json") }
    public func lastRestoredDir(_ id: AccountID) -> URL { accountDir(id).appendingPathComponent("app-login-last-restored") }
    public func cliAccountFile(_ id: AccountID) -> URL { accountDir(id).appendingPathComponent("cli-account.json") }
    public func cliFilesDir(_ id: AccountID) -> URL { accountDir(id).appendingPathComponent("cli-files") }
    public func sideHome(_ id: AccountID) -> URL { sideDir.appendingPathComponent(id.raw) }
    public func strayDir(stamp: String) -> URL { switcherHome.appendingPathComponent("stray-" + stamp) }
    public func backupDir(stamp: String) -> URL { switcherHome.appendingPathComponent("backup-" + stamp) }

    public static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
