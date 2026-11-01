import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Detecção dos modelos de cada CLI, com trechos das saídas reais de `codex debug models` e `opencode models` (01/11).
@Suite struct ModelDiscoveryTests {
    static let codexJSON = #"""
    {"models":[
      {"slug":"gpt-6.1-terra","display_name":"GPT-6.1 Terra","visibility":"list","priority":3},
      {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list","priority":1},
      {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide","priority":4},
      {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":43}
    ]}
    """#

    static let openCodeText = """
    opencode/deepseek-v4.1-flash-free
    opencode-go/kimi-k3
    opencode-go/claude-haiku-5-5
    openai/gpt-5.6-luna
    openrouter/~anthropic/claude-opus-latest
    openrouter/openrouter/free
    openrouter/google/gemma-4-31b-it:free
    openrouter/anthropic/claude-opus-5.5
    openrouter/anthropic/claude-opus-5.5
    """

    @Test func codexKeepsOnlyListedModelsInPriorityOrder() {
        let models = ModelCatalogParser.codex(Data(Self.codexJSON.utf8))
        #expect(models.map(\.id) == ["gpt-6.1-sol", "gpt-6.1-terra"])
        #expect(models.allSatisfy { $0.harness == .codex && $0.vendor == "openai" && $0.via == nil })
        #expect(models[1].name == "GPT-6.1 Terra")
    }

    @Test func codexGarbageGivesNothing() {
        #expect(ModelCatalogParser.codex(Data("not json".utf8)).isEmpty)
    }

    @Test func openCodeDropsRoutersAndDuplicatesAndMarksFreeOnes() {
        let models = ModelCatalogParser.openCode(Self.openCodeText)
        #expect(models.map(\.id) == [
            "opencode/deepseek-v4.1-flash-free", "opencode-go/kimi-k3", "opencode-go/claude-haiku-5-5", "openai/gpt-5.6-luna",
            "openrouter/google/gemma-4-31b-it:free", "openrouter/anthropic/claude-opus-5.5",
        ])
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(byID["opencode/deepseek-v4.1-flash-free"]?.free == true)
        #expect(byID["opencode/deepseek-v4.1-flash-free"]?.vendor == "deepseek")
        #expect(byID["opencode-go/kimi-k3"]?.vendor == "moonshotai")
        #expect(byID["opencode-go/kimi-k3"]?.via == "opencode-go")
        #expect(byID["openai/gpt-5.6-luna"]?.via == nil)
        #expect(byID["openrouter/google/gemma-4-31b-it:free"]?.free == true)
        #expect(byID["openrouter/anthropic/claude-opus-5.5"]?.vendor == "anthropic")
        #expect(byID["openrouter/anthropic/claude-opus-5.5"]?.via == "openrouter")
    }

    @Test func familyKeyMatchesAcrossProviders() {
        #expect(ModelFamily.key("openrouter/anthropic/claude-opus-5.5") == ModelFamily.key("claude-opus-5-5"))
        #expect(ModelFamily.key("gpt-6.1-terra") == "gpt61terra")
        #expect(ModelFamily.key("opencode/deepseek-v4.1-flash-free") == ModelFamily.key("deepseek-v4.1-flash-1017"))
        #expect(ModelFamily.key("opencode-go/qwen3.8-max") == ModelFamily.key("qwen-3.8-max-0902"))
        #expect(ModelFamily.key("openrouter/google/gemma-4-31b-it:free") == "gemma431bit")
        #expect(AvailableModel(harness: .claude, id: "opus", name: "Claude Opus", vendor: "anthropic").family == "claudeopus55")
    }

    @Test func discoveryAsksEachInstalledCLIAndRecordsWhatFailed() async {
        let runner = FakeModelRunner(outputs: [
            "debug models": ProcessOutput(exitCode: 0, stdout: Data(Self.codexJSON.utf8), stderr: Data(), truncated: false),
            "models": ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data("boom".utf8), truncated: false),
        ])
        let discovery = ModelDiscovery(runner: runner, environment: { ["PATH": ""] },
                                       overrides: [.claude: "/bin/echo", .codex: "/bin/echo", .opencode: "/bin/echo"])
        let inventory = await discovery.inventory()
        #expect(inventory.models(for: .claude).map(\.id) == ["fable", "opus", "sonnet", "haiku"])
        #expect(inventory.models(for: .codex).count == 2)
        #expect(inventory.models(for: .opencode).isEmpty)
        #expect(inventory.issues["opencode"] == "exited with 1")
        #expect(inventory.harnesses == [.claude, .codex])
        #expect(await runner.calls == 2)
        _ = await discovery.inventory()
        #expect(await runner.calls == 2, "segunda consulta vem do cache")
    }

    @Test func missingCLIIsReportedNotGuessed() async {
        let discovery = ModelDiscovery(runner: FakeModelRunner(outputs: [:]), environment: { ["PATH": ""] },
                                       overrides: [.claude: "/nonexistent/claude", .codex: "/nonexistent/codex", .opencode: "/nonexistent/opencode"])
        let inventory = await discovery.inventory()
        #expect(inventory.models.isEmpty)
        #expect(inventory.issues == ["claude": "not installed", "codex": "not installed", "opencode": "not installed"])
    }
}

private actor FakeModelRunner: CommandRunning {
    let outputs: [String: ProcessOutput]
    var calls = 0
    init(outputs: [String: ProcessOutput]) { self.outputs = outputs }
    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        calls += 1
        guard let out = outputs[request.arguments.joined(separator: " ")] else { throw ProcessRunnerError.launchFailed("unexpected") }
        return out
    }
}

/// A base externa que vai com o app: carrega, toda medição tem fonte e data, e cobre os modelos do Claude e do Codex.
@Suite struct ModelReferencesTests {
    @Test func bundledBaseLoadsAndEveryEntryHasASource() throws {
        let base = try ModelReferences.bundled()
        #expect(base.entries.count > 100)
        for entry in base.entries {
            #expect(entry.sourceURL.hasPrefix("https://"), "\(entry.model) \(entry.benchmark)")
            #expect(entry.sourceDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, "\(entry.model)")
        }
    }

    @Test func claudeAndCodexModelsHaveReferences() throws {
        let base = try ModelReferences.bundled()
        let codex = ModelCatalogParser.codex(Data(ModelDiscoveryTests.codexJSON.utf8))
        for model in ModelCatalogParser.claude() + codex {
            #expect(!base.references(family: model.family, skill: .code).isEmpty || !base.references(family: model.family, skill: .plan).isEmpty,
                    "\(model.id) sem referência")
        }
        let opus = base.references(family: "claudeopus55", skill: .code)
        #expect(opus.first?.secondary == false)
        #expect(base.price(family: "claudeopus55")?.inputPerMTok == 4)
    }
}
