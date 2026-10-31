import RackyDocker
import RackyPlatform
import Foundation

// F12 item 4: a primeira vez sem imagens Docker o app constrói (ou baixa) a imagem única do computador em segundo plano,
// mostrando o progresso na linha do computador; Docker parado vira um erro claro com "Open Docker". 07 §2.3 (CS-120, CS-121).

public enum ComputerSetupError: Error, LocalizedError, Equatable, Sendable {
    case dockerNotRunning
    case runtimeFilesMissing(String)
    /// `runOn == .cloud` sem um provedor implementado (BK-12): o computador falha, não cai para o Mac.
    case cloudUnavailable
    /// O runtime nativo (sem Docker) foi escolhido mas não pôde preparar/subir (download, imagem, entitlement...). O texto é a causa.
    case nativeRuntime(String)

    public static let cloudUnavailableMessage = "Cloud computers aren't available yet. Switch to This Mac in Computers."

    /// Prefixo estável: a UI mostra o botão "Open Docker" quando o detalhe do computador começa por ele.
    public static let dockerNotRunningMessage = "Docker isn't running"

    public var errorDescription: String? {
        switch self {
        case .dockerNotRunning: "\(Self.dockerNotRunningMessage). Open Docker, then reserve the computer again."
        case .runtimeFilesMissing(let path): "The computer image files are missing (\(path))."
        case .cloudUnavailable: Self.cloudUnavailableMessage
        case .nativeRuntime(let detail): "The computer runtime isn't ready: \(detail)"
        }
    }
}

/// Onde estão os contextos de build (`computer/`): `RACKY_RUNTIME_ROOT`, o checkout (`RACKY_REPO_ROOT`, dev) ou o bundle.
public enum RuntimeContextLocator {
    public static func root(environment: [String: String], bundleURL: URL) -> URL? {
        var candidates: [URL] = []
        if let value = environment["RACKY_RUNTIME_ROOT"], !value.isEmpty { candidates.append(URL(fileURLWithPath: value, isDirectory: true)) }
        if let value = environment["RACKY_REPO_ROOT"], !value.isEmpty {
            candidates.append(URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent("runtime", isDirectory: true))
        }
        candidates.append(bundleURL.appendingPathComponent("Contents/Resources/runtime", isDirectory: true))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("computer/Dockerfile").path) }
    }
}

/// Estado do preparo das imagens, para a linha do computador.
public enum ComputerSetupState: Sendable, Equatable {
    case idle
    case building(image: String, step: Int, of: Int)
    case pulling(image: String, done: Int, of: Int)
    /// Runtime nativo: baixando kernel/vminit/imagem do computador (bytes feitos de total; `total == 0` = tamanho desconhecido).
    case downloading(done: Int64, total: Int64)
    /// Runtime nativo: importando e desempacotando a imagem (uma vez por imagem).
    case preparing
    case ready
    case failed(String)

    /// `"Building computer image… 3 of 14"` enquanto trabalha; `nil` parado, pronto ou com erro.
    public var label: String? {
        switch self {
        case .building(let image, let step, let total): total > 0 ? "Building \(image) image… \(step) of \(total)" : "Building \(image) image…"
        case .pulling(let image, let done, let total): total > 0 ? "Downloading \(image) image… \(done) of \(total)" : "Downloading \(image) image…"
        case .downloading(let done, let total):
            total > 0 ? "Downloading the computer runtime (\(done >> 20) of \(total >> 20) MB)…" : "Downloading the computer runtime (\(done >> 20) MB)…"
        case .preparing: "Preparing the computer runtime…"
        case .idle, .ready, .failed: nil
        }
    }
}

