import Foundation
import Synchronization

/// Backend de um computador que já existe para o pai (reservado, na fila ou subindo) mas ainda não tem containers. O
/// `ManagedComputer` nasce com este wrapper; o scheduler troca o backend interno quando o provisionamento termina. Até lá toda
/// operação devolve `queued` (o filho repete) e nunca toca o Docker.
public final class LazyComputerBackend: ComputerBackend, Sendable {
    private let inner = Mutex<(any ComputerBackend)?>(nil)

    public init() {}

    public func attach(_ backend: any ComputerBackend) { inner.withLock { $0 = backend } }
    public func detach() { inner.withLock { $0 = nil } }

    private func current() throws -> any ComputerBackend {
        guard let backend = inner.withLock({ $0 }) else { throw ToolError(.queued, "the computer has no containers yet", retryAfterS: 5) }
        return backend
    }

    public func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON { try await current().runtime(operation, args, timeout: timeout) }
    public func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome { try await current().execRun(request, timeout: timeout) }
    public func execStart(_ request: BackendExec) async throws -> String { try await current().execStart(request) }
    public func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome { try await current().execPoll(jobID: jobID, wait: wait) }
    public func execCancel(jobID: String) async throws -> BackendExecOutcome { try await current().execCancel(jobID: jobID) }
    public func ingest(_ payload: JSON) async throws -> String { try await current().ingest(payload) }
    public func switchProxy(to proxy: String, country: String?) async throws -> Int { try await current().switchProxy(to: proxy, country: country) }
    public func proxyInfo() async throws -> JSON { try await current().proxyInfo() }
    public func usage() async throws -> JSON { try await current().usage() }
    public func render(_ payload: JSON) async throws -> JSON { try await current().render(payload) }
    /// Sem isto o viewer caía no padrão do protocolo ("this computer has no screen") e nunca conectava.
    public func vncEndpoint() async throws -> URL { try await current().vncEndpoint() }
    public func adminTunnel(port: Int) async throws -> AdminTunnelTarget { try await current().adminTunnel(port: port) }
}
