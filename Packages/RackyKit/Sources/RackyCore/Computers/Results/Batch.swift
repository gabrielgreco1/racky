import Foundation

// T3-07, 07 CS-323/326, 03 §12.4: o lote (`batch`) como entidade derivada. Um lote é o conjunto de computadores reservados com o mesmo
// rótulo `batch` por um pai; o app não guarda uma tabela própria, ele agrega o que já existe (entradas vivas do scheduler e, para
// quem já terminou, `box.json` + `result.json` no run folder). Tipos puros: agregação, conclusão, exportação e texto da notificação.

/// Estado de um filho do lote como o painel mostra (03 §12.4: filtros `Needs You`, `Blocked`, `Done`).
public enum BatchChildStatus: String, Sendable, Codable, CaseIterable, Equatable {
    case queued, running
    case needsYou = "needs_you"
    case blocked, done, failed, stopped

    /// `done`, `failed` e `stopped` (inclui `interrupted`) encerram o filho (CS-326).
    public var isTerminal: Bool { self == .done || self == .failed || self == .stopped }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .needsYou: "Needs You"
        case .blocked: "Blocked"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

public struct BatchChild: Sendable, Equatable, Identifiable {
    /// O nome do computador (o alvo do lote, p. ex. `phoenix-az`).
    public var name: String
    public var id: String { name }
    public var childID: String?
    public var status: BatchChildStatus
    public var computerState: BoxState?
    public var verified: Int
    public var citedMissing: Int
    public var notVerified: Int
    public var proxy: String
    public var proxyRequests: Int?
    public var durationSeconds: Int?
    public var lastDoing: String?
    public var runPath: String
    /// `result.json` do filho; só preenchido ao coletar ou exportar (o polling do painel não lê resultados).
    public var result: JSON?

    public init(
        name: String, childID: String? = nil, status: BatchChildStatus, computerState: BoxState? = nil, verified: Int = 0, citedMissing: Int = 0,
        notVerified: Int = 0, proxy: String = "direct", proxyRequests: Int? = nil, durationSeconds: Int? = nil, lastDoing: String? = nil,
        runPath: String = "", result: JSON? = nil
    ) {
        self.name = name; self.childID = childID; self.status = status; self.computerState = computerState; self.verified = verified
        self.citedMissing = citedMissing; self.notVerified = notVerified; self.proxy = proxy; self.proxyRequests = proxyRequests
        self.durationSeconds = durationSeconds; self.lastDoing = lastDoing; self.runPath = runPath; self.result = result
    }

    public var totalFields: Int { verified + citedMissing + notVerified }
    /// `3/5` (03 §12.4); `-` quando o filho ainda não entregou resultado.
    public var verifiedText: String { totalFields == 0 ? "-" : "\(verified)/\(totalFields)" }
}

public struct BatchSummary: Sendable, Equatable, Identifiable {
    /// O nome do lote é o id (`batch_id` da resposta de `boxes_reserve`).
    public var id: String { name }
    public var name: String
    public var sessionID: UUID?
    public var sessionTitle: String?
    /// Identidade do pai que criou os filhos (a mais recente, quando a sessão foi retomada).
    public var parent: String?
    public var children: [BatchChild]
    public var createdAt: Date?

    public init(name: String, sessionID: UUID? = nil, sessionTitle: String? = nil, parent: String? = nil, children: [BatchChild], createdAt: Date? = nil) {
        self.name = name; self.sessionID = sessionID; self.sessionTitle = sessionTitle; self.parent = parent; self.children = children; self.createdAt = createdAt
    }

    // MARK: Contagens

