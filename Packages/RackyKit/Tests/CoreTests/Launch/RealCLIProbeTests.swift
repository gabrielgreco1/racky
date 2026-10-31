import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Contrato com os CLIs reais instalados (06 §7). Só roda com `AB_REAL_CLI=1`: usa `--version`, `--help` e os comandos de
/// status de login (somente leitura). Nunca executa um agente nem passa prompt. `AB_EVIDENCE_OUT=<arquivo.json>` grava o resultado.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AB_REAL_CLI"] == "1"))
struct RealCLIProbeTests {
    struct Record: Codable {
        var provider: String
        var executable: String?
        var versionText: String?
        var version: String?
        var capabilitySource: String?
        var flagCount: Int?
        var subcommands: [String]
        var login: String
        var issues: [String]
        var helpMatchesFixture: Bool?
        var flagsMissingFromFixture: [String]
        var flagsMissingFromInstalled: [String]
        var argvSample: [String]
        var argvSampleWarnings: [String]
    }

    @Test func probeInstalledCLIs() async throws {
        let loginEnv = LoginShellEnvProvider()
        let prober = CLIProber(environment: { await loginEnv.environment().captured.variables })
        var records: [Record] = []
        let fixtures: [TerminalProvider: (String, CLIVersion)] = [
            .claude: ("claude-2.1.302.help.txt", CLIVersion(2, 1, 302)),
            .codex: ("codex-0.163.0.help.txt", CLIVersion(0, 163, 0)),
            .opencode: ("opencode-1.18.34.help.txt", CLIVersion(1, 18, 34)),
        ]
        for adapter in ProviderAdapters.agents {
            let result = await prober.probe(adapter)
            var record = Record(
                provider: adapter.provider.rawValue, executable: result.executable.map { URL(fileURLWithPath: $0).path },
                versionText: result.versionText, version: result.version?.description,
                capabilitySource: result.capabilities?.source.rawValue, flagCount: result.capabilities?.flags.count,
                subcommands: (result.capabilities?.subcommands ?? []).sorted(), login: "\(result.login)", issues: result.issues,
                helpMatchesFixture: nil, flagsMissingFromFixture: [], flagsMissingFromInstalled: [], argvSample: [], argvSampleWarnings: []
            )
            if let (name, version) = fixtures[adapter.provider], let caps = result.capabilities, result.version == version {
                let fixtureFlags = HelpParser.parse(LaunchFixtures.text(name)).flags
                record.flagsMissingFromFixture = caps.flags.subtracting(fixtureFlags).sorted()
                record.flagsMissingFromInstalled = fixtureFlags.subtracting(caps.flags).sorted()
                record.helpMatchesFixture = record.flagsMissingFromFixture.isEmpty && record.flagsMissingFromInstalled.isEmpty
                #expect(record.helpMatchesFixture == true, "installed --help drifted from the recorded fixture for \(adapter.displayName)")
            }
            if let exe = result.executable {
                var input = LaunchSamples.input(LaunchSpec(provider: adapter.provider, initialPrompt: "hello"), capabilities: result.capabilities)
                input.executablePath = exe
                let plan = try LaunchPlanner.plan(input, newUUID: { LaunchSamples.fixedID })
                record.argvSample = plan.flattenedArgv.map { $0 == exe ? URL(fileURLWithPath: exe).lastPathComponent : $0 }
                record.argvSampleWarnings = plan.warnings.map(\.message)
            }
            #expect(result.isInstalled, "\(adapter.displayName) should be installed on the evidence machine")
            records.append(record)
        }
        if let out = ProcessInfo.processInfo.environment["AB_EVIDENCE_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(records).write(to: URL(fileURLWithPath: out))
        }
    }
}
