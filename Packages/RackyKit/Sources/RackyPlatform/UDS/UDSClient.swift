import Darwin
import Foundation

/// Cliente de socket Unix.
public enum UDSClient {
    /// Conecta em `path`. O `connect` roda fora do pool cooperativo; a conexão devolvida é não bloqueante.
    public static func connect(path: String) async throws -> UDSConnection {
        let fd = try await UDSSupport.offPool {
            let fd = try UDSSupport.makeSocket()
            do {
                try UDSSupport.withSockaddr(path: path) { address, length in
                    guard Darwin.connect(fd, address, length) == 0 else { throw UDSError.system(op: "connect", errno: errno) }
                }
                try UDSSupport.configure(fd, nonBlocking: true)
            } catch {
                Darwin.close(fd)
                throw error
            }
            return fd
        }
        return UDSConnection(adopting: fd)
    }
}
