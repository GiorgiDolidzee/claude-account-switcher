import SwiftUI
import SwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = Self.model
        try? StateStore(paths: model.paths).ensureHome()
        guard SingleInstance.acquire(lockFile: model.paths.lockFile) else {
            NSApp.terminate(nil)   // another copy is already running
            return
        }
        Task { await model.start() }
    }
}

/// Started from main.swift, after the preview check.
struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppDelegate.model

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "arrow.left.arrow.right")
            if model.summary.badge { Text("!") } else if model.busy { Text("…") }
        }
        .menuBarExtraStyle(.window)
    }
}
