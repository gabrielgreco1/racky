import Darwin
import Dispatch
import Foundation

/// Conexão de stream sobre socket Unix, não bloqueante: leitura e escrita são dirigidas por `DispatchSource`
/// numa fila própria; as chamadas `async` só suspendem (nunca bloqueiam uma thread do pool cooperativo).
///
/// - `receive()` é por demanda: o fd só é lido enquanto há um `receive()` pendente (contrapressão de leitura).
/// - `send(_:)` só retorna quando todos os bytes foram aceitos pelo kernel (contrapressão de escrita).
/// - `close()` é idempotente e acorda quem espera. Cancelar a task dentro de `receive()` fecha a conexão.
// SAFETY: todo estado mutável é confinado à fila serial `queue`; nenhum método o toca fora dela.
public final class UDSConnection: @unchecked Sendable {
    private struct PendingWrite {
        var data: Data
        var offset: Int
        var continuation: CheckedContinuation<Void, any Error>
    }

    /// Tamanho máximo de uma leitura do fd.
    public static let readChunkSize = 64 << 10

    /// Credenciais do peer lidas no `accept` (só conexões aceitas por `UDSListener`; `nil` no lado cliente).
    public let peer: PeerCredentials?

    private let fd: Int32
    private let queue = DispatchQueue(label: "app.racky.uds.connection")
    private let readSource: any DispatchSourceRead
    private let writeSource: any DispatchSourceWrite
    private var readRunning = false
    private var writeRunning = false
    private var pendingReceive: CheckedContinuation<Data?, any Error>?
    private var reachedEOF = false
    private var closed = false
    private var cancelledSources = 0
    private var writes: [PendingWrite] = []
    private var writeFailure: UDSError?
    private var finishWritingRequested = false

    /// Assume a posse do descritor (já não bloqueante, `CLOEXEC`, `NOSIGPIPE`).
    init(adopting fd: Int32, peer: PeerCredentials? = nil) {
        self.fd = fd
        self.peer = peer
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [self] in handleReadable() }
        writeSource.setEventHandler { [self] in flushWrites() }
        readSource.setCancelHandler { [self] in sourceCancelled() }
        writeSource.setCancelHandler { [self] in sourceCancelled() }
    }

    /// Próximo pedaço de bytes, ou `nil` no fim do stream (EOF do par ou conexão fechada).
    public func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                queue.async { self.beginReceive(continuation) }
            }
        } onCancel: {
            self.close()
        }
    }

    /// Escreve todos os bytes; suspende enquanto o par não drena.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { self.beginSend(data, continuation) }
        }
    }

    /// Half-close da escrita (`shutdown(SHUT_WR)`) depois que todos os bytes enfileirados foram aceitos pelo kernel.
    /// A leitura continua aberta. É assim que o stdin de um exec hijacked do Docker recebe EOF (07 CS-102).
    public func finishWriting() {
        queue.async {
            guard !self.closed, !self.finishWritingRequested else { return }
            self.finishWritingRequested = true
            if self.writes.isEmpty { self.shutdownWriteOnQueue() }
        }
    }

    public func close() {
        queue.async { self.closeOnQueue() }
    }

    private func shutdownWriteOnQueue() {
        shutdown(fd, SHUT_WR)
    }

    // MARK: Leitura

    private func beginReceive(_ continuation: CheckedContinuation<Data?, any Error>) {
        if closed || reachedEOF {
            continuation.resume(returning: nil)
            return
        }
        if pendingReceive != nil {
            continuation.resume(throwing: UDSError.concurrentReceive)
            return
        }
        pendingReceive = continuation
        if !readRunning {
            readRunning = true
            readSource.resume()
        }
    }

    private func handleReadable() {
        guard !closed else { return }
        guard let continuation = pendingReceive else {
            suspendRead()
            return
        }
        var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            pendingReceive = nil
            suspendRead()
            continuation.resume(returning: Data(buffer[0 ..< count]))
        } else if count == 0 {
            reachedEOF = true
            pendingReceive = nil
            suspendRead()
            continuation.resume(returning: nil)
        } else if errno == EAGAIN || errno == EINTR {
            return
        } else {
            let code = errno
            pendingReceive = nil
            suspendRead()
            continuation.resume(throwing: UDSError.system(op: "read", errno: code))
        }
    }

    private func suspendRead() {
        guard readRunning else { return }
        readRunning = false
        readSource.suspend()
    }

    // MARK: Escrita

    private func beginSend(_ data: Data, _ continuation: CheckedContinuation<Void, any Error>) {
        if closed {
            continuation.resume(throwing: UDSError.closed)
            return
        }
        if let writeFailure {
            continuation.resume(throwing: writeFailure)
            return
        }
        writes.append(PendingWrite(data: data, offset: 0, continuation: continuation))
        flushWrites()
    }

    private func flushWrites() {
        guard !closed else { return }
        while let current = writes.first {
            let remaining = current.data.count - current.offset
            let count = current.data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress! + current.offset, remaining)
            }
            if count >= 0 {
                if count == remaining {
                    writes.removeFirst()
                    current.continuation.resume()
                } else {
                    writes[0].offset += count
                }
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                if !writeRunning {
                    writeRunning = true
                    writeSource.resume()
                }
                return
            } else {
                let failure = UDSError.system(op: "write", errno: errno)
                writeFailure = failure
                let failed = writes
                writes.removeAll()
                for pending in failed { pending.continuation.resume(throwing: failure) }
                break
            }
        }
        if writeRunning {
            writeRunning = false
            writeSource.suspend()
        }
        if finishWritingRequested, writes.isEmpty, writeFailure == nil { shutdownWriteOnQueue() }
    }

    // MARK: Fechamento

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        if let continuation = pendingReceive {
            pendingReceive = nil
            continuation.resume(returning: nil)
        }
        let failed = writes
        writes.removeAll()
        for pending in failed { pending.continuation.resume(throwing: UDSError.closed) }
        shutdown(fd, SHUT_RDWR)
        // Uma fonte suspensa (ou nunca ativada) precisa ser retomada antes do cancelamento.
        if !readRunning { readSource.resume() }
        readRunning = true
        if !writeRunning { writeSource.resume() }
        writeRunning = true
        readSource.cancel()
        writeSource.cancel()
    }

    private func sourceCancelled() {
        cancelledSources += 1
        if cancelledSources == 2 { Darwin.close(fd) }
    }
}
