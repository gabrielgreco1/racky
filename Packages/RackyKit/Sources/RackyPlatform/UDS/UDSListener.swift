import Darwin
import Dispatch
import Foundation

/// Servidor de socket Unix: aceita conexões sem bloquear (fonte de leitura do GCD) e as entrega em `connections`.
///
/// `listen(path:)` faz o `bind` (modo degradado e testes, 06 §1.2): confere dono e modo do diretório (`0700`),
/// remove socket obsoleto (sem servidor vivo), cria o socket com `0600`. `adopt(fileDescriptor:)` recebe um fd já
/// em escuta (ativação por launchd): nunca faz `unlink`/`bind`.
// SAFETY: o estado mutável (`closed`) é confinado à fila serial `queue`; `connections` e `path` são imutáveis.
public final class UDSListener: @unchecked Sendable {
    public let path: String?
    public let connections: AsyncStream<UDSConnection>

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "app.racky.uds.listener")
    private let source: any DispatchSourceRead
    private let continuation: AsyncStream<UDSConnection>.Continuation
    private var closed = false

    private init(listenFD: Int32, path: String?) {
        self.listenFD = listenFD
        self.path = path
        (connections, continuation) = AsyncStream<UDSConnection>.makeStream(bufferingPolicy: .unbounded)
        source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [self] in acceptPending() }
        source.setCancelHandler { [self] in
            Darwin.close(listenFD)
            if let path = self.path { unlink(path) }
        }
        continuation.onTermination = { [self] _ in close() }
        source.resume()
    }

    /// Cria o socket em `path` e passa a aceitar conexões.
    public static func listen(path: String, requirePrivateDirectory: Bool = true, backlog: Int32 = 128) async throws -> UDSListener {
        try await UDSSupport.offPool {
            try prepare(path: path, requirePrivateDirectory: requirePrivateDirectory)
            let fd = try UDSSupport.makeSocket()
            do {
                try UDSSupport.withSockaddr(path: path) { address, length in
                    guard bind(fd, address, length) == 0 else { throw UDSError.system(op: "bind", errno: errno) }
                }
                guard chmod(path, 0o600) == 0 else { throw UDSError.system(op: "chmod", errno: errno) }
                guard Darwin.listen(fd, backlog) == 0 else { throw UDSError.system(op: "listen", errno: errno) }
                try UDSSupport.configure(fd, nonBlocking: true)
            } catch {
                Darwin.close(fd)
                unlink(path)
                throw error
            }
            return UDSListener(listenFD: fd, path: path)
        }
    }

    /// Adota um fd de escuta já pronto (launchd). O fd passa a ser fechado por este objeto.
    public static func adopt(fileDescriptor fd: Int32) throws -> UDSListener {
        try UDSSupport.configure(fd, nonBlocking: true)
        return UDSListener(listenFD: fd, path: nil)
    }

    /// Para de aceitar, apaga o arquivo do socket (se foi criado aqui) e encerra `connections`.
    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            continuation.finish()
            source.cancel()
        }
    }

    private func acceptPending() {
        guard !closed else { return }
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }  // EAGAIN (esgotou) ou erro transitório: o GCD avisa de novo
            do {
                try UDSSupport.configure(fd, nonBlocking: true)
            } catch {
                Darwin.close(fd)
                continue
            }
            continuation.yield(UDSConnection(adopting: fd, peer: PeerCredentials.read(from: fd)))
        }
    }

    private static func prepare(path: String, requirePrivateDirectory: Bool) throws {
        guard path.utf8.count <= UDSSupport.maxPathBytes, !path.utf8.contains(0) else {
            throw UDSError.pathTooLong(path.utf8.count)
        }
        if requirePrivateDirectory {
            let directory = (path as NSString).deletingLastPathComponent
            var info = stat()
            guard stat(directory, &info) == 0 else { throw UDSError.system(op: "stat(directory)", errno: errno) }
            guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw UDSError.insecureDirectory(directory) }
        }
        var existing = stat()
        guard lstat(path, &existing) == 0 else { return }
        guard existing.st_mode & S_IFMT == S_IFSOCK else { throw UDSError.pathOccupied(path) }
        // Socket obsoleto: só remove se ninguém atende.
        if let probe = try? UDSSupport.makeSocket() {
            let alive = (try? UDSSupport.withSockaddr(path: path) { address, length in connect(probe, address, length) == 0 }) ?? false
            Darwin.close(probe)
            if alive { throw UDSError.addressInUse(path) }
        }
        unlink(path)
    }
}