    public var total: Int { children.count }
    public func count(_ status: BatchChildStatus) -> Int { children.filter { $0.status == status }.count }
    public var done: Int { count(.done) }
    public var failed: Int { count(.failed) }
    public var stopped: Int { count(.stopped) }
    public var needsYou: Int { count(.needsYou) }
    public var blocked: Int { count(.blocked) }
    public var running: Int { count(.running) + count(.queued) + needsYou + blocked }
    /// Filhos que já terminaram (`done`, `failed`, `stopped`): o `N` de `N of M`.
    public var finishedCount: Int { children.filter { $0.status.isTerminal }.count }
    public var verifiedFields: Int { children.reduce(0) { $0 + $1.verified } }
    public var totalFields: Int { children.reduce(0) { $0 + $1.totalFields } }
    /// `nil` quando nenhum filho informou uso (sem proxy ou sem backend).
    public var proxyRequests: Int? {
        let known = children.compactMap(\.proxyRequests)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
    /// Relógio da parede: o filho mais longo (os filhos rodam em paralelo).
    public var durationSeconds: Int? { children.compactMap(\.durationSeconds).max() }

    /// CS-326: todos os filhos em estado terminal, e há filhos. Pedidos de ajuda abertos seguram o lote (`needsYou` não é terminal).
    public var isFinished: Bool { !children.isEmpty && children.allSatisfy { $0.status.isTerminal } }

    // MARK: Textos

    /// `12 of 15 done · 212 proxy requests · 18 min` (03 §12.4).
    public var headline: String {
        var parts = ["\(finishedCount) of \(total) done"]
        if let requests = proxyRequests, requests > 0 { parts.append("\(requests) proxy requests") }
        if let seconds = durationSeconds { parts.append(RunCollector.duration(seconds)) }
        return parts.joined(separator: " · ")
    }

    /// `"<session> — <batch> finished"` (CS-326).
    public var notificationTitle: String { sessionTitle.map { "\($0) — \(name) finished" } ?? "\(name) finished" }

    /// `"5 done · 1 failed · 18 verified fields · 18 min · 212 proxy requests"`; sem conteúdo de página (CS-326). Termina com
    /// `· <n> need you` se ainda houver pedido aberto.
    public var notificationBody: String {
        var parts = ["\(done) done", "\(failed + stopped) failed", "\(verifiedFields) verified fields"]
        if let seconds = durationSeconds { parts.append(RunCollector.duration(seconds)) }
        if let requests = proxyRequests, requests > 0 { parts.append("\(requests) proxy requests") }
        if needsYou > 0 { parts.append("\(needsYou) need you") }
        return parts.joined(separator: " · ")
    }

    // MARK: Filtros (03 §12.4)

    public enum Filter: String, Sendable, CaseIterable, Equatable {
        case all = "All", needsYou = "Needs You", blocked = "Blocked", done = "Done"

        public func matches(_ child: BatchChild) -> Bool {
            switch self {
            case .all: true
            case .needsYou: child.status == .needsYou
            case .blocked: child.status == .blocked
            case .done: child.status == .done
            }
        }
    }

    public func children(matching filter: Filter) -> [BatchChild] { children.filter(filter.matches) }

    // MARK: Consolidado

    /// Colunas do consolidado: os campos de topo dos `result.json`, na ordem de aparição.
    public var resultColumns: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for child in children {
            for key in (child.result?.object ?? [:]).keys.sorted() where seen.insert(key).inserted { out.append(key) }
        }
        return out
    }

    // MARK: Exportação

    static func csvCell(_ text: String) -> String { CSVFormat.cell(text) }

    public static func flat(_ value: JSON?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .null: return ""
        default: return value.text
        }
    }

