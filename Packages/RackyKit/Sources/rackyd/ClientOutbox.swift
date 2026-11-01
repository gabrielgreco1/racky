import RackyProtocol
import Foundation
import Synchronization

/// Replay de um `attach`: a resposta `attachSnapshot` e os bytes de `startSeq` a `endSeq`, enviados com
/// contrapressão direta do socket (o ring de até 4 MiB não passa pela fila de 2 MiB do cliente).
struct ReplayJob: Sendable {
    var reply: DaemonReply
    var sessionID: SessionID
    var startSeq: UInt64
    var bytes: [UInt8]
}

enum OutboxWork: Sendable {
    case frame(Frame)
    case replay(ReplayJob)
}

/// Fila de saída de UM cliente (06 §1.3 backpressure): `OutboundQueue` de 2 MiB + replays pendentes.
/// Quem produz (sessões, na fila GCD delas) nunca espera; um único escritor consome (`next()`).
final class ClientOutbox: Sendable {
    private struct State {
        var queue: OutboundQueue
        var replays: [ReplayJob] = []
        var closed = false
    }

    // LOCK: protege só a fila e a lista de replays; nenhum I/O sob o lock.
    private let state: Mutex<State>
    private let wake: AsyncStream<Void>.Continuation
    let wakeStream: AsyncStream<Void>
    /// Total de vezes que a fila estourou (diagnóstico e testes).
    private let overflows = Mutex(0)

    init(limitBytes: Int = ProtocolLimits.clientQueueLimit) {
        state = Mutex(State(queue: OutboundQueue(limitBytes: limitBytes)))
        (wakeStream, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var overflowCount: Int { overflows.withLock { $0 } }

    @discardableResult
    func enqueue(_ frame: Frame) -> OutboundQueue.EnqueueResult? {
        let result: OutboundQueue.EnqueueResult? = state.withLock { state in
            guard !state.closed else { return nil }
            return try? state.queue.enqueue(frame)
        }
        if case .overflow = result { overflows.withLock { $0 += 1 } }
        wake.yield()
        return result
    }

    func enqueueControl(_ message: ControlMessage) { enqueue(.control(message)) }

    /// Substitui o stream da sessão por um replay novo (`attach`): descarta o `output` pendente dela e a marca de resync.
    func beginReplay(_ job: ReplayJob) {
        state.withLock { state in
            guard !state.closed else { return }
            state.queue.removeOutput(for: job.sessionID)
            state.queue.didResync(job.sessionID)
            state.replays.append(job)
        }
        wake.yield()
    }

    func removeOutput(for session: SessionID) {
        state.withLock { $0.queue.removeOutput(for: session) }
    }

    /// Replays têm prioridade: o live da sessão só segue depois deles (o `seq` ao vivo começa em `endSeq`).
    func next() -> OutboxWork? {
        state.withLock { state in
            if !state.replays.isEmpty { return .replay(state.replays.removeFirst()) }
            return state.queue.dequeue().map { .frame($0) }
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    func close() {
        state.withLock { $0.closed = true }
        wake.finish()
    }
}

/// Assinaturas de eventos por conexão e despacho (06 §1.3 `subscribe`). Quem está anexado a uma sessão recebe todos
/// os eventos dela; `stillAlive`, `resyncRequired` e `sessionGone` não dependem de `events[]`.
final class EventHub: Sendable {
    private struct Subscriber {
        var outbox: ClientOutbox
        var all = false
        var sessions: Set<SessionID> = []
        var kinds: Set<EventKind> = []
    }

    // LOCK: protege o mapa de assinantes; o enfileiramento acontece fora do lock.
    private let subscribers = Mutex<[ObjectIdentifier: Subscriber]>([:])

    func register(_ outbox: ClientOutbox) {
        subscribers.withLock { $0[ObjectIdentifier(outbox)] = Subscriber(outbox: outbox) }
    }

    func unregister(_ outbox: ClientOutbox) {
        subscribers.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(outbox)) }
    }

    func subscribe(_ outbox: ClientOutbox, request: SubscribeRequest) {
        subscribers.withLock { map in
            guard var subscriber = map[ObjectIdentifier(outbox)] else { return }
            subscriber.kinds.formUnion(request.events)
            switch request.scope {
            case .all: subscriber.all = true
            case .sessions(let ids): subscriber.sessions.formUnion(ids)
            }
            map[ObjectIdentifier(outbox)] = subscriber
        }
    }

    func dispatch(_ event: DaemonEvent, attached: [ClientOutbox]) {
        let attachedIDs = Set(attached.map { ObjectIdentifier($0) })
        let targets: [ClientOutbox] = subscribers.withLock { map in
            map.values.compactMap { subscriber in
                if attachedIDs.contains(ObjectIdentifier(subscriber.outbox)) { return subscriber.outbox }
                guard subscriber.all || subscriber.sessions.contains(event.sessionID) else { return nil }
                if let kind = event.payload.subscribableKind, !subscriber.kinds.contains(kind) { return nil }
                return subscriber.outbox
            }
        }
        for outbox in targets { outbox.enqueueControl(.event(event)) }
    }
}
