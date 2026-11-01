import RackyPlatform
import RackyProtocol
import Foundation

/// Um modelo que o usuário consegue usar agora, por um dos CLIs instalados. `id` é o que vai no `--model` daquele CLI.
public struct AvailableModel: Codable, Hashable, Sendable, Identifiable {
    public var harness: WorkerHarness
    public var id: String
    public var name: String
    /// Quem treinou o modelo (anthropic, openai, deepseek…), não por onde ele chega.
    public var vendor: String
    /// Por onde ele chega quando não é o CLI do próprio fabricante (openrouter, opencode-go…); `nil` = direto.
    public var via: String?
    public var free: Bool

    public init(harness: WorkerHarness, id: String, name: String, vendor: String, via: String? = nil, free: Bool = false) {
        self.harness = harness; self.id = id; self.name = name; self.vendor = vendor; self.via = via; self.free = free
    }

    /// Chave para casar com a base de referências: `claude-opus-5-5`, `gpt-6-1-terra`, `deepseek-v4-pro`.
    public var family: String { ModelFamily.key(harness == .claude ? ModelFamily.claudeAliases[id] ?? id : id) }
}

public enum ModelFamily {
    /// Último pedaço do caminho, minúsculo, sem marca de grátis nem data de snapshot (`-0813`), só letras e números:
    /// `claude-opus-5.5`, `claude-opus-5-5` e `qwen-3.8-max-0902` / `qwen3.8-max` caem na mesma chave.
    public static func key(_ raw: String) -> String {
        var name = (raw.split(separator: "/").last.map(String.init) ?? raw).lowercased()
        for suffix in [":free", "-free"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        if let range = name.range(of: #"-\d{4}$"#, options: .regularExpression) { name.removeSubrange(range) }
        return String(name.filter { $0.isLetter || $0.isNumber })
    }

    /// Os aliases do Claude Code apontam para a versão mais nova de cada linha (01/11: Fable 5.1, Opus/Sonnet/Haiku 5.5).
    public static let claudeAliases = ["fable": "claude-fable-5-1", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"]
}

/// Lê a lista de modelos de cada CLI. Puro (texto entra, lista sai) para os testes usarem as saídas reais.
public enum ModelCatalogParser {
    /// O Claude Code não lista modelos; aceita os aliases que apontam para a versão mais nova de cada linha.
    /// O plano decide quais funcionam de fato: um alias recusado aparece no placar como falha, não some daqui.
    public static func claude() -> [AvailableModel] {
        [("fable", "Claude Fable"), ("opus", "Claude Opus"), ("sonnet", "Claude Sonnet"), ("haiku", "Claude Haiku")].map {
            AvailableModel(harness: .claude, id: $0.0, name: $0.1, vendor: "anthropic")
        }
    }

    /// `codex debug models`: catálogo JSON. Só os visíveis no seletor do próprio Codex (`visibility == "list"`).
    public static func codex(_ data: Data) -> [AvailableModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return AvailableModel(harness: .codex, id: slug, name: model["display_name"] as? String ?? slug, vendor: "openai")
            }
    }

    /// `opencode models`: uma linha `provedor/modelo` por modelo. Roteadores (`~…-latest`, `openrouter/free`) ficam de fora:
    /// o placar precisa saber qual modelo rodou de verdade.
    public static func openCode(_ text: String) -> [AvailableModel] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: "/").map(String.init)
            guard parts.count >= 2, !line.contains(" "), seen.insert(line).inserted else { return nil }
            let provider = parts[0]
            if parts.dropFirst().contains(where: { $0.hasPrefix("~") }) || parts.last == "free" { return nil }
            let model = parts.last!.lowercased()
            let free = model.hasSuffix(":free") || model.hasSuffix("-free")
            let vendor = parts.count >= 3 ? parts[1].lowercased() : vendorGuess(model) ?? provider
            let direct = ["anthropic", "openai", "google", "deepseek", "moonshotai", "xai"].contains(provider)
            return AvailableModel(harness: .opencode, id: line, name: parts.dropFirst().joined(separator: "/"),
                                  vendor: vendor, via: direct ? nil : provider, free: free)
        }
    }

    /// Fabricante pelo nome, para provedores que não dizem (`opencode-go/kimi-k3`).
    static func vendorGuess(_ model: String) -> String? {
        let table: [(String, String)] = [
            ("claude", "anthropic"), ("gpt", "openai"), ("deepseek", "deepseek"), ("kimi", "moonshotai"), ("glm", "z-ai"),
            ("qwen", "qwen"), ("gemini", "google"), ("gemma", "google"), ("grok", "xai"), ("minimax", "minimax"),
            ("mimo", "xiaomi"), ("nemotron", "nvidia"),
        ]
        return table.first { model.hasPrefix($0.0) }?.1
    }
}