public actor AppComputerProvisioning: ComputerProvisioning {
    public struct Config: Sendable {
        public var runtimeRoot: URL?
        public var secretsRoot: URL
        public var owner: String
        /// Sufixo do repositório das imagens (testes: `-test-<id>`).
        public var repositorySuffix = ""
        public var extraLabels: [String: String] = [:]
        public var isTest = false
        public var network = ComputerProvisioner.defaultNetwork
        public var allowCIDRs: [String] = []
        public var resolver: ProxyConfigResolver?
        /// Troca a detecção do runtime (testes que já têm o cliente).
        public var client: DockerClient?
        /// Runtime sem Docker (`RackyVZ`), quando o app o linka. `nil` = só Docker, como antes.
        public var native: (any NativeComputerRuntime)?
        /// Settings › Computers › "Use Docker instead": força o Docker mesmo onde o runtime nativo serviria.
        public var forceDocker: @Sendable () async -> Bool = { false }
        /// Settings › General › Storage › Old computer images: com a imagem nova pronta, as tags antigas do mesmo repositório saem.
        public var removeOldImages: @Sendable () async -> Bool = { false }

        public init(runtimeRoot: URL?, secretsRoot: URL, owner: String) {
            self.runtimeRoot = runtimeRoot; self.secretsRoot = secretsRoot; self.owner = owner
        }
    }

    private var config: Config
    private var cachedClient: DockerClient?
    private var imageTask: Task<String, Error>?
    public private(set) var state: ComputerSetupState = .idle
    private var observer: (@Sendable (ComputerSetupState) -> Void)?
    private var problem: (@Sendable (ComputerSetupError) -> Void)?
    /// Rota de nuvem (BK-12). `nil` = só Mac, como sempre.
    private var cloudRoute: CloudComputerRoute?

    public init(config: Config) {
        self.config = config
        self.cachedClient = config.client
    }

    public func setObserver(state: (@Sendable (ComputerSetupState) -> Void)?, problem: (@Sendable (ComputerSetupError) -> Void)?) {
        observer = state
        self.problem = problem
        state?(self.state)
    }

    public func setCloudRoute(_ route: CloudComputerRoute?) { cloudRoute = route }

    /// O runtime nativo quando ele existe, serve a este Mac e o usuário não forçou o Docker; `nil` = Docker.
    private func nativeTarget() async -> (any NativeComputerRuntime)? {
        guard let native = config.native else { return nil }
        let choice = RuntimeSelector.choose(
            appleSilicon: RuntimeSelector.isAppleSilicon, forceDocker: await config.forceDocker(), nativeLinked: native.unavailableReason == nil)
        return choice == .native ? native : nil
    }

    /// Qual runtime sobe o próximo computador (Settings mostra; os testes conferem).
    public func activeRuntime() async -> ComputerRuntimeChoice { await nativeTarget() == nil ? .docker : .native }

    /// Fim do app: para as VMs do runtime nativo. Sem runtime nativo não faz nada (os contêineres do Docker seguem vivos).
    public func shutdownNative() async { await config.native?.shutdown() }

    /// A rota de nuvem quando a setting pede nuvem; `nil` = caminho local (nada abaixo muda).
    private func cloudTarget() async -> (any ComputerProvisioning)? {
        guard let route = cloudRoute, await route.place() == .cloud else { return nil }
        return route.effective
    }

    private func set(_ new: ComputerSetupState) {
        guard new != state else { return }
        state = new
        observer?(new)
    }

    // MARK: Docker

    private func client() async throws -> DockerClient {
        if let cachedClient { return cachedClient }
        do {
            let detected = try await RuntimeDetector().detect()
            let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
            cachedClient = client
            return client
        } catch {
            throw ComputerSetupError.dockerNotRunning
        }
    }

    public func preflight() async throws {
        if let cloud = await cloudTarget() {
            do { try await cloud.preflight() } catch {
                if let setup = error as? ComputerSetupError { problem?(setup) }
                throw error
            }
            return
        }
        if let native = await nativeTarget() {
            // Só confere que o Mac serve; o download acontece no primeiro `provision` (com progresso na linha do computador).
            if let reason = native.unavailableReason {
                let error = ComputerSetupError.nativeRuntime(reason)
                problem?(error)
                throw error
            }
            return
        }
        do {
            try await client().ping()
        } catch {
            cachedClient = config.client
            problem?(.dockerNotRunning)
            throw ComputerSetupError.dockerNotRunning
        }
    }

    /// `M` e CPUs da VM; sem Docker, 8 GB (a admissão não trava, o preflight já avisou).
    public func vmCapacity() async -> VMCapacity {
        // Nuvem: a admissão é do pool (capacidade do host e `maxComputers`); a memória do Mac não conta, o scheduler não a limita.
        if await cloudTarget() != nil { return VMCapacity(memTotalBytes: 1 << 50, cpuCount: 1024) }
        if let native = await nativeTarget() { return await native.vmCapacity() }
        if let client = try? await client(), let info = try? await client.info() { return VMCapacity(memTotalBytes: info.memTotal, cpuCount: info.cpuCount) }
        return VMCapacity(memTotalBytes: 8 << 30, cpuCount: 4)
    }

    // MARK: Imagens

    /// Garante a imagem uma vez para todos os computadores que estão subindo (a primeira vez constrói; as seguintes só conferem).
    public func ensureImages() async throws -> String {
        if let imageTask { return try await imageTask.value }
        guard let root = config.runtimeRoot else {
            let error = ComputerSetupError.runtimeFilesMissing("runtime/computer")
            set(.failed(error.localizedDescription))
            throw error
        }
        let client = try await client()
        let config = config
        let owner = self
        let task = Task<String, Error> {
            let manager = ImageManager(client: client)
            let source = ImageSource(
                repository: "racky-computer\(config.repositorySuffix)", contextDirectory: root.appendingPathComponent("computer", isDirectory: true),
                extraLabels: config.extraLabels)
            let ensured = try await manager.ensure(source) { progress in
                switch progress {
                case .building(let step, let total): Task { await owner.set(.building(image: "computer", step: step, of: total)) }
                case .pulling(let done, let total, _): Task { await owner.set(.pulling(image: "computer", done: done, of: total)) }
                case .log: break
                }
            }
            if await config.removeOldImages() {
                await manager.removeOtherTags(repository: source.repository, keeping: ensured.tag)
            }
            return ensured.tag
        }
        imageTask = task
        do {
            let tag = try await task.value
            set(.ready)
            return tag
        } catch {
            imageTask = nil
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            set(.failed(text))
            throw error
        }
    }

    // MARK: ComputerProvisioning

    public func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        if let cloud = await cloudTarget() { return try await cloud.provision(spec) }
        observer?(state)
        if let native = await nativeTarget() { return try await provisionNative(native, spec) }
        let tag = try await ensureImages()
        let client = try await client()
        let inner = DockerComputerProvisioning(
            client: client, image: tag, secrets: BoxSecretFiles(root: config.secretsRoot), owner: config.owner,
            network: config.network, allowCIDRs: config.allowCIDRs, extraLabels: config.extraLabels, isTest: config.isTest,
            resolver: config.resolver)
        return try await inner.provision(spec)
    }

    /// Runtime nativo: prepara (baixa/desempacota uma vez, com o progresso na linha do computador) e sobe a VM.
    private func provisionNative(_ native: any NativeComputerRuntime, _ spec: ComputerSpec) async throws -> ProvisionedHandle {
        let owner = self
        do {
            try await native.ensureReady { progress in Task { await owner.set(progress) } }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            set(.failed(text))
            let wrapped = ComputerSetupError.nativeRuntime(text)
            problem?(wrapped)
            throw wrapped
        }
        set(.ready)
        return try await native.provision(spec)
    }

    /// Adoção ao abrir o app: só olha o Docker se ele já estiver de pé (nada de aviso "Docker isn't running" nem de abrir o Docker).
    /// Com o runtime nativo ativo, as VMs de uma sessão anterior já não existem: a lista é vazia (não `nil`), e o scheduler marca como
    /// removidos os computadores que o Store ainda dava como vivos. Contêineres do Docker de antes continuam adotáveis se o Docker responde.
    public func liveComputers() async -> [LiveComputer]? {
        if await cloudTarget() != nil { return nil }  // adoção de computadores em hosts remotos: BK-12 fase seguinte
        let native = await nativeTarget() != nil
        guard let client = try? await client() else { return native ? [] : nil }
        return await dockerProvisioning(client: client, image: "").liveComputers() ?? (native ? [] : nil)
    }

    public func adopt(_ live: LiveComputer, spec: ComputerSpec) async throws -> AdoptedComputer {
        try await dockerProvisioning(client: try await client(), image: "").adopt(live, spec: spec)
    }

    private func dockerProvisioning(client: DockerClient, image: String) -> DockerComputerProvisioning {
        DockerComputerProvisioning(
            client: client, image: image, secrets: BoxSecretFiles(root: config.secretsRoot), owner: config.owner, network: config.network,
            allowCIDRs: config.allowCIDRs, extraLabels: config.extraLabels, isTest: config.isTest, resolver: config.resolver)
    }
}
