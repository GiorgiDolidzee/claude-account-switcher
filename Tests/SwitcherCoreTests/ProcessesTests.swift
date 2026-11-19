import Foundation
import Testing
@testable import SwitcherCore

@Suite struct ProcessesTests {
    let fx = Fixture()
    var p: Paths { fx.paths }

    func proc(_ path: String, configDir: String? = nil, readable: Bool = true, pid: Int32 = 10) -> ProcInfo {
        ProcInfo(pid: pid, executablePath: path, configDir: configDir, envReadable: readable)
    }

    @Test func classifiesAppHelpersAndCodeSessions() {
        let bundle = p.appBundle.path
        for path in [bundle + "/Contents/MacOS/Claude",
                     bundle + "/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
                     bundle + "/Contents/Frameworks/Squirrel.framework/Resources/ShipIt",
                     p.appData.path + "/claude-code/2.1.325/x/claude.app/Contents/MacOS/claude"] {
            #expect(ProcClassifier.kind(of: proc(path, configDir: "/some/dir"), paths: p) == .app, "\(path)")
        }
    }

    @Test func classifiesCLIs() {
        let versioned = p.home.path + "/.local/share/claude/versions/2.1.118"
        let brew = "/opt/homebrew/Caskroom/claude-code/2.1.311/claude"
        #expect(ProcClassifier.kind(of: proc(versioned), paths: p) == .mainCLI)
        #expect(ProcClassifier.kind(of: proc(brew, configDir: ""), paths: p) == .mainCLI)
        #expect(ProcClassifier.kind(of: proc(brew, configDir: p.sideHome(idW).path), paths: p) == .sideCLI)
        #expect(ProcClassifier.kind(of: proc(brew, configDir: p.claudeHome.path + "/"), paths: p) == .mainCLI)
        #expect(ProcClassifier.kind(of: proc(brew, configDir: p.sideHome(idW).path, readable: false), paths: p) == .mainCLI)
        #expect(ProcClassifier.kind(of: proc("/somewhere/bin/claude"), paths: p) == .mainCLI)
        #expect(ProcClassifier.kind(of: proc("/usr/bin/vim"), paths: p) == .other)
    }

    @Test func classifiesNpmInstalledCLI() {
        let script = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let node = ProcInfo(pid: 20, executablePath: "/opt/homebrew/Cellar/node/22.1.0/bin/node", configDir: nil,
                            envReadable: true, runsClaudeScript: true)
        #expect(ProcClassifier.kind(of: node, paths: p) == .mainCLI)
        let side = ProcInfo(pid: 21, executablePath: "/usr/local/bin/node", configDir: p.sideHome(idW).path,
                            envReadable: true, runsClaudeScript: true)
        #expect(ProcClassifier.kind(of: side, paths: p) == .sideCLI)
        #expect(ProcClassifier.kind(of: proc("/usr/local/bin/node"), paths: p) == .other)

        let buf = buffer(argc: 2, ["/usr/local/bin/node", "node", script, "HOME=/h"])
        #expect(ProcArgs.configDir(fromProcArgs2: buf)?.runsClaudeScript == true)
        let other = buffer(argc: 2, ["/usr/local/bin/node", "node", "/x/server.js", "HOME=/h"])
        #expect(ProcArgs.configDir(fromProcArgs2: other)?.runsClaudeScript == false)
    }

    @Test func blockersSkipOwnPIDAndSideCLIs() {
        let brew = "/opt/homebrew/Caskroom/claude-code/2.1.311/claude"
        let procs = [proc(p.appBundle.path + "/Contents/MacOS/Claude", pid: 1),
                     proc(brew, pid: 2),
                     proc(brew, configDir: p.sideHome(idW).path, pid: 3),
                     proc(brew, pid: 4),
                     proc("/usr/bin/vim", pid: 5)]
        let b = blockers(in: procs, paths: p, ownPID: 4)
        #expect(b.app.map(\.pid) == [1])
        #expect(b.mainCLIs.map(\.pid) == [2])
        #expect(!b.isEmpty)
        #expect(blockers(in: [procs[2], procs[4]], paths: p, ownPID: 4).isEmpty)
    }

    func buffer(argc: Int32, _ strings: [String], pad: Int = 2) -> [UInt8] {
        var out = withUnsafeBytes(of: argc) { Array($0) }
        for (i, s) in strings.enumerated() {
            out += Array(s.utf8) + [0]
            if i == 0 { out += [UInt8](repeating: 0, count: pad) }
        }
        return out + [0]
    }

    @Test func parsesProcArgs2() {
        let full = buffer(argc: 2, ["/x/claude", "claude", "--resume", "HOME=/h", "CLAUDE_CONFIG_DIR=/a b/c"])
        let parsed = ProcArgs.configDir(fromProcArgs2: full)
        #expect(parsed?.exec == "/x/claude")
        #expect(parsed?.configDir == "/a b/c")

        let noEnv = buffer(argc: 2, ["/x/claude", "claude", "--resume"])
        #expect(ProcArgs.configDir(fromProcArgs2: noEnv)?.configDir == nil)
        #expect(ProcArgs.configDir(fromProcArgs2: noEnv)?.exec == "/x/claude")

        // An argument that looks like the variable is not the environment.
        let trick = buffer(argc: 2, ["/x/claude", "claude", "CLAUDE_CONFIG_DIR=/arg", "HOME=/h"])
        #expect(ProcArgs.configDir(fromProcArgs2: trick)?.configDir == nil)

        #expect(ProcArgs.configDir(fromProcArgs2: [1, 2, 3]) == nil)
        #expect(ProcArgs.configDir(fromProcArgs2: []) == nil)
    }

    @Test func libprocSeesThisTestProcess() {
        let me = LibprocInspector().list().first { $0.pid == getpid() }
        #expect(me != nil)
        #expect(me?.envReadable == true)
        #expect(me?.executablePath.isEmpty == false)
    }
}
