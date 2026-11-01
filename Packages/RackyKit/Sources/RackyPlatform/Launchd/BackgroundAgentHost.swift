import CryptoKit
import Foundation

/// Onde o daemon roda nesta execução (T1-24, 06 §1.2).
public enum DaemonHostMode: Sendable, Equatable {
    /// LaunchAgent registrado e habilitado; o app conecta no socket que o launchd criou.
    case launchAgent(socketPath: String)
    /// Modo atual (daemon filho que sobrevive por reparent): fallback funcional. `reason == nil`: escolhido (testes, automação).
    case childProcess(reason: FallbackReason?)

    public var isLaunchAgent: Bool {
        if case .launchAgent = self { return true }
        return false
    }

    public var fallbackReason: FallbackReason? {
        if case .childProcess(let reason) = self { return reason }
        return nil
    }
}

public enum FallbackReason: Sendable, Equatable {
    /// O plist do LaunchAgent não está no bundle (execução fora do `.app`, `swift run`).
    case notInBundle
    /// Itens de Início aguardando aprovação do dono do Mac. Settings › General mostra "Background agents need approval".
    case requiresApproval
    case registrationFailed(String)
    /// Registrado, mas o launchd não publicou o caminho do socket.
    case socketUnavailable
    /// O socket do launchd existe mas o daemon não respondeu (ex.: `spawn failed`).
    case daemonUnreachable

    /// Texto curto para log e Diagnostics (sem caminhos).
    public var summary: String {
        switch self {
        case .notInBundle: "launch agent plist not in bundle"
        case .requiresApproval: "login item requires approval"
        case .registrationFailed(let message): "registration failed: \(message)"
        case .socketUnavailable: "launchd did not publish the socket path"
        case .daemonUnreachable: "daemon did not answer on the launchd socket"
        }
    }
}

/// Registro persistido: qual binário (o launcher estável `rackyd-launch`) estava registrado. O launchd prende o job ao `cdhash`
/// do `BundleProgram` no momento do registro (S-01): trocar esse binário deixa o job em `spawn failed` até um novo `register()`.
/// O launcher quase nunca muda; as atualizações do `rackyd` não passam por aqui.
struct RegistrationRecord: Codable, Equatable {
    var label: String
    var daemonFingerprint: String
}

