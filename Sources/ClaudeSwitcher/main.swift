import Foundation

// `--render-preview <out-dir>` draws the menu with sample data and exits.
// It reads no live data and never starts the app.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--render-preview") {
    guard i + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: ClaudeSwitcher --render-preview <out-dir>\n".utf8))
        exit(2)
    }
    let ok = MainActor.assumeIsolated { MenuPreview.render(to: URL(fileURLWithPath: arguments[i + 1])) }
    exit(ok ? 0 : 1)
}

MainActor.assumeIsolated { ClaudeSwitcherApp.main() }
