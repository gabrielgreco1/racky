import CryptoKit
import Foundation

public enum EgressAdminError: Error, Sendable, Equatable {
    case unauthorized
    case http(status: Int, body: String)
    case malformed(String)
    case notHealthy(String)
}

/// Um registro do reqlog (campos que o app usa; o resto fica em `raw`). O egress é quem escreve.
public struct ReqlogRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var raw: [String: JSONAny]

    public var kind: String? { raw["kind"]?.string }
    public var method: String? { raw["method"]?.string }
    public var url: String? { raw["url"]?.string }
    public var host: String? { raw["host"]?.string }
    public var via: String? { raw["via"]?.string }
    public var status: Int? { raw["status"]?.int }
    public var blocked: Bool { raw["blocked"]?.bool ?? false }
    public var blockedReason: String? { raw["blocked_reason"]?.string }
    public var error: String? { raw["error"]?.string }
    public var upstreamStatus: Int? { raw["upstream_status"]?.int }
    public var bytesUp: Int { raw["bytes_up"]?.int ?? 0 }
    public var bytesDown: Int { raw["bytes_down"]?.int ?? 0 }
    public var responseBodyFile: String? { raw["response_body_file"]?.string }
}

/// JSON dinâmico mínimo, só para ler registros do reqlog sem `Any`.
public enum JSONAny: Sendable, Equatable, Decodable {
    case string(String), int(Int), double(Double), bool(Bool), array([JSONAny]), object([String: JSONAny]), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONAny].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONAny].self)) }
    }

    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var int: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): Int(v)
        default: nil
        }
    }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var array: [JSONAny]? { if case .array(let v) = self { v } else { nil } }
    public var object: [String: JSONAny]? { if case .object(let v) = self { v } else { nil } }
}

public struct EgressUsage: Sendable, Equatable {
    public var via: String
    public var requests: Int
    public var tunnels: Int
    public var bytesUp: Int
    public var bytesDown: Int
    public var blocked: Int
    public var errors: Int
    public var renders: Int
    public var openTunnels: Int
    public var reqlogRecords: Int
    /// Por proxy (`via`): requests, tunnels, bytes, blocked, errors, renders.
    public var byVia: [String: [String: Int]]
}