/// Orquestra o LaunchAgent do daemon: registra, lê o socket, trata aprovação pendente e re-registra com segurança
/// depois que o binário do daemon muda (nunca derruba um daemon com sessões vivas).
public actor BackgroundAgentHost {
    public let identity: BackgroundAgentIdentity
    private let service: any BackgroundAgentService
    private let launchd: any LaunchdQuerying
    private let bundleURL: URL
    private let daemonExecutable: URL?
    private let stateFile: URL
    private let pointer: PointerConfiguration?
    private let pause: @Sendable (Duration) async -> Void
    private let log = LogFacade(.app, category: "background-agent")

    /// O binário do daemon mudou com o job rodando: re-registrar quando o daemon antigo sair.
    public private(set) var pendingReRegistration = false
    public private(set) var lastMode: DaemonHostMode?

    /// Onde publicar o ponteiro do launcher estável (F30): o `rackyd` deste app e o build dele.
    public struct PointerConfiguration: Sendable {
        public var home: URL
        public var daemonBinary: URL
        public var build: String
        public init(home: URL, daemonBinary: URL, build: String) {
            self.home = home
            self.daemonBinary = daemonBinary
            self.build = build
        }
    }

    /// - Parameters:
    ///   - bundleURL: `Racky.app` (procura o plist em `Contents/Library/LaunchAgents/`).
    ///   - stateFile: onde guardar o registro (`AB/run/ptyd-registration.json`).
    public init(
        identity: BackgroundAgentIdentity, service: any BackgroundAgentService, launchd: any LaunchdQuerying = SystemLaunchd(),
        bundleURL: URL, daemonExecutable: URL?, stateFile: URL, pointer: PointerConfiguration? = nil,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.identity = identity
        self.service = service
        self.launchd = launchd
        self.bundleURL = bundleURL
        self.daemonExecutable = daemonExecutable
        self.stateFile = stateFile
        self.pointer = pointer
        self.pause = pause
    }

    public var status: BackgroundAgentStatus { service.status }

    /// Botão "Allow in Login Items": a UI chama; o spike e os testes nunca.
    public nonisolated func openLoginItemsSettings() { service.openLoginItemsSettings() }

    var plistURL: URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(identity.plistName)")
    }

    // MARK: Preparar

    /// Decide onde o daemon roda e devolve o socket quando é o LaunchAgent. Registra na primeira vez.
    public func prepare() async -> DaemonHostMode {
        let mode = await resolve()
        lastMode = mode
        return mode
    }

    private func resolve() async -> DaemonHostMode {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return .childProcess(reason: .notInBundle) }
        if let pointer { DaemonPointer.update(home: pointer.home, executable: pointer.daemonBinary, build: pointer.build) }
        var status = service.status
        // F30: um daemon vivo (registrado por este ou por outro app, de outra pasta) é adotado como está. Registrar de novo
        // trocaria o job do launchd e derrubaria o daemon com as sessões vivas. Job só carregado (ocioso) não tem sessões: pode re-registrar.
        if status != .enabled, status != .requiresApproval {
            let existing = await launchd.jobState(label: identity.label)
            if existing == .running, let socket = await launchd.socketPath(forKey: identity.socketKey), !socket.isEmpty {
                log.publicInfo("adopting the launch agent registered by another build; not re-registering")
                return .launchAgent(socketPath: socket)
            }
        }
        if status == .notRegistered || status == .notFound {
            if let failure = performRegister() {
                let after = service.status
                if after == .requiresApproval { return .childProcess(reason: .requiresApproval) }
                if after != .enabled { return .childProcess(reason: .registrationFailed(failure)) }
            }
            status = service.status
        }
        if status == .requiresApproval { return .childProcess(reason: .requiresApproval) }
        guard status == .enabled else { return .childProcess(reason: .registrationFailed("status \(status)")) }

        let job = await launchd.jobState(label: identity.label)
        if job == .failed {
            await reRegister()  // spawn failed: o binário não bate com o registro; o job não está rodando, é seguro
        } else if fingerprintMismatch() {
            if job == .running {
                pendingReRegistration = true  // o daemon antigo (com sessões) continua; re-registra depois que ele sair
                log.publicInfo("daemon binary changed; re-registration deferred until the running daemon exits")
            } else {
                await reRegister()
            }
        }
        guard let socket = await waitForSocketPath() else { return .childProcess(reason: .socketUnavailable) }
        return .launchAgent(socketPath: socket)
    }

    // MARK: Recuperar

    /// Chamado quando o cliente perdeu o daemon: se o binário mudou e o job não roda mais, re-registra (o launchd não
    /// conseguiria subir o binário novo) e devolve o caminho vigente do socket.
    public func recover() async -> DaemonHostMode {
        guard service.status == .enabled else { return await prepare() }
        let job = await launchd.jobState(label: identity.label)
        if job != .running, job == .failed || pendingReRegistration || fingerprintMismatch() {
            await reRegister()
        }
        guard let socket = await waitForSocketPath() else {
            lastMode = .childProcess(reason: .socketUnavailable)
            return .childProcess(reason: .socketUnavailable)
        }
        lastMode = .launchAgent(socketPath: socket)
        return .launchAgent(socketPath: socket)
    }

    /// Remove o registro (limpeza de testes). Encerra o job; só chamar sem sessões vivas.
    public func unregister() {
        try? service.unregister()
        try? FileManager.default.removeItem(at: stateFile)
        pendingReRegistration = false
    }

    // MARK: Registro

    /// `nil` = ok; senão a mensagem do erro.
    private func performRegister() -> String? {
        do {
            try service.register()
            recordFingerprint()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// `unregister` + `register`. O `register` logo depois de um `unregister` ainda em andamento não faz nada (o BTM mantém o
    /// registro antigo e o LWCR com o cdhash velho; visto no e2e da T1-24), então espera o launchd esquecer o job antes.
    private func reRegister() async {
        log.publicInfo("re-registering background agent for the new daemon binary")
        try? service.unregister()
        for _ in 0 ..< 40 {
            let gone = service.status != .enabled
            if gone, await launchd.jobState(label: identity.label) == .notLoaded { break }
            await pause(.milliseconds(100))
        }
        _ = performRegister()
        pendingReRegistration = false
    }

    private func waitForSocketPath() async -> String? {
        for attempt in 0 ..< 20 {
            if let path = await launchd.socketPath(forKey: identity.socketKey), !path.isEmpty { return path }
            if attempt < 19 { await pause(.milliseconds(100)) }
        }
        return nil
    }

    // MARK: Fingerprint do daemon

    func currentFingerprint() -> String? {
        guard let daemonExecutable, let handle = try? FileHandle(forReadingFrom: daemonExecutable) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func recordedFingerprint() -> String? {
        guard let data = try? Data(contentsOf: stateFile), let record = try? JSONDecoder().decode(RegistrationRecord.self, from: data),
            record.label == identity.label
        else { return nil }
        return record.daemonFingerprint
    }

    private func recordFingerprint() {
        guard let fingerprint = currentFingerprint() else { return }
        let record = RegistrationRecord(label: identity.label, daemonFingerprint: fingerprint)
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: stateFile, options: .atomic) }
    }

    /// Sem fingerprint do binário (não deu para ler) não força re-registro.
    private func fingerprintMismatch() -> Bool {
        guard let current = currentFingerprint() else { return false }
        return recordedFingerprint() != current
    }
}
