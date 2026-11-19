import AppKit
import Observation
import ServiceManagement
import SwitcherCore

@MainActor
@Observable
final class AppModel {
    let paths = Paths.live()
    private let keychain: KeychainStore = SecurityCLIKeychain()
    private let store: StateStore

    private(set) var loginSet: LoginSet?
    private(set) var switcher: Switcher?
    private(set) var registry: AccountRegistry?
    private(set) var state = SwitcherState()
    private(set) var live = LiveState()
    private(set) var summary = MenuSummary(lines: ["Starting…"], badge: false, unsaved: [])
    private(set) var busy = false
    var launchAtLogin = false

    private var timer: Timer?

    init() {
        store = StateStore(paths: paths)
    }

    var control: ClaudeAppControl? { switcher.map { ClaudeAppControl(paths: paths, switcher: $0) } }

    func label(_ id: AccountID) -> String { accountLabel(id, state: state, live: live) }
    func isActive(_ id: AccountID) -> Bool { live.appAccount == id && live.cliAccount == id }
    func isLive(_ id: AccountID) -> Bool { live.appAccount == id || live.cliAccount == id }

    // MARK: Start

    func start() async {
        try? store.ensureHome()
        loadLoginSet()
        if let s = try? store.load(), !s.launchAtLoginConfigured, (try? SMAppService.mainApp.register()) != nil {
            try? switcher?.updateState { $0.launchAtLoginConfigured = true }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        await recoverIfNeeded()
        await refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                await self.refresh()
            }
        }
    }

    private func loadLoginSet() {
        // First run on this Mac: start from the login set measured by the author, shipped in the app.
        if !FileManager.default.fileExists(atPath: paths.loginSetFile.path),
           let shipped = Bundle.main.url(forResource: "login-set", withExtension: "json") {
            try? FileManager.default.copyItem(at: shipped, to: paths.loginSetFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.loginSetFile.path)
        }
        guard let set = try? LoginSet.load(from: paths.loginSetFile) else {
            loginSet = nil; switcher = nil; registry = nil
            return
        }
        let switcher = Switcher(paths: paths, loginSet: set, keychain: keychain, processes: LibprocInspector())
        loginSet = set
        self.switcher = switcher
        registry = AccountRegistry(paths: paths, store: store, keychain: keychain, switcher: switcher,
                                   trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    func refresh() async {
        if loginSet == nil { loadLoginSet() }
        guard let switcher, let registry, let loginSet else {
            summary = summarize(state: state, live: LiveState(), loginSet: nil, installedAppVersion: nil, sideWrong: [])
            return
        }
        let version = control?.installedVersion()
        let paths = self.paths
        let result = await Task.detached { () -> (SwitcherState, LiveState, MenuSummary)? in
            guard let live = try? switcher.liveState(), let state = try? registry.refresh(live: live) else { return nil }
            let side = SideTerminal(paths: paths, loginSet: loginSet)
            let wrong = state.accounts.map(\.id).filter { side.isWrongAccount($0) }
            return (state, live, summarize(state: state, live: live, loginSet: loginSet, installedAppVersion: version, sideWrong: wrong))
        }.value
        if let result {
            (state, live, summary) = result
        } else {
            summary = MenuSummary(lines: ["Could not read Claude's login data"], badge: true, unsaved: [])
        }
    }

    // MARK: Recovery

    private func recoverIfNeeded() async {
        guard let switcher, let control, (try? switcher.pendingJournal()) ?? nil != nil else { return }
        let choice = Dialogs.ask("A switch was interrupted",
                                 "Claude must quit so it can finish. Your logins are safe.",
                                 buttons: ["Quit Claude and finish", "Later"], style: .warning)
        guard choice == 0 else { return }
        busy = true
        defer { busy = false }
        guard await makeQuiet(switcher: switcher, control: control, confirm: nil) else { return }
        do {
            _ = try await Task.detached { try switcher.recover() }.value
        } catch {
            showStopped(error)
        }
        // Never open Claude on a half-finished switch.
        if ((try? switcher.pendingJournal()) ?? nil) == nil { await control.launchClaude() }
    }

    // MARK: Switching

    func switchTo(_ id: AccountID) { Task { await perform(target: id) } }
    func addAccount() { Task { await perform(target: nil) } }

    /// Quits Claude and closes main CLIs. Returns false if the user cancels or something stays open.
    private func makeQuiet(switcher: Switcher, control: ClaudeAppControl, confirm: String?) async -> Bool {
        let found = await Task.detached { switcher.currentBlockers() }.value
        if found.isEmpty { return true }
        if let confirm {
            var text = ""
            if !found.app.isEmpty { text += "Claude will quit and open again when done.\n" }
            if !found.mainCLIs.isEmpty {
                text += "These Claude Code windows will be closed:\n"
                text += found.mainCLIs.map { "  claude (pid \($0.pid))" }.joined(separator: "\n")
            }
            guard Dialogs.ask(confirm, text, buttons: ["Quit and switch", "Cancel"]) == 0 else { return false }
        }
        if !found.app.isEmpty, !(await control.quitClaude()) {
            Dialogs.ask("Claude did not quit", "Nothing was changed. Quit Claude yourself and try again.", style: .warning)
            return false
        }
        if !found.mainCLIs.isEmpty, !(await control.closeCLIs(found.mainCLIs)) {
            Dialogs.ask("Claude Code is still running", "Nothing was changed. Close it and try again.", style: .warning)
            await control.launchClaude()
            return false
        }
        return true
    }

    private func perform(target: AccountID?) async {
        guard !busy, let switcher, let registry, let control else { return }
        busy = true
        defer { busy = false }
        await refresh()
        if let target, isActive(target) { return }
        let targetName = target.map(label) ?? "a new account"

        // An account that is not saved is never parked silently.
        var discard = false
        let unsaved = summary.unsaved
        if !unsaved.isEmpty {
            let names = unsaved.map(label).joined(separator: ", ")
            let choice = Dialogs.ask("\(names) is not saved. Save this account first?",
                                     "Don't save throws this login away, like a normal log out.",
                                     buttons: ["Save and switch", "Don't save", "Cancel"])
            switch choice {
            case 0:
                for id in unsaved { try? registry.save(id, email: live.cliAccount == id ? live.cliEmail : nil) }
            case 1:
                discard = true
            default:
                return
            }
        }

        let title = target == nil ? "Quit Claude to add an account?" : "Quit Claude to switch to \(targetName)?"
        let wasRunning = !(await Task.detached { switcher.currentBlockers() }.value).app.isEmpty
        guard await makeQuiet(switcher: switcher, control: control, confirm: title) else {
            await refresh()
            return
        }

        do {
            let throwAway = discard
            let result = try await Task.detached {
                if let target { return try switcher.switchTo(target, discardUnsaved: throwAway) }
                return try switcher.parkAll(discardUnsaved: throwAway)
            }.value
            await control.launchClaude()
            await refresh()
            if target == nil {
                Dialogs.info("Log in to the new account",
                             "1. Log in in the Claude app.\n2. In Terminal, run claude and type /login.\n\nThe new account is saved when you log in.")
            } else {
                var todo: [String] = []
                if result.app == .loggedOut { todo.append("Log in to \(targetName) in the Claude app.") }
                if result.cli == .loggedOut { todo.append("In Terminal, run claude and type /login.") }
                if !todo.isEmpty { Dialogs.info("Switched to \(targetName)", "One more step, only this first time:\n" + todo.joined(separator: "\n")) }
                if result.app == .restored, let target { checkLater(target) }
            }
        } catch {
            showStopped(error)
            let pending = ((try? switcher.pendingJournal()) ?? nil) != nil
            if wasRunning, !pending { await control.launchClaude() }
            await refresh()
        }
    }

    /// After a restore, make sure Claude really accepted the login.
    private func checkLater(_ id: AccountID) {
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard !busy else { return }
            await refresh()
            guard !busy, !live.appLoggedIn, live.appAccount != id else { return }
            Dialogs.ask("Claude shows you logged out",
                        "A saved login for \(label(id)) was restored, but Claude did not accept it.\nA copy is kept here:\n\(paths.lastRestoredDir(id).path)\n\nYou can log in by hand, or re-run Step 0.",
                        style: .warning)
        }
    }

    private func showStopped(_ error: Error) {
        let folder = paths.switcherHome.path
        let unfinished = ((try? switcher?.pendingJournal()) ?? nil) != nil
        if unfinished {
            let choice = Dialogs.ask("The switch is not finished",
                                     "It stopped to protect your logins. Nothing was deleted.\nKeep Claude closed. Quit Claude Account Switcher and open it again to finish.\n\nDetails: \(error)\nFolder: \(folder)",
                                     buttons: ["OK", "Open folder"], style: .critical)
            if choice == 1 { openFolder() }
            return
        }
        switch error {
        case SwitchError.busy:
            Dialogs.ask("Claude is still running", "Nothing was changed.", style: .warning)
        case SwitchError.unknownAppOwner, SwitchError.unknownCLIOwner:
            Dialogs.ask("Could not tell which account is logged in", "Nothing was changed.", style: .warning)
        case SwitchError.unsavedAccount:
            Dialogs.ask("This account is not saved", "Nothing was changed. Try again.", style: .warning)
        case SwitchError.backupFailed(let reason):
            Dialogs.ask("The safety copy failed", "Nothing was changed.\n\(reason)", style: .warning)
        case SwitchError.recoveryNeeded:
            Dialogs.ask("An earlier switch is not finished", "Quit and open Claude Account Switcher again to finish it.", style: .warning)
        case is JSONFileError:
            Dialogs.ask("A Claude settings file could not be read", "Nothing was changed.", style: .warning)
        default:
            let choice = Dialogs.ask("The switch stopped to protect your logins",
                                     "Nothing was deleted.\nDetails: \(error)\nFolder: \(folder)",
                                     buttons: ["OK", "Open folder"], style: .critical)
            if choice == 1 { openFolder() }
        }
    }

    // MARK: Accounts

    func saveAccount(_ id: AccountID) {
        guard !busy else { return }
        try? registry?.save(id, email: live.cliAccount == id ? live.cliEmail : nil)
        Task { await refresh() }
    }

    func rename(_ id: AccountID) {
        guard !busy else { return }
        guard let name = Dialogs.prompt("Rename account", text: "Leave empty to use the email.", value: label(id)) else { return }
        try? registry?.rename(id, to: name)
        Task { await refresh() }
    }

    func remove(_ id: AccountID) {
        guard !busy, !isLive(id) else { return }
        let choice = Dialogs.ask("Remove \(label(id))?",
                                 "This deletes its saved logins only. Claude keeps its own data for this account.",
                                 buttons: ["Remove", "Cancel"], style: .warning)
        guard choice == 0 else { return }
        do {
            try registry?.remove(id, live: live)
        } catch {
            Dialogs.ask("Could not remove the account", "\(error)", style: .warning)
        }
        Task { await refresh() }
    }

    // MARK: Side terminal

    func openTerminal(_ id: AccountID) {
        guard !busy, let loginSet else { return }
        let side = SideTerminal(paths: paths, loginSet: loginSet)
        let binary = SideTerminal.resolveClaudeBinary(home: paths.home) { FileManager.default.fileExists(atPath: $0) }
        do {
            // The account the main CLI is already on needs no second login: open a normal terminal.
            let isMain = live.cliAccount == id
            let command = isMain ? try side.prepareMain(displayName: label(id), claudeBinary: binary)
                                 : try side.prepare(id, displayName: label(id), claudeBinary: binary)
            let firstTime = !isMain && (try? keychain.exists(service: side.keychainService(id), account: paths.userName)) != true
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            if firstTime {
                Dialogs.info("First time for \(label(id))", "In the new Terminal window, log in as \(label(id)).\nIf it does not ask, type /login.\n\nThis is needed only once. Next time it opens already logged in.")
            }
        } catch {
            Dialogs.ask("Could not open the terminal", "\(error)", style: .warning)
        }
    }

    // MARK: Other

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Dialogs.ask("Could not change this setting", "\(error.localizedDescription)", style: .warning)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var text = "Version \(version)\n\nUnofficial. Not affiliated with or endorsed by Anthropic.\n\n"
        text += "Switches the logins of the Claude app and the claude CLI. Your logins stay on this Mac.\n\n"
        if let loginSet {
            text += "Login set measured on Claude \(loginSet.claudeAppVersion)"
            if let installed = control?.installedVersion() { text += "; you have \(installed)" }
            text += ".\nIf switching stops working after a Claude update, re-measure."
        } else {
            text += "No login set yet. Re-measure to turn switching on."
        }
        let choice = Dialogs.ask("Claude Account Switcher", text, buttons: ["OK", "Re-measure login…"])
        if choice == 1 { startStep0() }
    }

    /// Opens Terminal with the Step 0 script that ships inside the app.
    func startStep0() {
        guard !busy, let script = Bundle.main.url(forResource: "step0", withExtension: "sh", subdirectory: "step0") else {
            Dialogs.ask("Step 0 is not available", "Rebuild the app with ./install.sh.", style: .warning)
            return
        }
        let ok = Dialogs.ask("Re-measure the login (about 10 minutes)",
                             "Terminal opens and guides you. You log out and log in once.\nClaude quits several times. It only looks at names, never at passwords or tokens.",
                             buttons: ["Open Terminal", "Cancel"])
        guard ok == 0 else { return }
        let command = paths.switcherHome.appendingPathComponent("step0.command")
        let body = "#!/bin/bash\nexec /bin/bash \(SideTerminal.shellQuote(script.path))\n"
        do {
            try Data(body.utf8).write(to: command, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            NSWorkspace.shared.open([command], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Dialogs.ask("Could not open Terminal", "\(error.localizedDescription)", style: .warning)
        }
    }

    func openFolder() {
        NSWorkspace.shared.open(paths.switcherHome)
    }
}
