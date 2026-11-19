import AppKit
import SwiftUI
import SwitcherCore

/// Hidden preview mode: renders the popover with fake data to PNG files.
/// No AppModel, no live data, no Keychain, no lock, no launch-at-login.
@MainActor
enum MenuPreview {
    static func render(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Could not create \(dir.path): \(error)\n".utf8))
            return false
        }
        var ok = true
        for (name, state) in samples() {
            for scheme in [ColorScheme.light, .dark] {
                let file = dir.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png")
                if let png = png(state, scheme: scheme) {
                    do { try png.write(to: file); print(file.path) } catch { ok = false }
                } else {
                    ok = false
                }
            }
        }
        return ok
    }

    /// Draws through an offscreen NSHostingView. ImageRenderer cannot draw AppKit-backed
    /// controls (the switch, borderless buttons) and shows placeholders for them instead.
    private static func png(_ state: MenuViewState, scheme: ColorScheme) -> Data? {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance

        let view = MenuView(state: state, actions: MenuActions())
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuView.width, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                         pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Sample data (fake)

    private static func samples() -> [(String, MenuViewState)] {
        let work = AccountID("11111111-1111-4111-8111-111111111111")!
        let personal = AccountID("22222222-2222-4222-8222-222222222222")!
        let newOne = AccountID("33333333-3333-4333-8333-333333333333")!
        let icon = AppIcon.image

        let a = MenuViewState(
            icon: icon, title: "Work",
            appPill: .init(text: "App", tone: .match), cliPill: .init(text: "CLI", tone: .match),
            notSaved: false, saveButtons: [], notices: [], busy: false, canSwitch: true,
            switchRows: [.init(id: personal, name: "Personal", canRemove: true)],
            accounts: [.init(id: work, name: "Work", canRemove: false),
                       .init(id: personal, name: "Personal", canRemove: true)],
            launchAtLogin: true)

        let b = MenuViewState(
            icon: icon, title: "Work",
            appPill: .init(text: "App", tone: .match), cliPill: .init(text: "CLI: Personal", tone: .other),
            notSaved: false, saveButtons: [], notices: ["App and CLI use different accounts"], busy: false, canSwitch: true,
            switchRows: [.init(id: work, name: "Work", canRemove: false),
                         .init(id: personal, name: "Personal", canRemove: false)],
            accounts: [.init(id: work, name: "Work", canRemove: false),
                       .init(id: personal, name: "Personal", canRemove: false)],
            launchAtLogin: true)

        let c = MenuViewState(
            icon: icon, title: "you@example.com",
            appPill: .init(text: "App", tone: .match), cliPill: .init(text: "CLI: logged out", tone: .off),
            notSaved: true, saveButtons: [.init(id: newOne, title: "Save this account")],
            notices: ["CLI: run claude, then /login"], busy: false, canSwitch: true,
            switchRows: [], accounts: [], launchAtLogin: false)

        return [("a", a), ("b", b), ("c", c)]
    }
}
