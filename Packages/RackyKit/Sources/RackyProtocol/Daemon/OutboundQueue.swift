import Foundation

/// Fila de saída de UM cliente no daemon, com o limite de 2 MiB (06 §1.3, 08 AR-102).
///
/// Política: quando um frame `output` não cabe, a fila **descarta todos os frames `output` pendentes** daquele
/// cliente, marca as sessões afetadas como "aguardando resync" e enfileira `resyncRequired` para cada uma.
/// Frames de controle (respostas e eventos) nunca são descartados. Enquanto a sessão aguarda resync, novos
/// `output` dela são ignorados; o cliente refaz `attach` em modo `snapshot` e o daemon chama `didResync`.
/// A sessão nunca é bloqueada por um cliente lento: `enqueue` nunca espera.
public struct OutboundQueue: Sendable {
    public enum EnqueueResult: Sendable, Hashable {
        /// Frame aceito.
        case queued
        /// `output` ignorado: a sessão já aguarda resync.
        case discarded
        /// Estouro: fila de `output` descartada e `resyncRequired` enfileirado para estas sessões.
        case overflow(resyncSessions: [SessionID])
    }

    private struct Entry: Sendable {
        var frame: Frame
        var size: Int
    }

    public let limitBytes: Int
    public private(set) var pendingBytes = 0
    private var entries: [Entry] = []
    private var awaitingResync: Set<SessionID> = []

    public init(limitBytes: Int = ProtocolLimits.clientQueueLimit) {
        self.limitBytes = limitBytes
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func isAwaitingResync(_ session: SessionID) -> Bool { awaitingResync.contains(session) }

    public mutating func enqueue(_ frame: Frame) throws -> EnqueueResult {
        let size = try FrameCodec.wireSize(of: frame)
        guard case .output(let output) = frame else {
            append(frame, size: size)
            return .queued
        }
        if awaitingResync.contains(output.sessionID) { return .discarded }
        if pendingBytes + size <= limitBytes {
            append(frame, size: size)
            return .queued
        }
        // Estouro: descarta todo o `output` pendente (de todas as sessões deste cliente).
        var affected: [SessionID] = []
        var kept: [Entry] = []
        var keptBytes = 0
        for entry in entries {
            if case .output(let pending) = entry.frame {
                if !affected.contains(pending.sessionID) { affected.append(pending.sessionID) }
            } else {
                kept.append(entry)
                keptBytes += entry.size
            }
        }
        if !affected.contains(output.sessionID) { affected.append(output.sessionID) }
        entries = kept
        pendingBytes = keptBytes
        for session in affected {
            awaitingResync.insert(session)
            let event = Frame.control(.event(DaemonEvent(sessionID: session, payload: .resyncRequired)))
            append(event, size: try FrameCodec.wireSize(of: event))
        }
        return .overflow(resyncSessions: affected)
    }

    /// Próximo frame a escrever no socket (FIFO).
    public mutating func dequeue() -> Frame? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        pendingBytes -= entry.size
        return entry.frame
    }

    /// O cliente refez `attach` (snapshot): volta a receber `output` desta sessão.
    public mutating func didResync(_ session: SessionID) {
        awaitingResync.remove(session)
    }

    /// Esquece a sessão (detach, forget, sessão encerrada): descarta o `output` pendente dela.
    public mutating func removeOutput(for session: SessionID) {
        awaitingResync.remove(session)
        entries.removeAll { entry in
            if case .output(let pending) = entry.frame, pending.sessionID == session {
                pendingBytes -= entry.size
                return true
            }
            return false
        }
    }

    private mutating func append(_ frame: Frame, size: Int) {
        entries.append(Entry(frame: frame, size: size))
        pendingBytes += size
    }
}