/// Cliente da admin API do egress, publicada em `127.0.0.1:<porta efêmera>` (07 CS-111). Autentica com o token do computador.
public struct EgressAdminClient: Sendable {
    public let port: Int
    private let token: String
    private let session: URLSession

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.connectionProxyDictionary = [:]  // nunca por proxy do sistema: é loopback
        self.session = URLSession(configuration: configuration)
    }

    /// Cabeçalho do `GET /v1/tcp?port=<n>` (túnel para um serviço do computador), com o token. Só o app o monta; nunca vai a log.
    public func tunnelRequest(port: Int) -> Data {
        Data(("GET /v1/tcp?port=\(port) HTTP/1.1\r\nHost: racky-admin\r\nAuthorization: Bearer \(token)\r\n"
            + "Upgrade: racky-tcp\r\nConnection: Upgrade\r\n\r\n").utf8)
    }

    private func request(_ method: String, _ path: String, authorized: Bool = true, body: Data? = nil,
                         timeout: TimeInterval = 10) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw EgressAdminError.malformed(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EgressAdminError.malformed("sem HTTP") }
        return (http.statusCode, data)
    }

    private func ok(_ result: (status: Int, body: Data)) throws -> Data {
        if result.status == 401 { throw EgressAdminError.unauthorized }
        guard result.status == 200 else { throw EgressAdminError.http(status: result.status, body: String(decoding: result.body, as: UTF8.self)) }
        return result.body
    }

    public func health() async throws -> Bool {
        let result = try await request("GET", "/v1/health", authorized: false)
        return result.status == 200
    }

    /// Espera o egress responder (a publicação da porta pode atrasar 1 a 3 s no Colima).
    public func waitUntilHealthy(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        var last = "sem resposta"
        while ContinuousClock.now < deadline {
            do {
                if try await health() { return }
            } catch {
                last = "\(error)"
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw EgressAdminError.notHealthy(last)
    }

    public func usage() async throws -> EgressUsage {
        let body = try ok(try await request("GET", "/v1/usage"))
        guard case .object(let root) = try JSONDecoder().decode(JSONAny.self, from: body), let total = root["total"]?.object else {
            throw EgressAdminError.malformed("usage")
        }
        func n(_ key: String) -> Int { total[key]?.int ?? 0 }
        var byVia: [String: [String: Int]] = [:]
        for (name, value) in root["by_via"]?.object ?? [:] {
            byVia[name] = (value.object ?? [:]).compactMapValues(\.int)
        }
        return EgressUsage(
            via: root["via"]?.string ?? "?", requests: n("requests"), tunnels: n("tunnels"), bytesUp: n("bytes_up"), bytesDown: n("bytes_down"),
            blocked: n("blocked"), errors: n("errors"), renders: n("renders"), openTunnels: root["open_tunnels"]?.int ?? 0,
            reqlogRecords: root["reqlog_records"]?.int ?? 0, byVia: byVia)
    }

    public func reqlog(since: String? = nil, limit: Int = 200) async throws -> [ReqlogRecord] {
        var path = "/v1/reqlog?limit=\(limit)"
        if let since { path += "&since=\(since)" }
        let body = try ok(try await request("GET", path))
        guard case .object(let root) = try JSONDecoder().decode(JSONAny.self, from: body), let records = root["records"]?.array else {
            throw EgressAdminError.malformed("reqlog")
        }
        return records.compactMap { value in
            guard let object = value.object, let id = object["id"]?.string else { return nil }
            return ReqlogRecord(id: id, raw: object)
        }
    }

    public func responseBody(id: String) async throws -> String {
        String(decoding: try ok(try await request("GET", "/v1/reqlog/\(id)/body?kind=response")), as: UTF8.self)
    }

    // MARK: T3-03: runtime, ingest e render

    /// `POST /runtime/v1/<op>`: reverse proxy autenticado do egress até o servidor de controle do runtime (07 §2.2). Devolve o
    /// status e o JSON do runtime sem interpretar (o Core mapeia os códigos de erro).
    public func runtimeCall(_ operation: String, body: Data, timeout: TimeInterval = 125) async throws -> (status: Int, body: Data) {
        guard operation.allSatisfy({ $0.isLetter || $0 == "_" }) else { throw EgressAdminError.malformed(operation) }
        return try await request("POST", "/runtime/v1/\(operation)", body: body, timeout: timeout)
    }

    /// `GET /runtime/v1/health` (aberto no runtime; passa pelo egress autenticado): `true` com o browser pronto.
    public func runtimeReady() async -> Bool {
        guard let result = try? await request("GET", "/runtime/v1/health", timeout: 5), result.status == 200,
              case .object(let root)? = try? JSONDecoder().decode(JSONAny.self, from: result.body) else { return false }
        return root["ready"]?.bool == true
    }

    /// Registro `observed` do app (`http_request`, `render`): o egress redige, encadeia e devolve o id.
    public func ingest(_ payload: Data) async throws -> String {
        let result = try await request("POST", "/v1/reqlog/ingest", body: payload, timeout: 20)
        guard result.status == 200 else { throw EgressAdminError.http(status: result.status, body: String(decoding: result.body, as: UTF8.self)) }
        guard case .object(let root) = try JSONDecoder().decode(JSONAny.self, from: result.body), let id = root["id"]?.string else {
            throw EgressAdminError.malformed("ingest")
        }
        return id
    }

    /// `POST /v1/render`. Status 501 + `{error:"not_supported"}` quando o proxy selecionado não tem render.
    public func render(_ payload: Data, timeout: TimeInterval = 125) async throws -> (status: Int, body: Data) {
        try await request("POST", "/v1/render", body: payload, timeout: timeout)
    }

    /// `GET <path>` autenticado, corpo cru (`/v1/proxy`, `/v1/usage`). Status diferente de 200 lança.
    public func get(_ path: String) async throws -> Data { try ok(try await request("GET", path)) }

    /// Relê `egress.json`, aplica e derruba os túneis do caminho anterior (07 CS-141). Devolve quantos fechou.
    public func reloadProxy() async throws -> Int {
        let body = try ok(try await request("POST", "/v1/proxy/reload"))
        guard case .object(let root) = try JSONDecoder().decode(JSONAny.self, from: body), root["applied"]?.bool == true else {
            throw EgressAdminError.malformed("reload")
        }
        return root["closed_tunnels"]?.int ?? 0
    }
}

/// Verificação da cadeia de hashes de `requests.jsonl` (07 CS-149): `"Log integrity: OK"` ou `"Tampered at line <n>"`.
public enum ReqlogIntegrity: Sendable, Equatable {
    case ok(lines: Int)
    case tampered(line: Int)

    public var message: String {
        switch self {
        case .ok: "Log integrity: OK"
        case .tampered(let line): "Tampered at line \(line)"
        }
    }

    public static let genesis = String(repeating: "0", count: 64)

    public static func verify(file: URL) throws -> ReqlogIntegrity {
        guard FileManager.default.fileExists(atPath: file.path) else { return .ok(lines: 0) }
        let data = try Data(contentsOf: file)
        var previous = genesis
        var number = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            if line.isEmpty { continue }
            number += 1
            guard let object = try? JSONDecoder().decode([String: JSONAny].self, from: Data(line)),
                  object["prev_sha256"]?.string == previous else { return .tampered(line: number) }
            previous = SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
        }
        return .ok(lines: number)
    }
}