    /// CSV do consolidado: uma linha por alvo, colunas fixas e depois os campos do resultado. Células com `,`, `"` ou quebra de
    /// linha vão entre aspas (RFC 4180). Células que começam com `=`, `+`, `-` ou `@` ganham `'` na frente (injeção de fórmula em
    /// planilha: o texto veio de uma página da web).
    public func csv() -> String {
        let columns = resultColumns
        let header = ["target", "status", "verified", "cited_missing", "not_verified", "proxy_requests", "duration_s"] + columns
        var rows = [header.map(Self.csvCell).joined(separator: ",")]
        for child in children {
            var cells = [
                child.name, child.status.rawValue, "\(child.verified)", "\(child.citedMissing)", "\(child.notVerified)",
                child.proxyRequests.map(String.init) ?? "", child.durationSeconds.map(String.init) ?? "",
            ]
            for column in columns { cells.append(Self.safeCell(Self.flat(child.result?[column]))) }
            rows.append(cells.map(Self.csvCell).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    static func safeCell(_ text: String) -> String { CSVFormat.safe(text) }

    func childJSON(_ child: BatchChild) -> JSON {
        var o: [String: JSON] = [
            "name": .string(child.name), "status": .string(child.status.rawValue),
            "verified": .int(child.verified), "cited_missing": .int(child.citedMissing), "not_verified": .int(child.notVerified),
            "total_fields": .int(child.totalFields), "proxy": .string(child.proxy), "run": .string(child.runPath),
        ]
        if let childID = child.childID { o["child_id"] = .string(childID) }
        if let requests = child.proxyRequests { o["proxy_requests"] = .int(requests) }
        if let seconds = child.durationSeconds { o["duration_s"] = .int(seconds) }
        if let result = child.result { o["result"] = result }
        return .object(o)
    }

    /// JSON do consolidado: `{batch, finished, counts, children: [...]}`.
    public func json() -> JSON {
        [
            "batch": .string(name), "finished": .bool(isFinished),
            "counts": [
                "total": .int(total), "done": .int(done), "failed": .int(failed), "stopped": .int(stopped), "running": .int(running),
                "needs_you": .int(needsYou), "blocked": .int(blocked), "verified_fields": .int(verifiedFields), "total_fields": .int(totalFields),
            ],
            "children": .array(children.map(childJSON)),
        ]
    }

    /// `results.jsonl` (07 §4.2 `batch_collect`): um objeto por linha.
    public func resultsJSONL() -> Data {
        children.reduce(into: Data()) { out, child in
            out.append(childJSON(child).data())
            out.append(0x0A)
        }
    }

    /// `batch_status` do pai (07 §4.2).
    public var statusJSON: JSON {
        var o: [String: JSON] = [
            "batch": .string(name), "done": .int(done), "running": .int(running), "blocked": .int(blocked), "needs_you": .int(needsYou),
            "failed": .int(failed + stopped), "finished": .bool(isFinished),
            "children": .array(children.map { child in
                var c: [String: JSON] = [
                    "name": .string(child.name), "activity": .string(child.status.rawValue), "verified": .int(child.verified),
                    "total_fields": .int(child.totalFields),
                ]
                if let childID = child.childID { c["child_id"] = .string(childID) }
                if let state = child.computerState { c["box_state"] = .string(state.rawValue) }
                if let seconds = child.durationSeconds { c["duration_s"] = .int(seconds) }
                if let requests = child.proxyRequests { c["usage"] = ["requests": .int(requests)] }
                return .object(c)
            }),
        ]
        if let requests = proxyRequests { o["usage"] = ["requests": .int(requests)] }
        return .object(o)
    }
}

/// Detecção de "lote concluído" (CS-326, AC-429): **uma** vez por lote, mesmo que o painel seja aberto de novo ou o pai chame
/// `batch_collect` outra vez. Valor puro: o chamador alimenta com o estado atual e guarda o que já foi notificado.
public struct BatchCompletionTracker: Sendable, Equatable {
    public private(set) var notified: Set<String> = []

    public init(notified: Set<String> = []) { self.notified = notified }

    /// `true` na primeira vez que `summary` aparece concluído. Lote ainda em andamento (ou com pedido aberto) volta `false` e pode
    /// concluir depois; um lote que reabre (novo filho) e conclui de novo não repete: o `key` já foi notificado.
    public mutating func observe(_ summary: BatchSummary, key: String) -> Bool {
        guard summary.isFinished, !notified.contains(key) else { return false }
        notified.insert(key)
        return true
    }

    public func hasNotified(_ key: String) -> Bool { notified.contains(key) }
}

/// Marcas por lote no disco (`runs/<sessão>/_batches/<lote>/`): a notificação feita e o consolidado coletado.
public enum BatchLedger {
    public static func folder(session: URL, batch: String) -> URL {
        session.appendingPathComponent(RunArchive.batchesFolderName, isDirectory: true).appendingPathComponent(safe(batch), isDirectory: true)
    }

    /// Nome do lote como nome de pasta (o lote vem do agente: nada de `/` ou `..`).
    static func safe(_ batch: String) -> String {
        let cleaned = batch.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "_" }
        let text = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return text.isEmpty ? "batch" : String(text.prefix(100))
    }

    public static func notifiedMarker(session: URL, batch: String) -> URL { folder(session: session, batch: batch).appendingPathComponent("notified.json") }
    public static func resultsFile(session: URL, batch: String) -> URL { folder(session: session, batch: batch).appendingPathComponent("results.jsonl") }

    public static func wasNotified(session: URL, batch: String) -> Bool {
        FileManager.default.fileExists(atPath: notifiedMarker(session: session, batch: batch).path)
    }

    public static func markNotified(session: URL, batch: String, summary: BatchSummary, at date: Date = Date()) {
        let dir = folder(session: session, batch: batch)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker: JSON = ["batch": .string(batch), "at": .string(ISO8601DateFormatter().string(from: date)), "body": .string(summary.notificationBody)]
        try? marker.data(pretty: true).write(to: notifiedMarker(session: session, batch: batch), options: .atomic)
    }
}
