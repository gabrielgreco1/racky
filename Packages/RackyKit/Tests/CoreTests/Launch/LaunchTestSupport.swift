import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Fixtures (`--help` reais gravados) e golden files ficam no repositório e são lidos por caminho.
enum LaunchFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures = directory.appendingPathComponent("Fixtures", isDirectory: true)
    static let golden = directory.appendingPathComponent("Golden", isDirectory: true)

    static func text(_ name: String) -> String {
        guard let text = try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8) else {
            Issue.record("missing fixture \(name)")
            return ""
        }
        return text
    }

    static func data(_ name: String) -> Data { Data(text(name).utf8) }

    /// Compara com `Golden/<name>`. `RACKY_UPDATE_GOLDEN=1` regrava (revisar o diff antes de commitar).
    static func assertGolden(_ name: String, _ actual: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = golden.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["RACKY_UPDATE_GOLDEN"] == "1" {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("missing golden \(name); run with RACKY_UPDATE_GOLDEN=1", sourceLocation: sourceLocation)
            return
        }
        #expect(actual == expected, "golden \(name) differs", sourceLocation: sourceLocation)
    }
}

enum LaunchSamples {
    static let terminalID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
    static let runID = UUID(uuidString: "00000000-0000-4000-8000-0000000000BB")!
    static let fixedID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let launchDirectory = URL(fileURLWithPath: "/tmp/ab/run/launch/\(runID.uuidString.lowercased())", isDirectory: true)
    static let cwd = "/Users/example/work/repo"

    static let loginEnvironment: [String: String] = [
        "PATH": "/Users/example/.local/bin:/usr/bin:/bin",
        "HOME": "/Users/example", "USER": "example", "SHELL": "/bin/zsh", "LANG": "pt_BR.UTF-8",
        "SSH_AUTH_SOCK": "/private/tmp/agent.sock", "HTTPS_PROXY": "http://proxy:3128",
        // Devem sair pela denylist (06 §1.7):
        "KITTY_PANE_KEY": "pane-1", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "TERM_PROGRAM": "iTerm.app", "PWD": "/tmp",
    ]

    static func exe(_ provider: TerminalProvider) -> String {
        switch provider {
        case .claude: "/usr/local/bin/claude"
        case .codex: "/usr/local/bin/codex"
        case .opencode: "/usr/local/bin/opencode"
        case .shell: "/bin/zsh"
        case .custom: "/usr/bin/env"
        }
    }

    static func input(
        _ spec: LaunchSpec, mode: LaunchMode = .automatic, capabilities: CLICapabilities? = nil,
        catalog: ProfileCatalog = ProfileCatalog(), projectID: UUID? = nil, terminalAddDirs: [String] = [],
        slice: LaunchSlice = .slice1, injection: LaunchInjection? = nil
    ) -> LaunchPlanInput {
        LaunchPlanInput(
            spec: spec, terminalID: terminalID, runID: runID, cwd: cwd, projectID: projectID, terminalAddDirs: terminalAddDirs,
            catalog: catalog, executablePath: exe(spec.provider), capabilities: capabilities,
            loginEnvironment: loginEnvironment, launchDirectory: launchDirectory, mode: mode, slice: slice,
            appVersion: "1.0.0", appSocketPath: "/tmp/ab/run/app.sock", injection: injection
        )
    }

    static func plan(_ spec: LaunchSpec, mode: LaunchMode = .automatic, capabilities: CLICapabilities? = nil,
                     catalog: ProfileCatalog = ProfileCatalog(), projectID: UUID? = nil,
                     slice: LaunchSlice = .slice1, injection: LaunchInjection? = nil) throws -> LaunchPlan {
        try LaunchPlanner.plan(input(spec, mode: mode, capabilities: capabilities, catalog: catalog, projectID: projectID, slice: slice, injection: injection), newUUID: { fixedID })
    }

    /// Capabilities como o `--help` real instalado reporta.
    static func helpCapabilities(_ provider: TerminalProvider, removing: [String] = []) -> CLICapabilities {
        let adapter = ProviderAdapters.adapter(for: provider)
        let name: String
        switch provider {
        case .claude: name = "claude-2.1.302.help.txt"
        case .codex: name = "codex-0.163.0.help.txt"
        default: name = "opencode-1.18.34.help.txt"
        }
        var help = HelpParser.parse(LaunchFixtures.text(name))
        if provider == .codex {
            help.subcommands.formUnion(HelpParser.parse(LaunchFixtures.text("codex-0.163.0.resume.help.txt")).subcommands)
        }
        for flag in removing { help.flags.remove(flag) }
        return CLICapabilities.resolve(version: nil, help: help, adapter: adapter)
    }

    /// Texto estável de um plano para golden file: segmentos como arrays JSON (aspas, quebras e emoji exatos).
    static func render(_ label: String, _ plan: LaunchPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json(_ values: [String]) -> String {
            guard let data = try? encoder.encode(values) else { return "<encode error>" }
            return String(decoding: data, as: UTF8.self)
        }
        var lines = ["case: \(label)"]
        lines.append("executable: \(json(plan.argv.executable))")
        lines.append("identity: \(json(plan.argv.identity))")
        lines.append("profile: \(json(plan.argv.profile))")
        lines.append("injected: \(json(plan.argv.injected))")
        lines.append("prompt: \(json(plan.argv.prompt))")
        lines.append("cwd: \(plan.cwd)")
        lines.append("native_id: \(plan.nativeConversationID ?? "-")")
        lines.append("shield_off: \(plan.skipsPermissions?.tooltip ?? "-")")
        lines.append("warnings: \(plan.warnings.map(\.code.rawValue).joined(separator: ","))")
        lines.append("files: \(plan.files.map { "\($0.name) mode=\(String($0.posixMode, radix: 8)) bytes=\($0.contents.count)" }.joined(separator: ","))")
        return lines.joined(separator: "\n") + "\n"
    }
}
