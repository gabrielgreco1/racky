import RackyProtocol
import Darwin
import Foundation

/// Entrega síncrona de um evento ao serviço `hook` de `app.sock` com prazo total (06 §3.2: 200 ms).
/// Tudo (connect, escrita, espera da resposta) obedece ao mesmo prazo monotônico via `poll(2)`; nunca bloqueia além dele.
public enum HookTransport {
    public enum Outcome: Sendable, Equatable {
        case delivered(duplicate: Bool)
        /// O app respondeu, mas recusou (serviço indisponível, erro ao gravar). O chamador grava no spool.
        case rejected(String)
        /// Sem socket, sem resposta no prazo ou erro de transporte. O chamador grava no spool.
        case unavailable(String)

        public var isDelivered: Bool { if case .delivered = self { true } else { false } }
    }

    public static func monotonicNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
    public static func realtimeNs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_REALTIME)) }

    /// - Parameter envelope: JSON de um `HookEnvelope` (sem framing).
    public static func deliver(_ envelope: Data, socketPath: String, timeoutMs: Int = HookLimits.deliveryTimeoutMs) -> Outcome {
        let deadline = monotonicNs() + UInt64(max(1, timeoutMs)) * 1_000_000
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable("socket: errno \(errno)") }
        defer { close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return .unavailable("fcntl: errno \(errno)") }

        var addr: sockaddr_un
        do { addr = try makeSockAddr(socketPath) } catch { return .unavailable("socket path unusable") }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return .unavailable("connect: errno \(errno)") }
            guard wait(fd, Int16(POLLOUT), deadline: deadline) else { return .unavailable("connect timed out") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return .unavailable("connect: errno \(err)") }
        }

        // Handshake de serviço e evento seguem juntos; o servidor processa os frames em série.
        let encoder = HookCodec.encoder()
        guard let hello = try? encoder.encode(AppSockHello(service: .hook)) else { return .unavailable("encode hello") }
        var out = AppSockFrame.encode(hello)
        out.append(AppSockFrame.encode(envelope))
        guard send(fd, out, deadline: deadline) else { return .unavailable("send timed out") }

        var decoder = AppSockFrameDecoder(maxLength: 1 << 20)
        guard let helloFrame = receiveFrame(fd, &decoder, deadline: deadline) else { return .unavailable("no handshake reply in time") }
        guard let helloReply = try? JSONDecoder().decode(AppSockHelloReply.self, from: helloFrame) else { return .unavailable("bad handshake reply") }
        guard helloReply.ok else { return .rejected(helloReply.error?.message ?? "handshake refused") }
        guard let ackFrame = receiveFrame(fd, &decoder, deadline: deadline) else { return .unavailable("no ack in time") }
        guard let ack = try? JSONDecoder().decode(HookAck.self, from: ackFrame) else { return .unavailable("bad ack") }
        return ack.ok ? .delivered(duplicate: ack.duplicate) : .rejected(ack.error ?? "app refused the event")
    }

    // MARK: - poll

    private static func wait(_ fd: Int32, _ events: Int16, deadline: UInt64) -> Bool {
        while true {
            let now = monotonicNs()
            guard now < deadline else { return false }
            let ms = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
            var p = pollfd(fd: fd, events: events, revents: 0)
            let rc = poll(&p, 1, ms)
            if rc > 0 { return true }
            if rc == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    private static func send(_ fd: Int32, _ data: Data, deadline: UInt64) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard wait(fd, Int16(POLLOUT), deadline: deadline) else { return false }
                    continue
                }
                return false
            }
            return true
        }
    }

    private static func receiveFrame(_ fd: Int32, _ decoder: inout AppSockFrameDecoder, deadline: UInt64) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let frame = try? decoder.next() { return frame }
            guard wait(fd, Int16(POLLIN), deadline: deadline) else { return nil }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { decoder.append(Data(buffer[0..<n])); continue }
            if n == 0 { return nil }  // EOF sem resposta
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            return nil
        }
    }
}
