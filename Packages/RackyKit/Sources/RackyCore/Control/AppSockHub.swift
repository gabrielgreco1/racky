import RackyPlatform
import RackyProtocol
import Foundation

/// Um serviço de `app.sock` (08 AR-106: `mcp`, `hook`, `ctl` multiplexados por handshake no primeiro frame).
public protocol AppSockServiceProvider: Sendable {
    var service: AppSockService { get }
    /// `nil` admite a conexão; um erro recusa o handshake (por exemplo `ctl_disabled`).
    func admit() -> CtlError?
    /// Handler de uma conexão já admitida: recebe os frames seguintes ao handshake.
    func makeHandler() -> AppSockServer.Handler
}

/// Dono único de `app.sock`: lê o handshake e entrega a conexão ao serviço escolhido.
public actor AppSockHub {
    private let server: AppSockServer
    public nonisolated let socketPath: String

    public init(socketPath: String, providers: [any AppSockServiceProvider], maxFrame: Int = AppSockFrame.defaultMaxLength) {
        self.socketPath = socketPath
        let table = Dictionary(providers.map { ($0.service, $0) }, uniquingKeysWith: { _, last in last })
        self.server = AppSockServer(path: socketPath, maxFrame: maxFrame) {
            let session = HubSession(providers: table)
            return { frame in await session.receive(frame) }
        }
    }

    public func start() async throws { try await server.start() }
    public func stop() async { await server.stop() }
    public var isRunning: Bool { get async { await server.isRunning } }
}

/// Estado de uma conexão do hub: até o handshake, escolhe o serviço; depois, só encaminha.
actor HubSession {
    private let providers: [AppSockService: any AppSockServiceProvider]
    private var handler: AppSockServer.Handler?

    init(providers: [AppSockService: any AppSockServiceProvider]) { self.providers = providers }

    func receive(_ frame: Data) async -> AppSockReply {
        if let handler { return await handler(frame) }
        func refuse(_ error: CtlError) -> AppSockReply {
            AppSockReply(frames: [(try? CtlCodec.encoder().encode(AppSockHelloReply(ok: false, error: error))) ?? Data()], close: true)
        }
        guard let hello = try? CtlCodec.decoder().decode(AppSockHello.self, from: frame) else {
            return refuse(CtlError(code: "bad_request", message: "invalid handshake"))
        }
        guard let provider = providers[hello.service] else {
            return refuse(CtlError(code: "service_unavailable", message: "service \(hello.service.rawValue) is not available on this socket yet"))
        }
        guard hello.protocolVersion == AppSockHello.currentVersion else {
            return refuse(CtlError(code: "bad_request", message: "unsupported protocol version \(hello.protocolVersion)"))
        }
        if let error = provider.admit() { return refuse(error) }
        handler = provider.makeHandler()
        return AppSockReply(frames: [(try? CtlCodec.encoder().encode(AppSockHelloReply(ok: true))) ?? Data()], close: false)
    }
}

/// Serviço `ctl` no hub (mesma lógica do `CtlServer` isolado; o handshake já foi feito pelo hub).
public struct CtlServiceProvider: AppSockServiceProvider {
    public let service = AppSockService.ctl
    private let dispatcher: any ActionDispatching
    private let isEnabled: @Sendable () -> Bool

    public init(dispatcher: any ActionDispatching, isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.dispatcher = dispatcher
        self.isEnabled = isEnabled
    }

    public func admit() -> CtlError? {
        isEnabled() ? nil : CtlError(
            code: "ctl_disabled",
            message: "automation channel is off (enable it in Settings > Advanced or launch with RACKY_AUTOMATION=1)")
    }

    public func makeHandler() -> AppSockServer.Handler {
        let session = CtlSession(dispatcher: dispatcher, isEnabled: isEnabled, greeted: true)
        return { frame in await session.receive(frame) }
    }
}
