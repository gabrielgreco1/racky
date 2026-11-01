import Foundation

// Fio dos hooks de atividade (06 §3.2, 08 §0.2): `racky hook` -> serviço `hook` de `app.sock`, ou spool em disco.
// Foundation pura: o helper e o app compartilham estes tipos.

public enum HookProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

/// Limites e constantes canônicos do transporte (08 §0.2, AR-707).
public enum HookLimits {
    /// Timeout de entrega ao app antes de cair no spool.
    public static let deliveryTimeoutMs = 200
    /// `timeout` dos hooks nas settings do CLI, em segundos.
    public static let cliHookTimeoutSeconds = 5
    /// Tamanho máximo de um arquivo de spool (acima disso descarta os mais antigos).
    public static let spoolFileLimitBytes = 4 * 1024 * 1024
    /// Depois de truncar, o arquivo fica com no máximo este tamanho (histerese).
    public static let spoolTruncatedKeepBytes = 3 * 1024 * 1024
    /// Maior frame aceito pelo serviço `hook`.
    public static let maxFrameBytes = 256 * 1024
    /// Maior stdin que o helper lê (o resto é descartado).
    public static let maxStdinBytes = 16 * 1024 * 1024
    /// Payload guardado em `agent_event` (08 AR-311).
    public static let maxStoredPayloadBytes = 16 * 1024
    /// Última mensagem guardada no banco (06 §3.4).
    public static let lastMessageMaxCharacters = 500
    /// Retenção de `agent_event` (08 §0.4): 30 dias e 10 mil eventos por execução.
    public static let retentionDays = 30
    public static let retentionMaxEventsPerRun = 10_000
}

/// Eventos de hook conhecidos. Nomes fora da lista são gravados e ignorados pelo redutor (compatibilidade futura).
public enum HookEventName: String, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case sessionEnd = "SessionEnd"

    /// Eventos registrados por lançamento (06 §3.3).
    public static let claudeRegistered: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest,
        .notification, .stop, .stopFailure, .subagentStart, .subagentStop, .sessionEnd,
    ]
    /// Codex 0.160 (06 §3.3): sem `Notification`/`StopFailure`.
    public static let codexRegistered: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest, .stop, .subagentStart, .subagentStop,
    ]
}

/// Campos reduzidos do payload de um hook (06 §3.3). Nunca carrega o prompt, `tool_input` completo nem `tool_response`.
public struct ReducedHookPayload: Codable, Sendable, Equatable {
    public var sessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var source: String?
    public var toolName: String?
    /// Alvo curto da ferramenta (comando, arquivo, URL), já saneado.
    public var toolTarget: String?
    public var toolUseID: String?
    public var agentID: String?
    public var agentType: String?
    public var turnID: String?
    public var model: String?
    public var lastAssistantMessage: String?
    public var reason: String?
    public var notificationType: String?
    public var message: String?
    public var error: String?
    public var mcpServer: String?

    public init(
        sessionID: String? = nil, transcriptPath: String? = nil, cwd: String? = nil, source: String? = nil,
        toolName: String? = nil, toolTarget: String? = nil, toolUseID: String? = nil, agentID: String? = nil,
        agentType: String? = nil, turnID: String? = nil, model: String? = nil, lastAssistantMessage: String? = nil,
        reason: String? = nil, notificationType: String? = nil, message: String? = nil, error: String? = nil,
        mcpServer: String? = nil
    ) {
        self.sessionID = sessionID; self.transcriptPath = transcriptPath; self.cwd = cwd; self.source = source
        self.toolName = toolName; self.toolTarget = toolTarget; self.toolUseID = toolUseID; self.agentID = agentID
        self.agentType = agentType; self.turnID = turnID; self.model = model
        self.lastAssistantMessage = lastAssistantMessage; self.reason = reason
        self.notificationType = notificationType; self.message = message; self.error = error; self.mcpServer = mcpServer
    }
}

/// Um evento entregue pelo helper. `id` é a chave de idempotência (o mesmo evento chega pelo socket e pelo spool).
public struct HookEnvelope: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var v: Int
    public var id: String
    public var provider: HookProvider
    public var event: String
    public var runID: String
    public var paneID: String?
    /// `CLOCK_REALTIME` em nanossegundos, lido quando o helper nasce. Define a ordem de ocorrência.
    public var atNs: Int64
    public var payload: ReducedHookPayload

    public init(
        v: Int = HookEnvelope.currentVersion, id: String = UUID().uuidString.lowercased(), provider: HookProvider,
        event: String, runID: String, paneID: String? = nil, atNs: Int64, payload: ReducedHookPayload
    ) {
        self.v = v; self.id = id; self.provider = provider; self.event = event; self.runID = runID
        self.paneID = paneID; self.atNs = atNs; self.payload = payload
    }

    public var knownEvent: HookEventName? { HookEventName(rawValue: event) }
}

/// Marcador gravado no spool quando os eventos mais antigos foram descartados (06 §3.2).
public struct HookSpoolMarker: Codable, Sendable, Equatable {
    public var marker: String
    public var dropped: Int
    public var atNs: Int64
    public static let truncated = "truncated"
    public init(dropped: Int, atNs: Int64) { self.marker = Self.truncated; self.dropped = dropped; self.atNs = atNs }
}

public struct HookAck: Codable, Sendable, Equatable {
    public var ok: Bool
    public var duplicate: Bool
    public var error: String?
    public init(ok: Bool, duplicate: Bool = false, error: String? = nil) {
        self.ok = ok; self.duplicate = duplicate; self.error = error
    }
}

/// Uma linha do spool: evento, marcador ou lixo (registrado como erro; o cursor avança de qualquer forma).
public enum HookSpoolLine: Sendable, Equatable {
    case event(HookEnvelope)
    case marker(HookSpoolMarker)
    case invalid(String)

    public static func parse(_ line: Data) -> HookSpoolLine {
        let decoder = JSONDecoder()
        if let marker = try? decoder.decode(HookSpoolMarker.self, from: line), marker.marker == HookSpoolMarker.truncated {
            return .marker(marker)
        }
        do {
            let envelope = try decoder.decode(HookEnvelope.self, from: line)
            guard envelope.v <= HookEnvelope.currentVersion else { return .invalid("unsupported envelope version \(envelope.v)") }
            return .event(envelope)
        } catch {
            return .invalid("not a hook envelope: \(error.localizedDescription)")
        }
    }
}

public enum HookCodec {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// JSON em uma linha (sem `\n` interno), pronto para o spool.
    public static func line(_ envelope: HookEnvelope) throws -> Data { try encoder().encode(envelope) }
}
