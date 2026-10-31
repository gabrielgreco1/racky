import RackyPlatform
import RackyProtocol
import Foundation

/// Serviço `ctl` de `app.sock` (08 AR-106, AR-806): opt-in, saída sempre JSON, toda chamada vai para o log `ctl`.
public actor CtlServer {
    private let server: AppSockServer
    private let dispatcher: any ActionDispatching
    private let isEnabled: @Sendable () -> Bool
    private let log = LogFacade(.app, category: "ctl")

    public nonisolated let socketPath: String

    /// - Parameters:
    ///   - isEnabled: lido a cada conexão; falso responde `ctl_disabled` (a opção pode ser desligada em runtime).
    public init(
        socketPath: String, dispatcher: any ActionDispatching, isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.socketPath = socketPath
        self.dispatcher = dispatcher
        self.isEnabled = isEnabled
        let session = CtlSessionFactory(dispatcher: dispatcher, isEnabled: isEnabled)
        self.server = AppSockServer(path: socketPath) { session.makeHandler() }
    }

    public func start() async throws {
        try await server.start()
        log.publicInfo("ctl service listening")
    }

    public func stop() async {
        await server.stop()
        log.publicInfo("ctl service stopped")
    }
}

struct CtlSessionFactory: Sendable {
    let dispatcher: any ActionDispatching
    let isEnabled: @Sendable () -> Bool

    func makeHandler() -> AppSockServer.Handler {
        let session = CtlSession(dispatcher: dispatcher, isEnabled: isEnabled)
        return { frame in await session.receive(frame) }
    }
}

/// Estado de uma conexão: primeiro frame = handshake de serviço; depois, requisições `ctl`.
actor CtlSession {
    private let dispatcher: any ActionDispatching
    private let isEnabled: @Sendable () -> Bool
    private var greeted: Bool
    private let log = LogFacade(.app, category: "ctl")

    /// `greeted: true` quando o handshake de serviço já foi feito por outro roteador (`AppSockHub`).
    init(dispatcher: any ActionDispatching, isEnabled: @escaping @Sendable () -> Bool, greeted: Bool = false) {
        self.dispatcher = dispatcher
        self.isEnabled = isEnabled
        self.greeted = greeted
    }

    func receive(_ frame: Data) async -> AppSockReply {
        if !greeted { return handshake(frame) }
        let response: CtlResponse
        do {
            let request = try CtlCodec.decoder().decode(CtlRequest.self, from: frame)
            log.info("ctl \(request.command.rawValue)")
            response = await CtlHandler(dispatcher: dispatcher).handle(request)
        } catch {
            response = .failure(CtlError(code: "bad_request", message: "invalid ctl request: \(error.localizedDescription)"))
        }
        return AppSockReply(frames: [encode(response)], close: !response.ok && response.error?.code == "bad_request")
    }

    private func handshake(_ frame: Data) -> AppSockReply {
        func reply(_ r: AppSockHelloReply, close: Bool) -> AppSockReply {
            AppSockReply(frames: [(try? CtlCodec.encoder().encode(r)) ?? Data()], close: close)
        }
        guard let hello = try? CtlCodec.decoder().decode(AppSockHello.self, from: frame) else {
            return reply(.init(ok: false, error: CtlError(code: "bad_request", message: "invalid handshake")), close: true)
        }
        guard hello.service == .ctl else {
            return reply(
                .init(ok: false, error: CtlError(code: "service_unavailable", message: "service \(hello.service.rawValue) is not available on this socket yet")),
                close: true)
        }
        guard hello.protocolVersion == AppSockHello.currentVersion else {
            return reply(
                .init(ok: false, error: CtlError(code: "bad_request", message: "unsupported protocol version \(hello.protocolVersion)")),
                close: true)
        }
        guard isEnabled() else {
            return reply(
                .init(ok: false, error: CtlError(code: "ctl_disabled", message: "automation channel is off (enable it in Settings > Advanced or launch with RACKY_AUTOMATION=1)")),
                close: true)
        }
        greeted = true
        return reply(.init(ok: true), close: false)
    }

    private func encode(_ response: CtlResponse) -> Data {
        (try? CtlCodec.encoder().encode(response)) ?? Data()
    }
}

/// Traduz comandos `ctl` em chamadas a `ActionDispatching`.
struct CtlHandler: Sendable {
    let dispatcher: any ActionDispatching
    static let defaultWaitTimeoutMs = 5_000
    static let pollInterval = Duration.milliseconds(50)

