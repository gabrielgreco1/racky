import Foundation

// O que passa pela rede de um computador e o que roda no terminal dele, lido do run folder (`logs/requests.jsonl`, que só o egress
// e o navegador escrevem, e `logs/commands.jsonl`). A leitura é incremental: cada `poll()` lê só o que foi acrescentado desde a
// anterior, então a aba Computers e a tela Traffic acompanham ao vivo sem reler arquivos de megabytes.

/// O que uma request é, para o ícone da linha e as contas: página, API (onde costumam estar os dados), asset, analytics,
/// anti-bot (WAF, desafio, captcha), túnel TLS, bloqueada pelo egress ou outra coisa.
public enum TrafficCategory: String, Sendable, CaseIterable {
    case page, api, asset, analytics, antibot, tunnel, blocked, other

    static let analyticsMarks = [
        "analytics", "tagmanager", "doubleclick", "facebook.", "segment.", "mixpanel", "hotjar", "amplitude", "sentry", "datadog", "newrelic",
        "optimizely", "clarity.ms", "cookielaw", "onetrust", "otel", "sink.", "c360.", "bat.bing", "tiktok", "/collect", "/beacon", "/track",
    ]
    static let antibotMarks = [
        "awswaf", "datadome", "perimeterx", "px-cdn", "px-cloud", "captcha", "/cdn-cgi/challenge", "challenges.cloudflare", "akamai", "kasada",
        "imperva", "incapsula", "_abck", "/__challenge",
    ]
}

/// Uma request do computador (uma linha de `requests.jsonl`).
public struct TrafficEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var at: Date
    public var method: String
    public var host: String
    public var url: String
    /// Caminho e query (`/dml/graphql?ss=Lisbon`); num túnel, `host:porta`.
    public var path: String
    public var status: Int?
    /// `document`, `fetch`, `xhr`, `script`, `stylesheet`, `image`, `ping`, `tunnel`, `other`.
    public var type: String
    public var contentType: String?
    /// `browser` (o Chrome do computador) ou `egress` (o proxy de saída: comandos, scripts, túneis).
    public var source: String
    /// Por onde saiu: `direct` ou o nome do proxy.
    public var via: String
    public var bytes: Int64?
    public var durationMs: Int?
    public var blocked: Bool
    public var blockedReason: String?
    public var error: String?
    public var requestHeaders: [[String]]
    public var responseHeaders: [[String]]
    /// `bodies/<id>.request.txt` e `bodies/<id>.response.txt`, relativos a `logs/`.
    public var requestBodyFile: String?
    public var responseBodyFile: String?

    /// Página, API, asset, analytics, anti-bot, túnel, bloqueada ou outra (pelo host, a URL e o tipo de recurso).
    public var category: TrafficCategory {
        if blocked { return .blocked }
        let where_ = (host + " " + url).lowercased()
        if TrafficCategory.antibotMarks.contains(where: { where_.contains($0) }) { return .antibot }
        if TrafficCategory.analyticsMarks.contains(where: { where_.contains($0) }) { return .analytics }
        switch type {
        case "tunnel": return .tunnel
        case "document": return .page
        case "fetch", "xhr": return .api
        case "script", "stylesheet", "image", "font", "media": return .asset
        default: return .other
        }
    }

    /// Falhou (status ≥ 400, erro de rede) sem ter sido bloqueada de propósito.
    public var isError: Bool { !blocked && (error?.isEmpty == false || (status ?? 0) >= 400) }
    /// Fetch/XHR: o que costuma ter os dados (APIs, GraphQL).
    public var isAPI: Bool { type == "fetch" || type == "xhr" }

    init?(_ record: [String: JSON]) {
        guard let id = record["id"]?.string, let ts = record["ts"]?.double else { return nil }
        self.id = id
        at = Date(timeIntervalSince1970: ts)
        method = record["method"]?.string ?? "GET"
        host = record["host"]?.string ?? ""
        url = record["url"]?.string ?? ""
        if record["kind"]?.string == "tunnel" {
            path = url
            type = "tunnel"
        } else {
            let parts = URLComponents(string: url)
            let query = parts?.percentEncodedQuery.map { "?\($0)" } ?? ""
            path = ((parts?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/") + query
            type = record["type"]?.string ?? "other"
        }
        status = record["status"]?.int
        contentType = record["content_type"]?.string
        source = record["source"]?.string ?? "egress"
        via = record["via"]?.string ?? "direct"
        bytes = (record["response_body_bytes"]?.int ?? record["bytes_down"]?.int).map(Int64.init)
        durationMs = record["duration_ms"]?.int
        blocked = record["blocked"]?.bool == true
        blockedReason = record["blocked_reason"]?.string
        error = record["error"]?.string
        func headers(_ key: String) -> [[String]] {
            (record[key]?.array ?? []).compactMap { pair in pair.array?.compactMap(\.string) }.filter { $0.count == 2 }
        }
        requestHeaders = headers("request_headers")
        responseHeaders = headers("response_headers")
        requestBodyFile = record["request_body_file"]?.string
        responseBodyFile = record["response_body_file"]?.string
    }

    public init(
        id: String, at: Date, method: String = "GET", host: String, path: String = "/", status: Int? = 200, type: String = "fetch",
        source: String = "browser", via: String = "direct", bytes: Int64? = nil, durationMs: Int? = nil, blocked: Bool = false, error: String? = nil
    ) {
        self.id = id; self.at = at; self.method = method; self.host = host; self.url = "https://\(host)\(path)"; self.path = path
        self.status = status; self.type = type; self.contentType = nil; self.source = source; self.via = via; self.bytes = bytes
        self.durationMs = durationMs; self.blocked = blocked; self.blockedReason = blocked ? "noise" : nil; self.error = error
        self.requestHeaders = []; self.responseHeaders = []; self.requestBodyFile = nil; self.responseBodyFile = nil
    }
}

/// Um comando que o agente rodou no terminal do computador (uma linha de `commands.jsonl`).
public struct ActivityEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var at: Date
    public var shell: String
    public var cwd: String?
    public var exit: Int?
    public var durationMs: Int?
    public var outputBytes: Int?

    init?(_ record: [String: JSON]) {
        guard let ts = record["ts"]?.double, let shell = record["shell"]?.string else { return nil }
        id = record["log_id"]?.string ?? String(record["n"]?.int ?? Int(ts * 1000))
        at = Date(timeIntervalSince1970: ts)
        self.shell = shell
        cwd = record["cwd"]?.string
        exit = record["exit"]?.int
        durationMs = record["ms"]?.int
        outputBytes = record["output_bytes"]?.int
    }
}

