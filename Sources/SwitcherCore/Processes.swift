import Darwin
import Foundation

public struct ProcInfo: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    /// Value of CLAUDE_CONFIG_DIR in the process's environment, if any. No other variable is kept.
    public let configDir: String?
    public let envReadable: Bool
    /// True when an argument is Claude Code's script (an npm install runs `node …/@anthropic-ai/claude-code/cli.js`).
    public let runsClaudeScript: Bool
    public init(pid: Int32, executablePath: String, configDir: String?, envReadable: Bool, runsClaudeScript: Bool = false) {
        self.pid = pid; self.executablePath = executablePath; self.configDir = configDir; self.envReadable = envReadable
        self.runsClaudeScript = runsClaudeScript
    }
}

public enum ProcKind: Equatable, Sendable { case app, mainCLI, sideCLI, other }

public protocol ProcessInspector: Sendable {
    func list() -> [ProcInfo]
}

public enum ProcClassifier {
    public static func kind(of p: ProcInfo, paths: Paths) -> ProcKind {
        let path = p.executablePath
        if path.hasPrefix(paths.appBundle.path + "/") || path.hasPrefix(paths.appData.path + "/") { return .app }
        let cliPrefixes = [paths.home.path + "/.local/share/claude/versions/",
                           "/opt/homebrew/Caskroom/claude-code/", "/usr/local/Caskroom/claude-code/"]
        let isCLI = (path as NSString).lastPathComponent == "claude" || cliPrefixes.contains { path.hasPrefix($0) }
            || p.runsClaudeScript
        guard isCLI else { return .other }
        guard p.envReadable, let dir = p.configDir, !dir.isEmpty else { return .mainCLI }
        let same = URL(fileURLWithPath: dir).standardizedFileURL.path == paths.claudeHome.standardizedFileURL.path
        return same ? .mainCLI : .sideCLI
    }
}

/// Processes that must be gone before anything moves.
public struct Blockers: Equatable, Sendable {
    public var app: [ProcInfo]
    public var mainCLIs: [ProcInfo]
    public var isEmpty: Bool { app.isEmpty && mainCLIs.isEmpty }
    public init(app: [ProcInfo] = [], mainCLIs: [ProcInfo] = []) { self.app = app; self.mainCLIs = mainCLIs }
}

public func blockers(in procs: [ProcInfo], paths: Paths, ownPID: Int32) -> Blockers {
    var out = Blockers()
    for p in procs where p.pid != ownPID {
        switch ProcClassifier.kind(of: p, paths: paths) {
        case .app: out.app.append(p)
        case .mainCLI: out.mainCLIs.append(p)
        case .sideCLI, .other: break
        }
    }
    return out
}

public enum ProcArgs {
    /// Parses a KERN_PROCARGS2 buffer: argc, executable path, padding, argc arguments, then the environment.
    public static func configDir(fromProcArgs2 buf: [UInt8]) -> (exec: String, configDir: String?, runsClaudeScript: Bool)? {
        guard buf.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard i < buf.count else { return nil }
            var end = i
            while end < buf.count, buf[end] != 0 { end += 1 }
            let s = String(decoding: buf[i..<end], as: UTF8.self)
            i = min(end + 1, buf.count)
            return s
        }

        guard let exec = nextString(), !exec.isEmpty else { return nil }
        while i < buf.count, buf[i] == 0 { i += 1 }
        var script = false
        for _ in 0..<argc {
            guard let arg = nextString() else { return (exec, nil, script) }
            if arg.contains("/@anthropic-ai/claude-code/") { script = true }
        }
        let prefix = "CLAUDE_CONFIG_DIR="
        while let entry = nextString(), !entry.isEmpty {
            if entry.hasPrefix(prefix) { return (exec, String(entry.dropFirst(prefix.count)), script) }
        }
        return (exec, nil, script)
    }
}

/// Lists this user's processes with libproc and sysctl.
public struct LibprocInspector: ProcessInspector {
    public init() {}

    public func list() -> [ProcInfo] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        let me = getuid()
        var out: [ProcInfo] = []
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == me else { continue }
            var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let path = String(decoding: pathBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let args = Self.procArgs(pid), let parsed = ProcArgs.configDir(fromProcArgs2: args) {
                out.append(ProcInfo(pid: pid, executablePath: path, configDir: parsed.configDir, envReadable: true,
                                    runsClaudeScript: parsed.runsClaudeScript))
            } else {
                out.append(ProcInfo(pid: pid, executablePath: path, configDir: nil, envReadable: false))
            }
        }
        return out
    }

    static func procArgs(_ pid: pid_t) -> [UInt8]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var size = buf.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 0 else { return nil }
        return Array(buf.prefix(size))
    }
}
