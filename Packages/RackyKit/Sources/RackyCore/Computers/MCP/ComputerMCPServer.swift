import RackyPlatform
import RackyProtocol
import Foundation

/// Servidor MCP (JSON-RPC 2.0) das capacidades do computador (08 §0, §1: o MCP mora no app; o helper `racky mcp` só liga
/// o stdio do CLI ao `app.sock`). Sem estado por conexão: cada requisição traz a identidade do filho.
public struct ComputerMCPServer: Sendable {
    public static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public static let serverVersion = "1.0.0"

    public let tools: ComputerToolService

    public init(tools: ComputerToolService) { self.tools = tools }

    private static func reply(_ id: JSON, result: JSON) -> Data {
        JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).data()
    }

    private static func fail(_ id: JSON, code: Int, _ message: String) -> Data {
        JSON.object(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]).data()
    }

    /// Resposta à mensagem JSON-RPC `message` do `child`. `nil` para notificações (sem `id`).
    public func handle(_ message: Data, child: String) async -> Data? {
        guard let parsed = try? JSON.parse(message), case .object(let object) = parsed, object["jsonrpc"]?.string == "2.0",
              let method = object["method"]?.string else {
            return Self.fail(.null, code: -32600, "Invalid request")
        }
        guard let id = object["id"], !id.isNull else { return nil }  // notificação (`notifications/initialized`...)
        guard id.string != nil || id.int != nil else { return Self.fail(.null, code: -32600, "Invalid request id") }
        let params = object["params"]
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.string ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions.last!
            let isParent = await tools.hub.role(of: child) == .parent
            return Self.reply(id, result: [
                "protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "racky", "version": .string(Self.serverVersion)],
                "instructions": .string(isParent ? ToolCatalog.parentInstructions : ToolCatalog.serverInstructions),
            ])
        case "ping":
            return Self.reply(id, result: [:])
        case "tools/list":
            let isParent = await tools.hub.role(of: child) == .parent
            return Self.reply(id, result: ["tools": .array((isParent ? ToolCatalog.parentTools : ToolCatalog.all).map(\.mcpJSON))])
        case "racky/spawn_guard":
            // Hook PreToolUse do pai (F12): `{decision: allow|block, reason?}`. Só o pai pergunta.
            guard await tools.hub.role(of: child) == .parent else { return Self.fail(id, code: -32601, "Method not found") }
            let input = SubagentSpawnGuard.Input(
                subagentType: params?["subagent_type"]?.string, prompt: params?["prompt"]?.string ?? "", description: params?["description"]?.string ?? "")
            switch await tools.spawnGuard(parent: child, input: input) {
            case .allow: return Self.reply(id, result: ["decision": "allow"])
            case .block(let reason): return Self.reply(id, result: ["decision": "block", "reason": .string(reason)])
            }
        case "tools/call":
            guard let name = params?["name"]?.string else { return Self.fail(id, code: -32602, "Invalid tool call: name is required") }
            let arguments = params?["arguments"] ?? [:]
            guard arguments.object != nil || arguments.isNull else { return Self.fail(id, code: -32602, "Invalid tool call: arguments must be an object") }
            let routed = await route(name, arguments: arguments, params: params, child: child)
            let outcome: ToolOutcome
            switch routed {
            case .failure(let denied): outcome = denied
            case .child(let effective): outcome = await tools.call(name, arguments: arguments, child: effective)
            }
            return Self.reply(id, result: ["content": .array(outcome.content), "isError": .bool(outcome.isError)])
        default:
            return Self.fail(id, code: -32601, "Method not found")
        }
    }
}

extension ComputerMCPServer {
    enum Routing { case child(String), failure(ToolOutcome) }

