import Foundation

/// Atualização do monitor de eventos (07 CS-103).
public enum EventUpdate: Sendable, Equatable {
    /// O stream (re)conectou: liste tudo e reconcilie antes de confiar nos eventos seguintes.
    case resync
    case event(DockerEvent)
    /// A conexão caiu; o monitor tenta de novo depois do atraso.
    case disconnected(String)
}

/// Assina `/events` filtrado por label e reconecta com atraso crescente, retomando de `since` (último evento visto).
public struct EventMonitor: Sendable {
    public let client: DockerClient
    public var filters: [String: [String]]
    public var initialDelay: Duration
    public var maxDelay: Duration

    public init(client: DockerClient, labels: [String], types: [String] = ["container", "network", "volume"],
                initialDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(5)) {
        self.client = client
        filters = ["label": labels, "type": types]
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    /// Para de reconectar quando o consumidor cancela. Docker ausente aparece como `.disconnected` e nova tentativa.
    public func updates() -> AsyncStream<EventUpdate> {
        let monitor = self
        return AsyncStream { continuation in
            let task = Task {
                var delay = monitor.initialDelay
                var since: Int64?
                while !Task.isCancelled {
                    do {
                        let stream = try await monitor.client.events(filters: monitor.filters, since: since)
                        continuation.yield(.resync)
                        delay = monitor.initialDelay
                        for try await event in stream {
                            since = event.time
                            continuation.yield(.event(event))
                        }
                        continuation.yield(.disconnected("stream encerrado"))
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.disconnected("\(error)"))
                    }
                    do { try await Task.sleep(for: delay) } catch { break }
                    delay = min(delay * 2, monitor.maxDelay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
