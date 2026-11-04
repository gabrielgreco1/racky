import Foundation

/// Conector de MySQL/MariaDB, SQL Server e Oracle: um helper pequeno em Go (`racky-db`, em Contents/Helpers) que só roda enquanto
/// há um pedido. Cada chamada é um processo: o pedido (com a connection string, que tem a senha) vai em JSON no stdin, a resposta
/// volta em JSON no stdout e o processo sai. Nada fica aberto entre as chamadas; a senha nunca vai em argv nem em log.
public struct SQLHelperConnector: PostgresBrowsing {
    public typealias Failure = PostgresConnector.Failure

    /// Variável de ambiente que troca o helper (os testes apontam para um script falso).
    public static let helperEnvironmentKey = "RACKY_DB_HELPER"

    public let engine: SQLHelperEngine
    private let dsn: String
    private let helperOverride: URL?

    /// `dsn` é a URL canônica (`SQLConnectionSpec.url`).
    public init(engine: SQLHelperEngine, dsn: String, helper: URL? = nil) {
        self.engine = engine
        self.dsn = dsn
        self.helperOverride = helper
    }

    /// Onde está o helper: o override do ambiente, senão `Contents/Helpers/racky-db` do app (ou ao lado do executável, em dev).
    public static func locateHelper(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = environment[helperEnvironmentKey], !path.isEmpty { return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/racky-db"))
        if let executable = bundle.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("../Helpers/racky-db").standardizedFileURL)
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("racky-db"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    // MARK: PostgresBrowsing

    public func check() async throws { _ = try await send(Request(op: "check")) }

    public func schemas() async throws -> [String] { try await catalog().map(\.name) }

    public func tables(schema: String) async throws -> [PostgresTable] { try await catalog().first { $0.name == schema }?.tables ?? [] }

    public func catalog() async throws -> [PostgresSchema] {
        let response = try await send(Request(op: "catalog"))
        return (response.schemas ?? []).map { schema in
            PostgresSchema(name: schema.name, tables: schema.tables.map {
                PostgresTable(schema: schema.name, name: $0.name, isView: $0.isView, estimatedRows: $0.estimatedRows.map(Int.init))
            })
        }
    }

    public func columns(schema: String, table: String) async throws -> [PostgresColumn] {
        let response = try await send(Request(op: "columns", schema: schema, table: table))
        return (response.columns ?? []).map { PostgresColumn(name: $0.name, type: $0.type, nullable: $0.nullable, isKey: $0.isKey) }
    }

    public func rowCount(schema: String, table: String) async throws -> PostgresRowCount {
        let response = try await send(Request(op: "rowCount", schema: schema, table: table))
        guard let count = response.rowCount else { throw Failure.unreachable("the database helper answered without a count") }
        return PostgresRowCount(value: Int(count.value), exact: count.exact)
    }

    public func rows(schema: String, table: String, limit: Int, offset: Int, orderBy: [String]) async throws -> PostgresResult {
        let response = try await send(Request(op: "rows", schema: schema, table: table, limit: limit, offset: offset, orderBy: orderBy))
        return try result(response)
    }

    public func query(sql: String, limit: Int) async throws -> PostgresResult {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.sql("Write a query first.") }
        return try result(try await send(Request(op: "query", limit: limit, sql: sql)))
    }

    private func result(_ response: Response) throws -> PostgresResult {
        guard let result = response.result else { throw Failure.unreachable("the database helper answered without rows") }
        return PostgresResult(columns: result.columns, rows: result.rows, truncated: result.truncated)
    }

    // MARK: Protocolo (o mesmo JSON de helpers/racky-db/protocol.go)

    struct Request: Encodable {
        var op: String
        var engine = ""
        var dsn = ""
        var schema: String?
        var table: String?
        var limit: Int?
        var offset: Int?
        var orderBy: [String]?
        var sql: String?
        var timeoutSeconds: Double?
    }

    struct Response: Decodable {
        struct ErrorBody: Decodable { var kind: String; var message: String }
        struct Table: Decodable { var name: String; var isView: Bool; var estimatedRows: Int64? }
        struct Schema: Decodable { var name: String; var tables: [Table] }
        struct Column: Decodable { var name: String; var type: String; var nullable: Bool; var isKey: Bool }
        struct Count: Decodable { var value: Int64; var exact: Bool }
        struct Result: Decodable { var columns: [String]; var rows: [[String]]; var truncated: Bool }
        var ok: Bool
        var error: ErrorBody?
        var schemas: [Schema]?
        var columns: [Column]?
        var rowCount: Count?
        var result: Result?
    }

    /// O helper recebe um prazo um pouco menor que o do app, para ele mesmo responder "timeout" antes de o app desistir.
    static let helperDeadline = PostgresConnector.operationDeadline - 3

    private func send(_ request: Request) async throws -> Response {
        guard let helper = helperOverride ?? Self.locateHelper() else {
            throw Failure.invalidConnectionString("The database helper (racky-db) is missing from this build of Racky.")
        }
        var request = request
        request.engine = engine.rawValue
        request.dsn = dsn
        request.timeoutSeconds = Self.helperDeadline
        let body = try JSONEncoder().encode(request)
        let data = try await PostgresConnector.withDeadline(PostgresConnector.operationDeadline) {
            try await HelperProcess.run(helper, stdin: body)
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Failure.unreachable("the database helper stopped without an answer")
        }
        if response.ok { return response }
        throw Self.map(response.error)
    }

    static func map(_ error: Response.ErrorBody?) -> Failure {
        guard let error else { return .unreachable("the database helper reported a failure") }
        switch error.kind {
        case "unreachable": return .unreachable(error.message)
        case "auth": return .auth(error.message)
        case "tls": return .tls(error.message)
        case "timeout": return .timeout
        case "invalid": return .invalidConnectionString(error.message)
        default: return .sql(error.message)
        }
    }
}

/// Roda o helper uma vez: stdin com o pedido, stdout lido até o fim. Cancelar (o prazo estourou) encerra o processo.
private final class HelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    static func run(_ helper: URL, stdin: Data) async throws -> Data {
        let run = HelperProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try run.execute(helper, stdin: stdin)) } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            run.terminate()
        }
    }

    private func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func execute(_ helper: URL, stdin: Data) throws -> Data {
        let process = Process()
        process.executableURL = helper
        process.arguments = []
        // Ambiente mínimo: o helper não precisa de nada do ambiente do app.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw PostgresConnector.Failure.timeout }
        self.process = process
        lock.unlock()
        do { try process.run() } catch {
            throw PostgresConnector.Failure.unreachable("the database helper could not start")
        }
        // O pedido pode passar do buffer do pipe: escrever fora desta thread evita travar se o helper responder antes de ler tudo.
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw PostgresConnector.Failure.timeout }
        return data
    }
}