    /// Quem chamou, segundo o Codex: `_meta.threadId` e `x-codex-turn-metadata.thread_source` em cada `tools/call`. Outros clientes
    /// (Claude, OpenCode) não mandam isso e passam direto.
    struct CallerMeta: Equatable {
        var threadID: String?
        var isSubagent: Bool
        init(_ params: JSON?) {
            let meta = params?["_meta"]
            threadID = meta?["threadId"]?.string ?? meta?["x-codex-turn-metadata"]?["thread_id"]?.string
            isSubagent = meta?["x-codex-turn-metadata"]?["thread_source"]?.string == "subagent"
        }
    }

    /// Decide com que identidade a chamada roda. Pool (workers do Codex): a thread vira o slot do computador que ela reivindica com
    /// `box_claim` (o computador foi reservado para um slot do MESMO pai); sem `box_claim` antes, erro. Pai: um subagente do Codex
    /// herda o MCP do pai e não pode reservar nem liberar computadores.
    func route(_ name: String, arguments: JSON, params: JSON?, child: String) async -> Routing {
        let hub = tools.hub
        let meta = CallerMeta(params)
        switch await hub.role(of: child) {
        case .pool?:
            guard let thread = meta.threadID, meta.isSubagent, let parent = await hub.poolParent(of: child) else {
                return .failure(ComputerToolService.failure(
                    ToolError(.blockedByPolicy, "\(name) is a worker tool: only the racky-worker-N subagents spawned for a reserved computer can use it"), box: nil))
            }
            if name == "box_claim" {
                let computer = arguments["name"]?.string ?? ""
                guard let slot = await tools.orchestrator?.workerChild(ofComputer: computer, parent: parent) else {
                    return .failure(ComputerToolService.failure(
                        ToolError(.notFound, "no computer named \(computer) was reserved by your parent session; use the name from your brief"), box: nil))
                }
                await hub.bind(thread: thread, pool: child, to: slot)
            }
            guard let bound = await hub.boundChild(thread: thread, pool: child) else {
                return .failure(ComputerToolService.failure(ToolError(.notClaimed, "call box_claim first; each worker operates the computer it claimed"), box: nil))
            }
            return .child(bound)
        case .parent?:
            if meta.isSubagent {
                return .failure(ComputerToolService.failure(
                    ToolError(.blockedByPolicy, "\(name) belongs to the parent session; workers use the computer they claimed"), box: nil))
            }
            return .child(child)
        default:
            return .child(child)
        }
    }
}

/// Serviço `mcp` de `app.sock` (08 AR-106): frame 1 = identidade, frame 2 = mensagem JSON-RPC, uma resposta, e a conexão fecha.
public struct McpServiceProvider: AppSockServiceProvider {
    public let service = AppSockService.mcp
    private let server: ComputerMCPServer
    private let hub: ComputerHub

    public init(server: ComputerMCPServer, hub: ComputerHub) {
        self.server = server
        self.hub = hub
    }

    public func admit() -> CtlError? { nil }

    public func makeHandler() -> AppSockServer.Handler {
        let session = McpSession(server: server, hub: hub)
        return { frame in await session.receive(frame) }
    }
}

actor McpSession {
    private let server: ComputerMCPServer
    private let hub: ComputerHub
    private var child: String?

    init(server: ComputerMCPServer, hub: ComputerHub) {
        self.server = server
        self.hub = hub
    }

    func receive(_ frame: Data) async -> AppSockReply {
        if child == nil {
            guard let identity = try? JSONDecoder().decode(McpIdentity.self, from: frame), await hub.authorize(child: identity.child, capability: identity.capability) else {
                // JSON-RPC sem id: o helper traduz em erro de ferramenta legível.
                let denied = JSON.object(["jsonrpc": "2.0", "id": .null, "error": ["code": -32001, "message": "unauthorized: unknown child or capability"]]).data()
                return AppSockReply(frames: [denied], close: true)
            }
            child = identity.child
            return AppSockReply()
        }
        guard let child else { return AppSockReply(close: true) }
        let response = await server.handle(frame, child: child)
        return AppSockReply(frames: response.map { [$0] } ?? [], close: true)
    }
}