/// Uso de um proxy (ou da saída direta) por um computador.
public struct TrafficVia: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var requests: Int
    public var bytes: Int64
}

/// Números do tráfego de um computador.
public struct TrafficStats: Sendable, Equatable {
    public var total = 0
    public var api = 0
    public var documents = 0
    public var errors = 0
    public var blocked = 0
    public var bytes: Int64 = 0
    /// Requests por minuto nos últimos `minutes` minutos (o último é o minuto atual).
    public var perMinute: [Int] = []
    /// Requests nos últimos 5 minutos.
    public var recent = 0
    public var hosts: [(host: String, count: Int)] = []
    /// Categoria que mais aparece em cada host (o ícone da lista "Talked to").
    public var hostCategory: [String: TrafficCategory] = [:]
    /// Quantas de cada tipo e quantos bytes por host (a barra dividida e o tamanho da lista "Talked to").
    public var hostKinds: [String: [TrafficCategory: Int]] = [:]
    public var hostBytes: [String: Int64] = [:]
    /// Hosts com tráfego de verdade (nem tudo bloqueado), do que mais falou para o que menos.
    public var activeHosts: [(host: String, count: Int)] = []
    /// Por saída (direto ou proxy): quantas responderam OK.
    public var viaOK: [String: Int] = [:]
    public var categories: [TrafficCategory: Int] = [:]
    /// Linha do tempo do run em `bins` faixas iguais, cada uma com [dados (API e páginas), assets, ruído (analytics e anti-bot), resto].
    public var timeline: [[Int]] = []
    public var vias: [TrafficVia] = []
    public var first: Date?
    public var last: Date?

    public init() {}

    public static func == (a: TrafficStats, b: TrafficStats) -> Bool {
        a.total == b.total && a.timeline == b.timeline && a.errors == b.errors && a.blocked == b.blocked && a.bytes == b.bytes && a.perMinute == b.perMinute
            && a.recent == b.recent && a.vias == b.vias && a.hosts.map(\.host) == b.hosts.map(\.host) && a.hosts.map(\.count) == b.hosts.map(\.count)
    }

    /// Ritmo atual: a média dos últimos 3 minutos com tráfego.
    public var perMinuteNow: Double {
        let tail = perMinute.suffix(3)
        return tail.isEmpty ? 0 : Double(tail.reduce(0, +)) / Double(tail.count)
    }

    public var errorRate: Double { total == 0 ? 0 : Double(errors) / Double(total) }

