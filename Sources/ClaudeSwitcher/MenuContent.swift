import AppKit
import SwiftUI
import SwitcherCore

/// The popover, fed from the live model.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        MenuView(state: model.menuViewState, actions: MenuActions(
            switchTo: { model.switchTo($0) },
            save: { model.saveAccount($0) },
            add: { model.addAccount() },
            openTerminal: { model.openTerminal($0) },
            rename: { model.rename($0) },
            remove: { model.remove($0) },
            setLaunchAtLogin: { model.setLaunchAtLogin($0) },
            openFolder: { model.openFolder() },
            about: { model.showAbout() },
            quit: { NSApp.terminate(nil) }
        ))
    }
}

extension AppModel {
    /// The account shown in the header: the app's account, else the CLI's.
    var headerAccount: AccountID? { live.appAccount ?? live.cliAccount }

    /// This app's own icon (an original drawing, not Anthropic's logo).
    var appIcon: NSImage { AppIcon.image }

    var menuViewState: MenuViewState {
        let shown = headerAccount
        func pill(_ side: String, account: AccountID?, loggedIn: Bool) -> MenuViewState.Pill {
            if let account {
                return account == shown ? .init(text: side, tone: .match) : .init(text: "\(side): \(label(account))", tone: .other)
            }
            return .init(text: loggedIn ? "\(side): unknown" : "\(side): logged out", tone: .off)
        }

        let title: String
        if let shown {
            title = label(shown)
        } else if live.appOwnerUnknown || live.cliOwnerUnknown {
            title = "Unknown account"
        } else {
            title = "Logged out"
        }

        let saveButtons = summary.unsaved.map { id in
            MenuViewState.SaveButton(id: id, title: id == shown ? "Save this account" : "Save \(label(id))")
        }
        // The first line is the "App: … · CLI: …" status, which the header replaces.
        // Other one-line summaries ("Could not read …") are kept as notices.
        var notices = summary.lines
        if let first = notices.first, first.hasPrefix("App: ") || first == "Starting…" { notices.removeFirst() }
        let accounts = state.accounts.map { MenuViewState.Account(id: $0.id, name: $0.name, canRemove: !isLive($0.id)) }

        return MenuViewState(
            icon: appIcon,
            title: title,
            appPill: pill("App", account: live.appAccount, loggedIn: live.appLoggedIn),
            cliPill: pill("CLI", account: live.cliAccount, loggedIn: live.cliLoggedIn),
            notSaved: shown.map { !state.isSaved($0) } ?? false,
            saveButtons: saveButtons,
            notices: notices,
            busy: busy,
            canSwitch: loginSet != nil,
            switchRows: accounts.filter { !isActive($0.id) },
            accounts: accounts,
            launchAtLogin: launchAtLogin
        )
    }
}
