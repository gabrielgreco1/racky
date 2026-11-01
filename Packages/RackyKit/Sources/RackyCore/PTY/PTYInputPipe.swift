import RackyProtocol
import Foundation

/// Fila de input de um pane (06 §1.3, 08 AR-709): a UI entrega bytes com a origem marcada e um único consumidor os
/// escreve no daemon na ordem de chegada. `PTYClient.sendInput` é de actor; criar uma `Task` por tecla poderia
/// reordenar, por isso há um só consumidor.
public final class PTYInputPipe: Sendable {
    private let continuation: AsyncStream<(InputOrigin, Data)>.Continuation
    private let task: Task<Void, Never>

    public init(client: PTYClient, sessionID: SessionID) {
        let (stream, continuation) = AsyncStream<(InputOrigin, Data)>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        task = Task {
            for await (origin, bytes) in stream {
                // Sem conexão (reconectando) o input é descartado: tecla digitada às cegas não deve voltar depois.
                try? await client.sendInput(sessionID: sessionID, origin: origin, bytes: bytes)
            }
        }
    }

    public func send(_ bytes: [UInt8], origin: InputOrigin) {
        guard !bytes.isEmpty else { return }
        continuation.yield((origin, Data(bytes)))
    }

    public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
