import Darwin
import Dispatch
import Foundation

/// Falhas do transporte por socket Unix.
public enum UDSError: Error, Sendable, Hashable {
    /// Caminho acima do limite de `sun_path` (103 bytes + NUL) ou com byte nulo.
    case pathTooLong(Int)
    /// Diretório do socket não pertence ao usuário ou é acessível a outros (exige `0700`).
    case insecureDirectory(String)
    /// Já existe um servidor vivo no caminho.
    case addressInUse(String)
    /// Existe um arquivo que não é socket no caminho.
    case pathOccupied(String)
    /// Falha de syscall (`op`, `errno`).
    case system(op: String, errno: Int32)
    /// Operação em conexão já fechada localmente.
    case closed
    /// Duas chamadas simultâneas a `receive()` na mesma conexão.
    case concurrentReceive
}

enum UDSSupport {
    /// Maior caminho aceito (bytes UTF-8, sem NUL final).
    static let maxPathBytes = 103  // sun_path tem 104 bytes no macOS (inclui o NUL)

    /// Executa trabalho de syscall fora do pool cooperativo (fila global do GCD).
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func withSockaddr<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes, !bytes.contains(0) else { throw UDSError.pathTooLong(bytes.count) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSError.system(op: "socket", errno: errno) }
        do {
            try configure(fd, nonBlocking: false)
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// `FD_CLOEXEC` e `SO_NOSIGPIPE` sempre; `O_NONBLOCK` quando pedido.
    static func configure(_ fd: Int32, nonBlocking: Bool) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw UDSError.system(op: "fcntl(FD_CLOEXEC)", errno: errno) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw UDSError.system(op: "setsockopt(SO_NOSIGPIPE)", errno: errno)
        }
        if nonBlocking {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw UDSError.system(op: "fcntl(O_NONBLOCK)", errno: errno)
            }
        }
    }
}
