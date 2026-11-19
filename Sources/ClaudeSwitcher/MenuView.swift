import AppKit
import SwiftUI
import SwitcherCore

/// Everything the popover shows, as plain values. Built from AppModel, or from sample data in preview mode.
struct MenuViewState {
    struct Pill: Equatable {
        enum Tone { case match, other, off }
        var text: String
        var tone: Tone
    }

    struct Account: Identifiable, Equatable {
        var id: AccountID
        var name: String
        var canRemove: Bool
    }

    struct SaveButton: Identifiable, Equatable {
        var id: AccountID
        var title: String
    }

    var icon: NSImage?
    var title: String
    var appPill: Pill
    var cliPill: Pill
    var notSaved: Bool
    var saveButtons: [SaveButton]
    var notices: [String]
    var busy: Bool
    var canSwitch: Bool
    /// Saved accounts that are not fully active.
    var switchRows: [Account]
    /// All saved accounts.
    var accounts: [Account]
    var launchAtLogin: Bool
}

/// What the popover can do. Each closure is called after the popover closes.
struct MenuActions {
    var switchTo: @MainActor (AccountID) -> Void = { _ in }
    var save: @MainActor (AccountID) -> Void = { _ in }
    var add: @MainActor () -> Void = {}
    var openTerminal: @MainActor (AccountID) -> Void = { _ in }
    var rename: @MainActor (AccountID) -> Void = { _ in }
    var remove: @MainActor (AccountID) -> Void = { _ in }
    var setLaunchAtLogin: @MainActor (Bool) -> Void = { _ in }
    var openFolder: @MainActor () -> Void = {}
    var about: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}

struct MenuView: View {
    let state: MenuViewState
    let actions: MenuActions
    @Environment(\.dismiss) private var dismiss

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 16)
                .padding(.bottom, 12)

            if !state.notices.isEmpty || state.busy {
                notices
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 12)
            switchSection
                .padding(.vertical, 6)

            Divider().padding(.horizontal, 12)
            actionSection
                .padding(.vertical, 6)

            Divider().padding(.horizontal, 12)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: Self.width)
        .background(RoundedWindow(radius: 16))
    }

    /// Closes the popover first, so dialogs are not hidden behind it.
    private func run(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        Task { @MainActor in action() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Group {
                if let icon = state.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)

            HStack(spacing: 6) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if state.notSaved { TagView(text: "Not saved").fixedSize() }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 6) {
                PillView(pill: state.appPill)
                PillView(pill: state.cliPill)
            }
            .padding(.horizontal, 12)

            ForEach(state.saveButtons) { button in
                Button(button.title) { run { actions.save(button.id) } }
                    .controlSize(.small)
                    .disabled(state.busy)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Notices

    private var notices: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.notices, id: \.self) { line in
                Label {
                    Text(line).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if state.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Working…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Switch to

    private var switchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Switch to")
            if state.switchRows.isEmpty {
                Text("No other account yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(state.switchRows) { account in
                    Button { run { actions.switchTo(account.id) } } label: {
                        HStack(spacing: 8) {
                            AvatarView(name: account.name)
                            Text(account.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .disabled(state.busy || !state.canSwitch)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: Actions

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                ForEach(state.accounts) { account in
                    Button(account.name) { run { actions.openTerminal(account.id) } }
                }
            } label: {
                RowLabel(icon: "terminal", title: "Open terminal as", more: true)
            }
            .menuStyle(.button)
            .buttonStyle(RowButtonStyle())
            .menuIndicator(.hidden)
            .disabled(state.accounts.isEmpty || !state.canSwitch)

            Button { run(actions.add) } label: {
                RowLabel(icon: "person.badge.plus", title: "Add account…")
            }
            .buttonStyle(RowButtonStyle())
            .disabled(state.busy || !state.canSwitch)

            Menu {
                ForEach(state.accounts) { account in
                    Menu(account.name) {
                        Button("Rename…") { run { actions.rename(account.id) } }
                            .disabled(state.busy)
                        Button("Remove…") { run { actions.remove(account.id) } }
                            .disabled(state.busy || !account.canRemove)
                    }
                }
            } label: {
                RowLabel(icon: "person.2", title: "Manage accounts", more: true)
            }
            .menuStyle(.button)
            .buttonStyle(RowButtonStyle())
            .menuIndicator(.hidden)
            .disabled(state.accounts.isEmpty)
        }
        .padding(.horizontal, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { actions.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.callout)
            Spacer()
            Button { run(actions.about) } label: { Image(systemName: "info.circle") }
                .help("About and help")
            Button { run(actions.openFolder) } label: { Image(systemName: "folder") }
                .help("Open switcher folder")
            Button { actions.quit() } label: { Image(systemName: "power") }
                .help("Quit Claude Account Switcher")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Parts

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 2)
    }
}

private struct RowLabel: View {
    let icon: String
    let title: String
    var more = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
            Spacer(minLength: 4)
            if more {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A full-width row with a soft highlight on hover, like a native menu row.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(fill))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hover = $0 }
        }

        private var fill: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.14 }
            return hover ? 0.08 : 0
        }
    }
}

private struct PillView: View {
    let pill: MenuViewState.Pill

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(pill.text).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(pill.tone == .off ? Color.secondary : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(pill.tone == .off ? 0.12 : 0.15)))
    }

    private var color: Color {
        switch pill.tone {
        case .match: .green
        case .other: .orange
        case .off: .gray
        }
    }
}

private struct TagView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
    }
}

private struct AvatarView: View {
    let name: String

    var body: some View {
        Text(letter)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(tint))
    }

    private var letter: String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }

    /// Same name, same color, every run.
    private var tint: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[sum % colors.count]
    }
}

/// Rounds the corners of the popover window, like the system's own menu-bar menus.
struct RoundedWindow: NSViewRepresentable {
    let radius: CGFloat

    final class Probe: NSView {
        var radius: CGFloat = 16

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let frame = window.contentView?.superview else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            frame.wantsLayer = true
            frame.layer?.cornerRadius = radius
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
            window.invalidateShadow()
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.radius = radius
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {}
}
