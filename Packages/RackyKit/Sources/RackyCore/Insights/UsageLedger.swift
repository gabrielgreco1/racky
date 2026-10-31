import Foundation

/// Estado de leitura de um arquivo (cursor + o necessário para não contar a mesma mensagem duas vezes).
public struct FileState: Codable, Sendable, Equatable {
    public struct Pending: Codable, Sendable, Equatable {
        public var id: String
        public var counts: TokenCounts
    }

    public var cursor = FileCursor()
    /// Claude: última mensagem vista (uma mensagem em streaming pode atravessar duas leituras).
    public var lastMessage: Pending?
    /// Codex: modelo e sessão do rollout, e o último total acumulado (o uso por turno é a diferença).
    public var codexModel: String?
    public var codexSession: String?
    public var codexTotals: TokenCounts?

    public init() {}
}

/// Livro-razão persistido: só agregados numéricos por hora + cursores. Nada de texto de conversa.
public struct UsageLedger: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = UsageLedger.currentVersion
    public var files: [String: FileState] = [:]
    public var buckets: [String: UsageBucket] = [:]
    /// Hashes (FNV-1a 64) de `message.id|requestId` já contados, entre arquivos (sessões retomadas copiam histórico).
    public var seen: Set<UInt64> = []
    /// Rótulo curto da sessão (último componente do `cwd`).
    public var sessionLabels: [String: String] = [:]
    public var codexLimits: CodexLimitSnapshot?

    public init() {}

    public static let maxSeen = 600_000

    // MARK: Claude

    /// Lê as linhas novas de um transcript do Claude. Devolve quantas mensagens novas foram contadas.
    @discardableResult
    public mutating func ingestClaude(path: String, cutoff: Date) -> Int {
        var state = files[path] ?? FileState()
        let fallbackSession = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var collapsed: [ClaudeUsageLine] = []
        let cursor = JSONLReader.readLines(path: path, cursor: files[path]?.cursor) { raw in
            guard let line = ClaudeTranscriptParser.parse(raw) else { return }
            // Linhas consecutivas da mesma mensagem (um bloco de conteúdo por linha) carregam o uso parcial: fica o maior.
            if let id = line.messageID, let last = collapsed.last, last.messageID == id, last.requestID == line.requestID {
                collapsed[collapsed.count - 1].counts = last.counts.merged(max: line.counts)
            } else {
                collapsed.append(line)
            }
        }
        guard let cursor else { return 0 }
        var added = 0
        for line in collapsed {
            let session = line.sessionID ?? fallbackSession
            var delta = line.counts
            var isNew = true
            if let id = line.messageID {
                let key = id + "|" + (line.requestID ?? "")
                if let last = state.lastMessage, last.id == key {
                    delta = line.counts.delta(since: last.counts)
                    isNew = false
                    state.lastMessage = .init(id: key, counts: last.counts.merged(max: line.counts))
                } else {
                    let h = Self.fnv(key)
                    if seen.contains(h) { continue }
                    seen.insert(h)
                    state.lastMessage = .init(id: key, counts: line.counts)
                }
            }
            if line.timestamp < cutoff { continue }
            if let cwd = line.cwd, sessionLabels[session] == nil {
                let name = URL(fileURLWithPath: cwd).lastPathComponent
                if !name.isEmpty { sessionLabels[session] = name }
            }
            add(.claude, session: session, model: line.model, at: line.timestamp, counts: delta, sidechain: line.isSidechain, newMessage: isNew)
            if isNew { added += 1 }
        }
        state.cursor = cursor
        files[path] = state
        return added
    }

    // MARK: Codex

    @discardableResult
    public mutating func ingestCodex(path: String, cutoff: Date) -> Int {
        var state = files[path] ?? FileState()
        let fallbackSession = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var events: [CodexRolloutEvent] = []
        let cursor = JSONLReader.readLines(path: path, cursor: files[path]?.cursor) { raw in
            events.append(contentsOf: CodexRolloutParser.parse(raw))
        }
        guard let cursor else { return 0 }
        var added = 0
        for event in events {
            switch event {
            case .sessionMeta(let id, let cwd):
                if let id { state.codexSession = id }
                if let cwd, let id = state.codexSession {
                    let name = URL(fileURLWithPath: cwd).lastPathComponent
                    if !name.isEmpty, sessionLabels[id] == nil { sessionLabels[id] = name }
                }
            case .model(let m):
                state.codexModel = m
            case .tokenTotals(let total, let at):
                let previous = state.codexTotals ?? .zero
                let delta = total.delta(since: previous)
                state.codexTotals = total.merged(max: previous)
                guard !delta.isEmpty, at >= cutoff else { continue }
                add(.codex, session: state.codexSession ?? fallbackSession, model: state.codexModel ?? "codex", at: at, counts: delta,
                    sidechain: false, newMessage: true)
                added += 1
            case .limits(let snapshot):
                if codexLimits == nil || snapshot.observedAt >= codexLimits!.observedAt { codexLimits = snapshot }
            }
        }
        state.cursor = cursor
        files[path] = state
        return added
    }

    // MARK: Comum

    mutating func add(_ provider: InsightsProvider, session: String, model: String, at date: Date, counts: TokenCounts,
                      sidechain: Bool, newMessage: Bool) {
        let hour = Int64(floor(date.timeIntervalSince1970 / 3600)) * 3600
        let key = UsageBucket.key(provider, session, model, hour)
        var bucket = buckets[key] ?? UsageBucket(provider: provider, session: session, model: model, hour: hour)
        bucket.counts += counts
        if newMessage {
            bucket.messages += 1
            if sidechain { bucket.sidechainMessages += 1 }
        }
        buckets[key] = bucket
    }

    /// Descarta o que saiu da janela de retenção e arquivos que não existem mais.
    public mutating func prune(before cutoff: Date, existingPaths: Set<String>? = nil) {
        let limit = Int64(cutoff.timeIntervalSince1970)
        buckets = buckets.filter { $0.value.hour >= limit }
        if let existingPaths { files = files.filter { existingPaths.contains($0.key) } }
        if seen.count > Self.maxSeen { seen.removeAll() }
        let live = Set(buckets.values.map(\.session))
        sessionLabels = sessionLabels.filter { live.contains($0.key) }
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}

/// Persistência do livro-razão (JSON atômico). Falhas de leitura devolvem um livro vazio (reconstrói do disco).
public enum UsageLedgerStore {
    public static func load(from url: URL) -> UsageLedger {
        guard let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(UsageLedger.self, from: data),
              ledger.version == UsageLedger.currentVersion else { return UsageLedger() }
        return ledger
    }

    public static func save(_ ledger: UsageLedger, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: .atomic)
    }
}
