import Foundation

/// Uma mensagem do assistente com seu `usage` (uma linha de `~/.claude/projects/**/*.jsonl`).
public struct ClaudeUsageLine: Sendable, Equatable {
    public var messageID: String?
    public var requestID: String?
    public var sessionID: String?
    public var model: String
    public var timestamp: Date
    public var counts: TokenCounts
    public var isSidechain: Bool
    /// Pasta de trabalho (só o último componente é guardado depois, como rótulo da sessão).
    public var cwd: String?
}

public enum ClaudeTranscriptParser {
    /// Só lê os campos numéricos e de identificação: nunca toca em `content`. Linha corrompida ou sem usage → `nil`.
    public static func parse(_ line: UnsafeRawBufferPointer) -> ClaudeUsageLine? {
        guard JSONLReader.contains("\"usage\"", in: line), JSONLReader.contains("\"assistant\"", in: line),
              let obj = JSONLReader.object(line) else { return nil }
        return parse(object: obj)
    }

    public static func parse(_ data: Data) -> ClaudeUsageLine? {
        data.withUnsafeBytes { parse($0) }
    }

    static func parse(object obj: [String: Any]) -> ClaudeUsageLine? {
        guard (obj["type"] as? String) == "assistant", let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<"),
              let ts = (obj["timestamp"] as? String).flatMap(ISOTimestamp.parse) else { return nil }
        func int(_ d: [String: Any], _ k: String) -> Int {
            if let n = d[k] as? NSNumber { return max(0, n.intValue) }
            return 0
        }
        var counts = TokenCounts(input: int(usage, "input_tokens"), output: int(usage, "output_tokens"),
                                 cacheRead: int(usage, "cache_read_input_tokens"))
        let creation = int(usage, "cache_creation_input_tokens")
        if let detail = usage["cache_creation"] as? [String: Any], detail["ephemeral_5m_input_tokens"] != nil || detail["ephemeral_1h_input_tokens"] != nil {
            counts.cacheWrite5m = int(detail, "ephemeral_5m_input_tokens")
            counts.cacheWrite1h = int(detail, "ephemeral_1h_input_tokens")
        } else {
            counts.cacheWrite5m = creation
        }
        if counts.isEmpty { return nil }
        return ClaudeUsageLine(
            messageID: message["id"] as? String, requestID: obj["requestId"] as? String, sessionID: obj["sessionId"] as? String,
            model: model, timestamp: ts, counts: counts, isSidechain: (obj["isSidechain"] as? Bool) ?? false,
            cwd: obj["cwd"] as? String)
    }
}

/// Janela de limite reportada pelo Codex (`rate_limits.primary|secondary`).
public struct CodexLimitWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent; self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
    }
}

public struct CodexLimitSnapshot: Codable, Sendable, Equatable {
    public var observedAt: Date
    public var primary: CodexLimitWindow?
    public var secondary: CodexLimitWindow?
    public var planType: String?

    public init(observedAt: Date, primary: CodexLimitWindow?, secondary: CodexLimitWindow?, planType: String?) {
        self.observedAt = observedAt; self.primary = primary; self.secondary = secondary; self.planType = planType
    }
}

/// Eventos relevantes de uma linha de rollout do Codex.
public enum CodexRolloutEvent: Sendable, Equatable {
    case sessionMeta(id: String?, cwd: String?)
    case model(String)
    /// `total_token_usage` acumulado da sessão (cresce monotonicamente).
    case tokenTotals(TokenCounts, at: Date)
    case limits(CodexLimitSnapshot)
}

public enum CodexRolloutParser {
    public static func parse(_ line: UnsafeRawBufferPointer) -> [CodexRolloutEvent] {
        let wantsMeta = JSONLReader.contains("\"session_meta\"", in: line)
        let wantsModel = JSONLReader.contains("\"turn_context\"", in: line)
        let wantsTokens = JSONLReader.contains("\"token_count\"", in: line)
        guard wantsMeta || wantsModel || wantsTokens, let obj = JSONLReader.object(line) else { return [] }
        return parse(object: obj)
    }

    public static func parse(_ data: Data) -> [CodexRolloutEvent] {
        data.withUnsafeBytes { parse($0) }
    }

    static func parse(object obj: [String: Any]) -> [CodexRolloutEvent] {
        guard let type = obj["type"] as? String, let payload = obj["payload"] as? [String: Any] else { return [] }
        let ts = (obj["timestamp"] as? String).flatMap(ISOTimestamp.parse)
        switch type {
        case "session_meta":
            return [.sessionMeta(id: payload["id"] as? String, cwd: payload["cwd"] as? String)]
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { return [.model(model)] }
            return []
        case "event_msg":
            guard (payload["type"] as? String) == "token_count", let ts else { return [] }
            var out: [CodexRolloutEvent] = []
            if let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
                func int(_ k: String) -> Int { max(0, (total[k] as? NSNumber)?.intValue ?? 0) }
                let cached = int("cached_input_tokens")
                // No Codex `input_tokens` já inclui o que veio de cache; separa para o custo não contar duas vezes.
                let counts = TokenCounts(input: max(0, int("input_tokens") - cached), output: int("output_tokens"), cacheRead: cached)
                if !counts.isEmpty { out.append(.tokenTotals(counts, at: ts)) }
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                let primary = window(limits["primary"], observedAt: ts)
                let secondary = window(limits["secondary"], observedAt: ts)
                if primary != nil || secondary != nil {
                    out.append(.limits(CodexLimitSnapshot(observedAt: ts, primary: primary, secondary: secondary,
                                                          planType: limits["plan_type"] as? String)))
                }
            }
            return out
        default:
            return []
        }
    }

    /// `resets_at` (epoch ou ISO) ou, em versões antigas do Codex, `resets_in_seconds` relativo ao momento da leitura.
    private static func window(_ any: Any?, observedAt: Date) -> CodexLimitWindow? {
        guard let d = any as? [String: Any], let used = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        var resets: Date?
        if let at = (d["resets_at"] as? NSNumber)?.doubleValue {
            resets = Date(timeIntervalSince1970: at)
        } else if let at = d["resets_at"] as? String {
            resets = ISOTimestamp.parse(at)
        } else if let secs = (d["resets_in_seconds"] as? NSNumber)?.doubleValue {
            resets = observedAt.addingTimeInterval(secs)
        }
        return CodexLimitWindow(usedPercent: used, windowMinutes: (d["window_minutes"] as? NSNumber)?.intValue
                                ?? (d["window_duration_mins"] as? NSNumber)?.intValue, resetsAt: resets)
    }
}
