import AppKit
import SwitcherCore

/// Quits and launches the Claude app, and closes main `claude` CLI processes.
@MainActor
struct ClaudeAppControl {
    let paths: Paths
    let switcher: Switcher

    static let bundleID = "com.anthropic.claudefordesktop"

    /// Asks Claude to quit and waits until none of its processes are left.
    func quitClaude(timeout: TimeInterval = 60) async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let left = await Task.detached { [switcher] in switcher.currentBlockers().app }.value
            if left.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Closes main CLI processes: asks nicely first, then forces the ones that stay.
    func closeCLIs(_ procs: [ProcInfo]) async -> Bool {
        func stillThere() -> [ProcInfo] {
            let now = switcher.currentBlockers().mainCLIs
            return procs.filter { p in now.contains { $0.pid == p.pid && $0.executablePath == p.executablePath } }
        }
        for p in stillThere() { kill(p.pid, SIGTERM) }
        for _ in 0..<10 {
            if stillThere().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        for p in stillThere() { kill(p.pid, SIGKILL) }
        for _ in 0..<4 {
            if stillThere().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return stillThere().isEmpty
    }

    func launchClaude() async {
        _ = try? await NSWorkspace.shared.openApplication(at: paths.appBundle, configuration: NSWorkspace.OpenConfiguration())
    }

    func installedVersion() -> String? {
        let plist = paths.appBundle.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
    }
}
