import RackyPlatform
import RackyProtocol
import ArgumentParser
import Foundation

/// `racky hook-guard --child <pai> --capability <token> --mode ask|full` (F12).
///
/// Hook `PreToolUse` na ferramenta que cria subagentes (`Agent`). Lê o `tool_input` do stdin: se o subagente vai mexer com web
/// (URL, domínio, site, portal, scrape, endpoint...) e não é um `racky-worker-N`, bloqueia a chamada dizendo ao Claude para reservar um
/// computador com `boxes_reserve` e dispará-lo de novo com o slot devolvido. No Ask pergunta ao app (card "Give this subagent a computer?").
/// Responde dentro do prazo: sem app ou sem decisão a tempo, deixa passar (`{}`) e registra em stderr. Sai com 0 sempre.
struct HookGuardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook-guard", abstract: "PreToolUse guard for subagent spawns (Subagent computers).")

    @Option(name: .long, help: "Parent identity registered by the app at launch.")
    var child: String

    @Option(name: .long, help: "Launch capability token.")
    var capability: String

    @Option(name: .long, help: "ask or full.")
    var mode: String = "ask"

    func run() async {
        let raw = HookRunner.readStdin(budgetMs: HookRunner.stdinBudgetMs)
        let output = await SpawnGuardRunner(
            identity: McpIdentity(child: child, capability: capability), socketPath: AppSockPath.resolve(environment: ProcessInfo.processInfo.environment),
            budget: .seconds(SubagentSpawnGuard.helperBudgetSeconds)
        ).decide(raw: raw, mode: SubagentComputersMode(rawValue: mode) ?? .off)
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
    }
}

struct SpawnGuardRunner: Sendable {
    let identity: McpIdentity
    let socketPath: String
    var budget: Duration

    /// Texto do stdout do hook: `{}` (deixa passar) ou o JSON de `deny`.
    func decide(raw: Data, mode: SubagentComputersMode) async -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              SubagentSpawnGuard.toolNames.contains(object["tool_name"] as? String ?? ""),
              let toolInput = object["tool_input"] as? [String: Any] else { return "{}" }
        let input = SubagentSpawnGuard.Input(toolInput: toolInput)
        switch SubagentSpawnGuard.decide(mode: mode, input) {
        case .allow: return "{}"
        case .block(let reason): return SubagentSpawnGuard.denyOutput(reason: reason)
        case .askUser:
            do {
                if let reason = try await askApp(input) { return SubagentSpawnGuard.denyOutput(reason: reason) }
            } catch {
                FileHandle.standardError.write(Data("racky hook-guard: no answer from Racky (\(error)); letting the subagent run\n".utf8))
            }
            return "{}"
        }
    }

    private func askApp(_ input: SubagentSpawnGuard.Input) async throws -> String? {
        let connection = try AppSockClient.connect(path: socketPath)
        defer { Task { await connection.close() } }
        let encoder = CtlCodec.encoder()
        try await connection.send(try encoder.encode(AppSockHello(service: .mcp)))
        try await connection.send(try encoder.encode(identity))
        let params: [String: Any] = ["subagent_type": input.subagentType ?? "", "prompt": input.prompt, "description": input.description]
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "racky/spawn_guard", "params": params]
        try await connection.send(try JSONSerialization.data(withJSONObject: request))
        let budget = budget
        let reply: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let hello = try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await connection.receive())
                guard hello.ok else { throw McpHelperError.refused(hello.error?.message ?? "handshake refused") }
                return try await connection.receive()
            }
            group.addTask {
                try await Task.sleep(for: budget)
                throw McpHelperError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
        let result = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["result"] as? [String: Any]
        guard result?["decision"] as? String == "block" else { return nil }
        return result?["reason"] as? String ?? SubagentSpawnGuard.blockReason
    }
}
