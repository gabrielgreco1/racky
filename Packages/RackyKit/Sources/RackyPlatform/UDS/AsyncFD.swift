import Darwin
import Dispatch
import Foundation
import Synchronization

/// Erros de socket UNIX.
public enum AppSockError: Error, Equatable, Sendable {
    case pathTooLong(Int)
    case alreadyRunning(String)
    case syscall(String, Int32)
    case closed
}

/// DispatchSource é thread-safe para `cancel()`; o wrapper só o atravessa o `Mutex`.
struct SourceBox: @unchecked Sendable {  // SAFETY: DispatchSource.cancel() é seguro entre threads; nada mais é chamado.
    let source: any DispatchSourceProtocol
}

/// Espera one-shot de prontidão de um descritor, cancelável (sem semáforo, sem thread bloqueada).
final class OneShotReadiness: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, any Error>, SourceBox)
        case finished
    }

    private let state = Mutex<State>(.idle)

    func install(_ continuation: CheckedContinuation<Void, any Error>, source: any DispatchSourceProtocol) {
        let proceed: Bool = state.withLock { s in
            switch s {
            case .idle:
                s = .waiting(continuation, SourceBox(source: source))
                return true
            default:
                return false
            }
        }
        if !proceed {
            source.cancel()
            continuation.resume(throwing: CancellationError())
        }
    }

    func finish(_ result: Result<Void, any Error>) {
        let taken: (CheckedContinuation<Void, any Error>, SourceBox)? = state.withLock { s in
            defer { s = .finished }
            if case .waiting(let c, let src) = s { return (c, src) }
            return nil
        }
        if let (c, src) = taken {
            src.source.cancel()
            c.resume(with: result)
        }
    }
}

private let readinessQueue = DispatchQueue(label: "app.racky.uds.readiness", qos: .userInitiated, attributes: .concurrent)

/// Espera `fd` ficar legível (ou gravável). Lança `CancellationError` se a Task for cancelada.
func awaitReady(fd: Int32, writable: Bool) async throws {
    let waiter = OneShotReadiness()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let source: any DispatchSourceProtocol
            if writable {
                source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: readinessQueue)
            } else {
                source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readinessQueue)
            }
            source.setEventHandler { waiter.finish(.success(())) }
            waiter.install(cont, source: source)
            source.resume()
        }
    } onCancel: {
        waiter.finish(.failure(CancellationError()))
    }
}

func setNonBlocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw AppSockError.syscall("fcntl", errno) }
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Lê o que houver (até 64 KiB). `Data()` vazio = EOF.
func readSome(fd: Int32) async throws -> Data {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        try Task.checkCancellation()
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 { return Data(buffer[0..<n]) }
        if n == 0 { return Data() }
        switch errno {
        case EINTR: continue
        case EAGAIN: try await awaitReady(fd: fd, writable: false)
        default: throw AppSockError.syscall("read", errno)
        }
    }
}

func writeAll(fd: Int32, _ data: Data) async throws {
    var offset = 0
    while offset < data.count {
        try Task.checkCancellation()
        let n = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        }
        if n > 0 {
            offset += n
            continue
        }
        switch errno {
        case EINTR: continue
        case EAGAIN: try await awaitReady(fd: fd, writable: true)
        default: throw AppSockError.syscall("write", errno)
        }
    }
}

func makeSockAddr(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { throw AppSockError.pathTooLong(bytes.count) }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return addr
}
