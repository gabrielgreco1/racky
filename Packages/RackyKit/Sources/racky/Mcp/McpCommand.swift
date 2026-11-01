import RackyPlatform
import RackyProtocol
import ArgumentParser
import Foundation

/// `racky mcp --child <id> --capability <token>` (07 §3.1, 08 AR-106/AR-110, S-08).
///
/// Servidor MCP stdio que o Claude Code sobe por filho (`mcpServers` inline do subagente). Não implementa ferramenta nenhuma:
/// cada linha JSON-RPC do stdin vai para o serviço `mcp` de `app.sock` (uma conexão por requisição, com a identidade do filho
/// vinda daqui, da configuração do subagente) e a resposta volta para o stdout. Se o app não está no ar, reabre-o em segundo
/// plano (`open -g -j -b app.racky.mac`), espera até 10 s e reconecta; sem app, devolve um erro de ferramenta legível
/// (`app_unavailable`) em vez de sair com código de erro.
struct McpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "MCP stdio server for a child agent's computer tools (talks to the Racky app).")

    @Option(name: .long, help: "Child id registered by the app at launch.")
    var child: String

    @Option(name: .long, help: "Launch capability token (correlation, never shown to the model).")
    var capability: String

    func run() async throws {
        let helper = McpHelper(
            identity: McpIdentity(child: child, capability: capability), socketPath: AppSockPath.resolve(environment: ProcessInfo.processInfo.environment))
        await helper.serve()
    }
}

/// Escrita serializada no stdout (um objeto JSON por linha).
actor McpStdout {
    func write(_ data: Data) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

actor AppLauncher {
    private var launched = false
    private var lastAttempt: ContinuousClock.Instant?

    /// Abre o app em segundo plano e espera o socket (até 10 s). Chamadas concorrentes compartilham a mesma espera.
    func ensureRunning(socketPath: String, wait: Duration = .seconds(10)) async -> Bool {
        if AppSockClient.isListening(path: socketPath) { return true }
        // `RACKY_MCP_NO_LAUNCH=1` é só de teste (como `RACKY_HOOK_TIMEOUT_MS`, 08 §0.2): não abre o app instalado.
        if ProcessInfo.processInfo.environment["RACKY_MCP_NO_LAUNCH"] == "1" { return false }
        let now = ContinuousClock.now
        if lastAttempt == nil || now - (lastAttempt ?? now) > .seconds(15) {
            lastAttempt = now
            _ = try? await ProcessRunner.run(ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-g", "-j", "-b", "app.racky.mac"], timeout: .seconds(5)))
        }
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            if AppSockClient.isListening(path: socketPath) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}

struct McpHelper: Sendable {
    let identity: McpIdentity
    let socketPath: String
    /// Mais que a maior ferramenta (50 s) com folga para o Docker.
    var callTimeout: Duration = .seconds(150)
    private let stdout = McpStdout()
    private let launcher = AppLauncher()

    init(identity: McpIdentity, socketPath: String) {
        self.identity = identity
        self.socketPath = socketPath
    }

    func serve() async {
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    let message = Data(line.utf8)
                    guard !message.isEmpty else { continue }
                    group.addTask {
                        if let reply = await forward(message) { await stdout.write(reply) }
                    }
                }
            } catch {
                // stdin fechou com erro: encerra como no EOF
            }
            await group.waitForAll()
        }
    }

    // MARK: Encaminhamento

    func forward(_ message: Data) async -> Data? {
        let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any]
        let expectsReply = object?["id"] != nil && !(object?["id"] is NSNull)
        for attempt in 0..<2 {
            do {
                return try await exchange(message, expectsReply: expectsReply)
            } catch let error as McpHelperError where error == .appNotListening {
                if attempt == 0, await launcher.ensureRunning(socketPath: socketPath) { continue }
                return expectsReply ? Self.unavailable(for: object) : nil
            } catch let error as McpHelperError {
                return expectsReply ? Self.failure(object, message: error.message) : nil
            } catch {
                return expectsReply ? Self.failure(object, message: "Racky connection failed: \(error)") : nil
            }
        }
        return expectsReply ? Self.unavailable(for: object) : nil
    }

    private func exchange(_ message: Data, expectsReply: Bool) async throws -> Data? {
        let connection: AppSockConnection
        do { connection = try AppSockClient.connect(path: socketPath) } catch { throw McpHelperError.appNotListening }
        defer { Task { await connection.close() } }
        let encoder = CtlCodec.encoder()
        try await connection.send(try encoder.encode(AppSockHello(service: .mcp)))
        try await connection.send(try encoder.encode(identity))
        try await connection.send(message)
        return try await withTimeout(callTimeout) {
            let hello = try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await connection.receive())
            guard hello.ok else { throw McpHelperError.refused(hello.error?.message ?? "handshake refused") }
            guard expectsReply else { return nil }
            // App fechado ou reiniciado no meio da chamada: sem resposta o Claude Code espera o id para sempre. Vira erro de
            // ferramenta com `retry_after_s` (o filho repete; a ferramenta pode ou não ter rodado).
            do { return try await connection.receive() } catch AppSockError.closed { throw McpHelperError.interrupted }
        }
    }

    private func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw McpHelperError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw McpHelperError.timeout }
            return first
        }
    }

    // MARK: Respostas sintéticas (app ausente, erro de transporte)

    private static func requestID(_ object: [String: Any]?) -> Any { object?["id"] ?? NSNull() }

    private static func encode(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data() }

    /// Erro de FERRAMENTA legível (não deixa o CLI marcar o servidor como quebrado): `{error, message, retry_after_s}`.
    static func unavailable(for object: [String: Any]?) -> Data {
        let body: [String: Any] = ["error": "app_unavailable", "message": "Racky is not running; retrying", "retry_after_s": 5]
        guard (object?["method"] as? String) == "tools/call" else {
            return encode(["jsonrpc": "2.0", "id": requestID(object), "error": ["code": -32000, "message": "Racky is not running; retrying"]])
        }
        let text = String(decoding: encode(body), as: UTF8.self)
        return encode(["jsonrpc": "2.0", "id": requestID(object), "result": ["isError": true, "content": [["type": "text", "text": text]]]])
    }

    static func failure(_ object: [String: Any]?, message: String) -> Data {
        guard (object?["method"] as? String) == "tools/call" else {
            return encode(["jsonrpc": "2.0", "id": requestID(object), "error": ["code": -32000, "message": message]])
        }
        let text = String(decoding: encode(["error": "app_unavailable", "message": message, "retry_after_s": 5]), as: UTF8.self)
        return encode(["jsonrpc": "2.0", "id": requestID(object), "result": ["isError": true, "content": [["type": "text", "text": text]]]])
    }
}

enum McpHelperError: Error, Equatable {
    case appNotListening
    case refused(String)
    case timeout
    case interrupted

    var message: String {
        switch self {
        case .appNotListening: "Racky is not running; retrying"
        case .refused(let m): "Racky refused the connection: \(m)"
        case .timeout: "Racky did not answer in time"
        case .interrupted: "Racky restarted during this call; check the computer's state (box_status) and retry"
        }
    }
}
