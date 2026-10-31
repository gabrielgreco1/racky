import RackyDocker
import Foundation

/// Um comando para o container `work` (via Engine API, uid 10002).
public struct BackendExec: Sendable, Equatable {
    public var argv: [String]?
    public var shell: String?
    /// Caminho dentro do container já validado (`/work/...`).
    public var cwd: String
    public var stdin: Data?
    public var env: [String: String]
    /// Nomes de segredo exportados SÓ neste processo, lidos de `/run/racky/secrets/<NOME>` dentro do container (§3.3).
    public var secretEnv: [String]

    public init(argv: [String]? = nil, shell: String? = nil, cwd: String = "/work", stdin: Data? = nil, env: [String: String] = [:], secretEnv: [String] = []) {
        self.argv = argv; self.shell = shell; self.cwd = cwd; self.stdin = stdin; self.env = env; self.secretEnv = secretEnv
    }
}

public struct BackendExecOutcome: Sendable, Equatable {
    public var running: Bool
    public var exitCode: Int?
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var durationMs: Int

    public init(running: Bool = false, exitCode: Int? = nil, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false, durationMs: Int = 0) {
        self.running = running; self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut; self.durationMs = durationMs
    }
}

/// Tudo que as ferramentas precisam do Docker e do egress, atrás de um protocolo (testes de unidade usam um falso). O reqlog NÃO
/// passa por aqui: o app lê `logs/requests.jsonl` direto do host (só o egress escreve nele).
public protocol ComputerBackend: Sendable {
    /// Operação do servidor de controle do runtime (`POST /runtime/v1/<op>` pelo egress). Lança `ToolError` com o código estável.
    func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON
    /// Executa no `work` até terminar ou estourar `timeout` (aí o grupo de processos recebe SIGTERM e depois SIGKILL).
    func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome
    func execStart(_ request: BackendExec) async throws -> String
    func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome
    func execCancel(jobID: String) async throws -> BackendExecOutcome
    /// Entrega um registro `observed` ao egress (que redige, encadeia e devolve o id).
    func ingest(_ payload: JSON) async throws -> String
    /// Troca o proxy (reescreve `egress.json`, recarrega o egress e derruba os túneis antigos). Devolve quantos fechou.
    func switchProxy(to proxy: String, country: String?) async throws -> Int
    func proxyInfo() async throws -> JSON
    func usage() async throws -> JSON
    /// `POST /v1/render` no egress. Lança `not_supported` etc.
    func render(_ payload: JSON) async throws -> JSON
    /// URL WebSocket do viewer (`ws://127.0.0.1:<porta do egress>/vnc?ticket=...`), com ticket de uso único válido por 60 s.
    func vncEndpoint() async throws -> URL
    /// Túnel até `127.0.0.1:<port>` dentro do computador, pela admin API (`GET /v1/tcp`): a porta da admin no Mac e o pedido de upgrade
    /// já autenticado. É como o app lê um banco que o agente subiu no computador.
    func adminTunnel(port: Int) async throws -> AdminTunnelTarget
}

/// Onde abrir um túnel para um serviço do computador: a admin API no loopback do Mac e o cabeçalho do upgrade (leva o token).
public struct AdminTunnelTarget: Sendable {
    public var adminPort: Int
    public var request: Data
    public init(adminPort: Int, request: Data) { self.adminPort = adminPort; self.request = request }
}

extension ComputerBackend {
    public func adminTunnel(port: Int) async throws -> AdminTunnelTarget { throw ToolError(.notSupported, "this computer has no admin tunnel") }

    /// `http_request`: roda `abx-http` (curl_cffi) no `work`, saindo pelo egress. Devolve o JSON do script.
    func httpRun(_ spec: JSON, timeout: Duration) async throws -> JSON {
        let outcome = try await execRun(BackendExec(argv: ["abx-http"], cwd: "/work", stdin: spec.data()), timeout: timeout)
        if outcome.timedOut { throw ToolError(.timeout, "http_request did not finish in \(timeout)") }
        guard let json = try? JSON.parse(outcome.stdout), json.object != nil else {
            throw ToolError(.proxyError, "http helper failed (exit \(outcome.exitCode ?? -1)): \(String(decoding: outcome.stderr.suffix(300), as: UTF8.self))")
        }
        return json
    }
}

/// Mapeia a resposta do runtime (status + corpo JSON) para `ToolError` com código do conjunto fechado.
public enum RuntimeErrorMapper {
    public static func map(status: Int, body: JSON) -> ToolError {
        let code = body["error"]?.string ?? ""
        let message = body["message"]?.string ?? "runtime error (\(status))"
        let details = body["details"]
        if code == ToolErrorCode.humanInControl.rawValue {
            var error = ManagedComputer.humanInControlError()
            error.details = details ?? error.details
            error.retryAfterS = details?["retry_after_s"]?.int ?? error.retryAfterS
            return error
        }
        if let known = ToolErrorCode(rawValue: code) {
            return ToolError(known, message, retryAfterS: details?["retry_after_s"]?.int, details: details)
        }
        switch code {
        case "navigation_failed": return ToolError(.proxyError, message, details: details)
        case "unauthorized": return ToolError(.appUnavailable, "the runtime rejected the app token", retryAfterS: 5)
        default:
            if status == 408 { return ToolError(.timeout, message, details: details) }
            if status == 409 || status == 503 { return ToolError(.boxRestarted, message, details: details) }
            return ToolError(.invalidArgument, message, details: details)
        }
    }
}
