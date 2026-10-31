import Foundation

/// Leitura de um servidor Prefect (2/3; self-hosted ou Cloud) pela API REST: o que está rodando, agendado e o que falhou. Só lê:
/// nenhuma chamada muda estado no Prefect. Self-hosted usa basic auth (`PREFECT_SERVER_API_AUTH_STRING`), Cloud usa API key (Bearer).
public struct PrefectClient: Sendable {
    public enum Auth: Sendable, Equatable {
        case none
        /// `user:password` (o `PREFECT_SERVER_API_AUTH_STRING` do servidor).
        case basic(String)
        case apiKey(String)
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case badURL
        case unauthorized
        case http(Int)
        case unreachable(String)
        case decoding

        public var description: String {
            switch self {
            case .badURL: "The server URL is not valid."
            case .unauthorized: "The server refused the credentials (401/403)."
            case .http(let code): "The server answered HTTP \(code)."
            case .unreachable(let why): "Could not reach the server: \(why)"
            case .decoding: "The server answered something that is not the Prefect API."
            }
        }
    }

    /// Estados de um flow run na API (`state.type`).
    public enum StateType: String, Sendable, Codable, CaseIterable {
        case scheduled = "SCHEDULED", pending = "PENDING", running = "RUNNING", completed = "COMPLETED", failed = "FAILED"
        case cancelled = "CANCELLED", crashed = "CRASHED", paused = "PAUSED", cancelling = "CANCELLING"
    }

    public struct FlowRun: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let state: StateType?
        public let stateName: String
        public let deploymentID: String?
        public let flowID: String?
        public let workPool: String?
        public let tags: [String]
        public let start: Date?
        public let expectedStart: Date?
        public let end: Date?
        public let totalRunTime: Double

        public init(
            id: String, name: String, state: StateType?, stateName: String, deploymentID: String?, flowID: String?, workPool: String?, tags: [String],
            start: Date?, expectedStart: Date?, end: Date?, totalRunTime: Double
        ) {
            self.id = id; self.name = name; self.state = state; self.stateName = stateName; self.deploymentID = deploymentID; self.flowID = flowID
            self.workPool = workPool; self.tags = tags; self.start = start; self.expectedStart = expectedStart; self.end = end; self.totalRunTime = totalRunTime
        }
    }

    /// URL base da API (termina em `/api`, como `PREFECT_API_URL`).
    public let baseURL: URL
    public let auth: Auth
    let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(baseURL: URL, auth: Auth, transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.baseURL = baseURL
        self.auth = auth
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable("no HTTP response") }
            return (data, http)
        }
    }

    /// `https://host/api` a partir do que o usuário digitou (com ou sem `/api`, com ou sem esquema).
    public static func apiURL(from text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.hasSuffix("/api") { raw += "/api" }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    // MARK: Chamadas

    /// O servidor responde e as credenciais valem: lê 1 run (a leitura também confirma a autenticação).
    public func check() async throws {
        _ = try await flowRuns(states: [.running], limit: 1)
    }

    /// `POST /flow_runs/filter`: runs nos estados pedidos, os mais recentes primeiro. `since` limita pelo início esperado.
    public func flowRuns(states: [StateType], since: Date? = nil, limit: Int = 100) async throws -> [FlowRun] {
        var flowRuns: [String: Any] = ["state": ["type": ["any_": states.map(\.rawValue)]]]
        if let since { flowRuns["expected_start_time"] = ["after_": Self.iso.string(from: since)] }
        let body: [String: Any] = ["flow_runs": flowRuns, "sort": "EXPECTED_START_TIME_DESC", "limit": limit, "offset": 0]
        let data = try await post("flow_runs/filter", body: body)
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.decoding }
        return items.map(Self.flowRun)
    }

    /// `POST /deployments/filter` pelos ids: o nome de cada deployment (para a tabela mostrar "flow/deployment").
    public func deploymentNames(ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let body: [String: Any] = ["deployments": ["id": ["any_": ids]], "limit": min(ids.count, 200)]
        let data = try await post("deployments/filter", body: body)
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.decoding }
        var out: [String: String] = [:]
        for item in items { if let id = item["id"] as? String, let name = item["name"] as? String { out[id] = name } }
        return out
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch auth {
        case .none: break
        case .basic(let pair): request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        case .apiKey(let key): request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(request)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        switch response.statusCode {
        case 200 ..< 300: return data
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(response.statusCode)
        }
    }

    // MARK: Decodificação

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let d = iso.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }

    static func flowRun(_ item: [String: Any]) -> FlowRun {
        let state = item["state"] as? [String: Any]
        let type = (item["state_type"] as? String ?? state?["type"] as? String).flatMap(StateType.init(rawValue:))
        return FlowRun(
            id: item["id"] as? String ?? "", name: item["name"] as? String ?? "",
            state: type, stateName: item["state_name"] as? String ?? state?["name"] as? String ?? type?.rawValue.capitalized ?? "",
            deploymentID: item["deployment_id"] as? String, flowID: item["flow_id"] as? String,
            workPool: item["work_pool_name"] as? String ?? item["work_queue_name"] as? String,
            tags: item["tags"] as? [String] ?? [],
            start: date(item["start_time"]), expectedStart: date(item["expected_start_time"]), end: date(item["end_time"]),
            totalRunTime: item["total_run_time"] as? Double ?? 0)
    }
}
