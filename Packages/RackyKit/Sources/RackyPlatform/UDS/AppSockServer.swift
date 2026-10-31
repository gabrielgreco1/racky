import RackyProtocol
import Darwin
import Foundation

/// Resposta de um handler de conexão: zero ou mais frames e se a conexão deve fechar depois.
public struct AppSockReply: Sendable {
    public var frames: [Data]
    public var close: Bool
    public init(frames: [Data] = [], close: Bool = false) {
        self.frames = frames
        self.close = close
    }
}

/// Servidor do canal de controle (app.sock) (`0600`, só o mesmo usuário via `getpeereid`) com framing `u32 len | payload`.
/// Cada conexão tem um handler próprio (estado de handshake) e processa seus frames em série;
/// conexões distintas rodam em paralelo, cada chamada numa `Task` cancelável (AR-106, sem semáforo).
public actor AppSockServer {
    public typealias Handler = @Sendable (Data) async -> AppSockReply

    public let path: String
    private let maxFrame: Int
    private let makeHandler: @Sendable () -> Handler
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var connections: [Int: Task<Void, Never>] = [:]
    private var nextConnectionID = 0

    public init(path: String, maxFrame: Int = AppSockFrame.defaultMaxLength, makeHandler: @escaping @Sendable () -> Handler) {
        self.path = path
        self.maxFrame = maxFrame
        self.makeHandler = makeHandler
    }

    public var isRunning: Bool { listenFD >= 0 }

    public func start() throws {
        guard listenFD < 0 else { return }
        if AppSockClient.isListening(path: path) { throw AppSockError.alreadyRunning(path) }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        var addr = try makeSockAddr(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppSockError.syscall("socket", errno) }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw AppSockError.syscall("bind", e)
        }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let e = errno
            Darwin.close(fd)
            unlink(path)
            throw AppSockError.syscall("listen", e)
        }
        do { try setNonBlocking(fd) } catch {
            Darwin.close(fd)
            unlink(path)
            throw error
        }
        listenFD = fd
        acceptTask = Task { [weak self] in await self?.acceptLoop(fd: fd) }
    }

    public func stop() async {
        guard listenFD >= 0 else { return }
        let task = acceptTask
        let conns = Array(connections.values)
        acceptTask = nil
        connections = [:]
        task?.cancel()
        conns.forEach { $0.cancel() }
        await task?.value
        for c in conns { await c.value }
        Darwin.close(listenFD)
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop(fd: Int32) async {
        while !Task.isCancelled {
            do { try await awaitReady(fd: fd, writable: false) } catch { return }
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    // Sem fds (EMFILE/ENFILE) o socket continua "pronto": sem espera isto gira a 100% de CPU.
                    if errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM { try? await Task.sleep(for: .milliseconds(200)) }
                    break
                }
                admit(client)
            }
        }
    }

    private func admit(_ client: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(), (try? setNonBlocking(client)) != nil else {
            Darwin.close(client)
            return
        }
        let id = nextConnectionID
        nextConnectionID += 1
        let handler = makeHandler()
        let max = maxFrame
        connections[id] = Task { [weak self] in
            await AppSockServer.serve(fd: client, maxFrame: max, handler: handler)
            await self?.finished(id)
        }
    }

    private func finished(_ id: Int) { connections[id] = nil }

    private static func serve(fd: Int32, maxFrame: Int, handler: Handler) async {
        defer { Darwin.close(fd) }
        var decoder = AppSockFrameDecoder(maxLength: maxFrame)
        do {
            while !Task.isCancelled {
                let chunk = try await readSome(fd: fd)
                if chunk.isEmpty { return }
                decoder.append(chunk)
                while let frame = try decoder.next() {
                    let reply = await handler(frame)
                    for out in reply.frames { try await writeAll(fd: fd, AppSockFrame.encode(out)) }
                    if reply.close { return }
                }
            }
        } catch {
            return
        }
    }
}