    public static func compute(_ entries: [TrafficEntry], now: Date = Date(), minutes: Int = 30, bins: Int = 36) -> TrafficStats {
        var s = TrafficStats()
        s.total = entries.count
        var perHost: [String: [TrafficCategory: Int]] = [:]
        let start = entries.first?.at ?? now
        let span = max((entries.last?.at ?? now).timeIntervalSince(start), 1)
        var lanes = Array(repeating: [0, 0, 0, 0], count: bins)
        var hosts: [String: Int] = [:]
        var vias: [String: TrafficVia] = [:]
        var buckets = Array(repeating: 0, count: minutes)
        for e in entries {
            let category = e.category
            s.categories[category, default: 0] += 1
            perHost[e.host, default: [:]][category, default: 0] += 1
            s.hostBytes[e.host, default: 0] += e.bytes ?? 0
            if !e.blocked, !e.isError { s.viaOK[e.via, default: 0] += 1 }
            if category != .blocked {
                let bin = min(bins - 1, Int(e.at.timeIntervalSince(start) / span * Double(bins)))
                let lane = switch category {
                case .api, .page: 0
                case .asset: 1
                case .analytics, .antibot: 2
                default: 3
                }
                if bin >= 0 { lanes[bin][lane] += 1 }
            }
            if e.isAPI { s.api += 1 }
            if e.type == "document" { s.documents += 1 }
            if e.blocked { s.blocked += 1 } else if e.isError { s.errors += 1 }
            s.bytes += e.bytes ?? 0
            hosts[e.host, default: 0] += 1
            if !e.blocked {
                var v = vias[e.via] ?? TrafficVia(name: e.via, requests: 0, bytes: 0)
                v.requests += 1
                v.bytes += e.bytes ?? 0
                vias[e.via] = v
            }
            let age = Int(now.timeIntervalSince(e.at) / 60)
            if age >= 0, age < minutes { buckets[minutes - 1 - age] += 1 }
            if now.timeIntervalSince(e.at) <= 300 { s.recent += 1 }
            s.first = min(s.first ?? e.at, e.at)
            s.last = max(s.last ?? e.at, e.at)
        }
        s.perMinute = buckets
        s.timeline = lanes
        s.hostCategory = perHost.compactMapValues { $0.max { $0.value < $1.value }?.key }
        s.hostKinds = perHost
        s.activeHosts = perHost.compactMap { host, kinds -> (String, Int)? in
            let live = kinds.filter { $0.key != .blocked }.values.reduce(0, +)
            return live > 0 ? (host, live) : nil
        }
        .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        .map { (host: $0.0, count: $0.1) }
        s.hosts = hosts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
        s.vias = vias.values.sorted { $0.requests > $1.requests }
        return s
    }

    /// Custo aproximado de um proxy: requests × preço por request (micro-dólares). `nil` sem preço.
    public static func cost(_ via: TrafficVia, pricePerRequestMicros: Int64?) -> Double? {
        pricePerRequestMicros.map { Double($0) * Double(via.requests) / 1_000_000 }
    }
}

/// Lê `requests.jsonl` e `commands.jsonl` de um run aos poucos.
// SAFETY: usado de uma task por vez (o `TrafficController` serializa os `poll()` de cada computador).
public final class TrafficLog: @unchecked Sendable {
    public let logs: URL
    public private(set) var entries: [TrafficEntry] = []
    public private(set) var activity: [ActivityEntry] = []
    private var requestsOffset: UInt64 = 0
    private var commandsOffset: UInt64 = 0
    /// Guarda no máximo isto (as mais novas); o arquivo continua inteiro no disco.
    public let limit: Int

    public init(logs: URL, limit: Int = 20_000) {
        self.logs = logs
        self.limit = limit
    }

    /// Lê o que foi acrescentado. Devolve quantas requests novas chegaram.
    @discardableResult
    public func poll() -> Int {
        let fresh = Self.readLines(logs.appendingPathComponent("requests.jsonl"), from: &requestsOffset).compactMap(TrafficEntry.init)
        entries.append(contentsOf: fresh)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        activity.append(contentsOf: Self.readLines(logs.appendingPathComponent("commands.jsonl"), from: &commandsOffset).compactMap(ActivityEntry.init))
        return fresh.count
    }

    /// Corpo salvo de uma request (`kind` = `request` ou `response`), confinado a `logs/bodies/`.
    public func body(_ entry: TrafficEntry, kind: String, max: Int = 1_048_576) -> Data? {
        guard let relative = kind == "request" ? entry.requestBodyFile : entry.responseBodyFile, relative.hasPrefix("bodies/"), !relative.contains("..")
        else { return nil }
        let file = logs.appendingPathComponent(relative)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: max)
    }

    /// Linhas JSON completas a partir de `offset` (uma linha ainda sendo escrita fica para o próximo `poll`).
    static func readLines(_ file: URL, from offset: inout UInt64) -> [[String: JSON]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return complete.split(separator: 0x0A).compactMap { line in
            (try? JSONDecoder().decode(JSON.self, from: Data(line)))?.object
        }
    }
}

extension TrafficEntry {
    /// `curl` equivalente (cabeçalhos sensíveis viram `<redacted>`; o corpo vai inteiro quando cabe).
    public func curl(body: Data?) -> String {
        let sensitive: Set<String> = ["cookie", "authorization", "proxy-authorization", "x-api-key"]
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl", "-X", method, quote(url)]
        for header in requestHeaders where header.count == 2 && !header[0].hasPrefix(":") {
            let value = sensitive.contains(header[0].lowercased()) ? "<redacted>" : header[1]
            parts += ["-H", quote("\(header[0]): \(value)")]
        }
        if let body, let text = String(data: body, encoding: .utf8), !text.isEmpty { parts += ["--data-raw", quote(text)] }
        return parts.joined(separator: " ")
    }
}