/// O que o usuário tem, CLI por CLI. Um CLI ausente ou que falhou fica com lista vazia e o motivo em `issues`.
public struct ModelInventory: Codable, Equatable, Sendable {
    public var models: [AvailableModel]
    public var issues: [String: String]
    public var discoveredAt: Date

    public init(models: [AvailableModel], issues: [String: String] = [:], discoveredAt: Date = Date()) {
        self.models = models; self.issues = issues; self.discoveredAt = discoveredAt
    }

    public func models(for harness: WorkerHarness) -> [AvailableModel] { models.filter { $0.harness == harness } }
    public var harnesses: [WorkerHarness] { WorkerHarness.allCases.filter { h in models.contains { $0.harness == h } } }
}

/// Pergunta a cada CLI instalado quais modelos ele aceita. Só comandos de leitura; nada de login, nada de rodar agente.
public actor ModelDiscovery {
    private let runner: any CommandRunning
    private let environment: @Sendable () async -> [String: String]
    private let overrides: [TerminalProvider: String]
    private let timeout: Duration
    private var cached: ModelInventory?

    public init(runner: any CommandRunning = SystemCommandRunner(), environment: @escaping @Sendable () async -> [String: String],
                overrides: [TerminalProvider: String] = [:], timeout: Duration = .seconds(30)) {
        self.runner = runner; self.environment = environment; self.overrides = overrides; self.timeout = timeout
    }

    public func inventory(force: Bool = false) async -> ModelInventory {
        if !force, let cached { return cached }
        let env = await environment()
        var models: [AvailableModel] = []
        var issues: [String: String] = [:]
        for harness in WorkerHarness.allCases {
            let name = harness.rawValue
            guard let path = CLIExecutableResolver.resolve(name: name, searchPath: env["PATH"], override: overrides[harness.provider]) else {
                issues[name] = "not installed"
                continue
            }
            switch harness {
            case .claude:
                models += ModelCatalogParser.claude()
            case .codex:
                switch await run(path, ["debug", "models"], env) {
                case .success(let out):
                    let found = ModelCatalogParser.codex(out.stdout)
                    if found.isEmpty { issues[name] = "the model list was empty or unreadable" }
                    models += found
                case .failure(let reason): issues[name] = reason
                }
            case .opencode:
                switch await run(path, ["models"], env) {
                case .success(let out):
                    let found = ModelCatalogParser.openCode(out.stdoutString)
                    if found.isEmpty { issues[name] = "no models configured" }
                    models += found
                case .failure(let reason): issues[name] = reason
                }
            }
        }
        let result = ModelInventory(models: models, issues: issues)
        cached = result
        return result
    }

    private enum Outcome { case success(ProcessOutput), failure(String) }

    private func run(_ path: String, _ arguments: [String], _ env: [String: String]) async -> Outcome {
        let request = ProcessRequest(executable: URL(fileURLWithPath: path), arguments: arguments, environment: env,
                                     currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                                     timeout: timeout, maxOutputBytes: 4 * 1024 * 1024)
        do {
            let out = try await runner.run(request)
            return out.exitCode == 0 ? .success(out) : .failure("exited with \(out.exitCode)")
        } catch ProcessRunnerError.timedOut { return .failure("timed out") }
        catch ProcessRunnerError.launchFailed(let message) { return .failure(message) }
        catch { return .failure("\(error)") }
    }
}

extension WorkerHarness {
    var provider: TerminalProvider {
        switch self { case .claude: .claude; case .codex: .codex; case .opencode: .opencode }
    }
}