    func handle(_ req: CtlRequest) async -> CtlResponse {
        switch req.command {
        case .state:
            return CtlResponse(state: await dispatcher.appState())
        case .uiTree:
            let tree = await dispatcher.uiTree(root: req.root)
            if let root = req.root, tree.roots.isEmpty {
                return .failure(CtlError(code: "unknown_target", message: "no element with id \(root.rawValue) on screen"))
            }
            return CtlResponse(tree: tree)
        case .uiAction:
            return await action(req)
        case .uiWait:
            return await wait(req)
        case .screenshot:
            do {
                let target: ScreenshotTarget = req.screenshotElement.map { .element($0) } ?? .window(size: req.size)
                return CtlResponse(screenshot: try await dispatcher.screenshot(target))
            } catch let e as CtlError {
                return .failure(e)
            } catch {
                return .failure(CtlError(code: "screenshot_failed", message: "\(error)"))
            }
        case .recordStart:
            guard let out = req.outPath, !out.isEmpty else {
                return .failure(CtlError(code: "bad_request", message: "record start needs --out <file.mov>"))
            }
            return await record(.start(outPath: out))
        case .recordStop:
            return await record(.stop)
        }
    }

    private func record(_ cmd: RecordingCommand) async -> CtlResponse {
        do {
            return CtlResponse(recording: try await dispatcher.record(cmd))
        } catch let e as CtlError {
            return .failure(e)
        } catch {
            return .failure(CtlError(code: "recording_failed", message: "\(error)"))
        }
    }

    private func action(_ req: CtlRequest) async -> CtlResponse {
        guard let target = req.target, !target.isEmpty else {
            return .failure(CtlError(code: "bad_request", message: "ui action needs an ActionID or an A11yID"))
        }
        let id: ActionID
        var argument = req.argument
        if let direct = ActionID(rawValue: target) {
            id = direct
        } else if let control = A11yID(rawValue: target) {
            guard let bound = await dispatcher.actionID(forControl: control) else {
                return .failure(CtlError(code: "unknown_target", message: "control \(target) is not on screen or has no action"))
            }
            id = bound
            // Sem argumento explícito, o mesmo de um clique de verdade (antes `data.connect.kind.supabase` ia sem o "supabase").
            if argument == nil || argument == .press, let carried = await dispatcher.boundArgument(forControl: control) { argument = carried }
        } else {
            return .failure(CtlError(code: "unknown_target", message: "\(target) is neither an ActionID nor a canonical A11yID"))
        }
        do {
            return CtlResponse(action: try await dispatcher.perform(id, argument))
        } catch let e as ActionError {
            return .failure(Self.map(e))
        } catch {
            return .failure(CtlError(code: "action_failed", message: "\(error)"))
        }
    }

    static func map(_ e: ActionError) -> CtlError {
        switch e {
        case .notRegistered(let id):
            return CtlError(code: "action_not_registered", message: "\(id.rawValue) has no handler registered")
        case .notAvailable(let id, let slice):
            return CtlError(code: "action_unavailable", message: "\(id.rawValue) belongs to a later slice (\(slice)) and is not part of this build")
        case .disabled(let id, let reason):
            return CtlError(code: "action_disabled", message: "\(id.rawValue) is disabled", reason: reason)
        case .failed(let id, let message):
            return CtlError(code: "action_failed", message: "\(id.rawValue): \(message)")
        }
    }

    private func wait(_ req: CtlRequest) async -> CtlResponse {
        guard let element = req.element else {
            return .failure(CtlError(code: "bad_request", message: "ui wait needs an A11yID"))
        }
        let state = req.waitState ?? .appear
        let timeout = req.timeoutMs ?? Self.defaultWaitTimeoutMs
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(timeout))
        while true {
            let node = await dispatcher.uiTree(root: nil).find(element)
            let met: Bool
            switch state {
            case .appear: met = node != nil
            case .gone: met = node == nil
            case .enabled: met = node?.enabled == true
            case .disabled: met = node?.enabled == false
            }
            if met {
                let ms = Int((clock.now - start) / .milliseconds(1))
                return CtlResponse(waited: node, waitedMs: ms)
            }
            if clock.now >= deadline {
                return .failure(CtlError(code: "timeout", message: "\(element.rawValue) did not reach state \(state.rawValue) within \(timeout) ms"))
            }
            do { try await Task.sleep(for: Self.pollInterval) } catch {
                return .failure(CtlError(code: "timeout", message: "cancelled"))
            }
        }
    }
}
