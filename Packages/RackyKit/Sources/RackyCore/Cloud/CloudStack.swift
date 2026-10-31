import RackyDocker
import RackyPlatform
import Foundation

// BK12-T10/T11 no app: as peças da nuvem montadas de verdade. Chaves SSH da instalação, o conector que abre o túnel e prepara a imagem
// no host, a colocação que segue a região escolhida e o `CloudStack`, que o app liga e a tela lê (hosts vivos, gasto, conexão).

/// Chaves desta instalação (pasta 0700, arquivos 0600): a do cliente (entra no `authorized_keys` do usuário `racky`) e a do host
/// (o app a entrega por cloud-init e fixa o `known_hosts` antes do boot: nada de "trust on first use").
public struct CloudKeys: Sendable {
    public var clientPrivateKey: URL
    public var clientPublicKey: String
    public var hostKey: CloudInit.HostKey

    public static func load(in directory: URL) async throws -> CloudKeys {
        let fm = FileManager.default
        let client = directory.appendingPathComponent("client_ed25519")
        let host = directory.appendingPathComponent("host_ed25519")
        if !fm.fileExists(atPath: client.path) { _ = try await SSHKeyPair.generate(in: directory, name: "client_ed25519", comment: "racky-client") }
        if !fm.fileExists(atPath: host.path) { _ = try await SSHKeyPair.generate(in: directory, name: "host_ed25519", comment: "racky-host") }
        chmod(directory.path, 0o700)
        func publicKey(_ url: URL) throws -> String {
            let fields = try String(contentsOfFile: url.path + ".pub", encoding: .utf8).split(separator: " ")
            guard fields.count >= 2 else { throw SSHConfigError.invalidField("chave pública") }
            return "\(fields[0]) \(fields[1])"
        }
        return CloudKeys(
            clientPrivateKey: client, clientPublicKey: try publicKey(client),
            hostKey: CloudInit.HostKey(privateKey: try String(contentsOf: host, encoding: .utf8), publicKey: try publicKey(host)))
    }

    public var access: CloudHostManager.Access { CloudHostManager.Access(authorizedKey: clientPublicKey, hostKey: hostKey) }

    /// Tag `racky:owner`: uma por instalação, guardada em `root/install-id` (dois Macs na mesma conta não encerram os hosts um do outro).
    public static func installOwner(in root: URL, base: String) -> String {
        let file = root.appendingPathComponent("install-id")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty { return saved }
        let id = "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: file, options: .atomic)
        return id
    }
}

/// Acesso a um host remoto que já tem a imagem do computador (a tag vale só para este host).
public struct ImagedHostAccess: ComputerHostAccess {
    public let inner: RemoteHostAccess
    public let imageTag: String
    public var host: ComputerHost { inner.host }
    public var client: DockerClient { inner.client }
    public var storage: ComputerStorage { inner.storage }
    public func reach(publishedPort: Int, computerID: String) async throws -> Int { try await inner.reach(publishedPort: publishedPort, computerID: computerID) }
    public func releaseForwards(computerID: String) async { await inner.releaseForwards(computerID: computerID) }
}

/// Fase do host em subida, para a linha do computador ("Starting a computer in AWS…").
public enum CloudHostProgress: Sendable, Equatable {
    case waitingForSSH
    case buildingImage(step: Int, of: Int)
    case ready
}

/// O conector real (`HostConnecting`): espera o SSH e o Docker do host responderem (boot + cloud-init levam 1-3 min), abre o
/// `SSHTunnel` e constrói a imagem do computador NO host (mesma arquitetura arm64 do Mac). Um túnel por host.
public actor SSHHostConnector: HostConnecting {
    private let keys: CloudKeys
    private let runtimeRoot: URL?
    private let progress: @Sendable (String, CloudHostProgress) -> Void
    private var tunnels: [String: SSHTunnel] = [:]
    private let runner = ProcessTunnelRunner()

    public init(keys: CloudKeys, runtimeRoot: URL?, progress: @escaping @Sendable (String, CloudHostProgress) -> Void = { _, _ in }) {
        self.keys = keys; self.runtimeRoot = runtimeRoot; self.progress = progress
    }

    public func tunnel(_ hostID: String) -> SSHTunnel? { tunnels[hostID] }

    public func connect(_ host: PlacedHost) async throws -> any ComputerHostAccess {
        guard let address = host.address else { throw CloudError.provider("The cloud computer has no public address yet.") }
        guard let runtimeRoot else { throw ComputerSetupError.runtimeFilesMissing("runtime/computer") }
        // Caminho curto: socket Unix tem teto de ~104 bytes.
        let short = String(host.id.suffix(10)).filter { $0.isLetter || $0.isNumber }
        let dir = URL(fileURLWithPath: "/tmp/racky-\(getuid())-\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let knownHosts = try KnownHosts.write(host: address, publicKey: keys.hostKey.publicKey, to: dir.appendingPathComponent("known_hosts"))
        let endpoint = SSHEndpoint(user: CloudInit.user, host: address, identityFile: keys.clientPrivateKey, knownHostsFile: knownHosts)
        progress(host.id, .waitingForSSH)
        try await waitForDocker(endpoint)
        let tunnel = try SSHTunnel(endpoint: endpoint, directory: dir, runner: runner, readyTimeout: .seconds(60))
        do { try await tunnel.start() } catch {
            await tunnel.stop()  // senão o supervisor do túnel respawna o ssh para sempre
            throw error
        }
        await tunnels.removeValue(forKey: host.id)?.stop()  // nunca deixa um túnel anterior órfão
        tunnels[host.id] = tunnel
        let remote = RemoteHostAccess(
            remote: RemoteHost(id: host.id, provider: "aws", region: host.region, address: address, sshUser: CloudInit.user), tunnel: tunnel)
        let hostID = host.id
        let report = progress
        let ensured: EnsuredImage
        do {
            ensured = try await ImageManager(client: tunnel.client).ensure(
                ImageSource(repository: "racky-computer", contextDirectory: runtimeRoot.appendingPathComponent("computer", isDirectory: true))
            ) { event in
                if case .building(let step, let total) = event { report(hostID, .buildingImage(step: step, of: total)) }
            }
        } catch {
            tunnels.removeValue(forKey: host.id)
            await tunnel.stop()
            throw error
        }
        progress(host.id, .ready)
        return ImagedHostAccess(inner: remote, imageTag: ensured.tag)
    }

    public func disconnect(hostID: String) async {
        await tunnels.removeValue(forKey: hostID)?.stop()
    }

    /// `ssh racky@host 'docker info'` até responder (até ~6 min: boot, cloud-init instala o Docker).
    private func waitForDocker(_ endpoint: SSHEndpoint) async throws {
        let args = [
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(endpoint.knownHostsFile.path)",
            "-o", "IdentitiesOnly=yes", "-i", endpoint.identityFile.path, "-o", "ConnectTimeout=8", "-p", "\(endpoint.port)",
            "\(endpoint.user)@\(endpoint.host)", "--", "docker info --format '{{.ServerVersion}}'",
        ]
        var last = ""
        for _ in 0 ..< 45 {
            let result = try await runner.run(args, timeout: .seconds(20))
            if result.status == 0 { return }
            last = result.stderr
            try await Task.sleep(for: .seconds(8))
        }
        throw CloudError.provider("The cloud computer didn't answer over SSH: \(last.suffix(200))")
    }
}

/// Colocação que segue a região escolhida AGORA: um `ComputerHostPool` por região (trocar a região vale para o próximo computador;
/// os que já rodam ficam no host deles até terminar).
public actor RegionalHostPlacement: HostPlacement {
    private let manager: CloudHostManager
    private let access: CloudHostManager.Access
    private let settings: @Sendable () async -> (region: String, maxComputers: Int)
    private let idleGrace: Duration
    private let onHostClosed: @Sendable (String) async -> Void
    private var pools: [String: ComputerHostPool] = [:]
    private var placedIn: [String: String] = [:]  // computador -> região

    public init(
        manager: CloudHostManager, access: CloudHostManager.Access, idleGrace: Duration,
        settings: @escaping @Sendable () async -> (region: String, maxComputers: Int), onHostClosed: @escaping @Sendable (String) async -> Void
    ) {
        self.manager = manager; self.access = access; self.idleGrace = idleGrace; self.settings = settings; self.onHostClosed = onHostClosed
    }

    private func pool(_ region: String, maxComputers: Int) async -> ComputerHostPool {
        if let pool = pools[region] {
            await pool.update(maxComputers: maxComputers)
            return pool
        }
        let pool = ComputerHostPool(
            manager: manager, region: region, shape: AWSProvider.shape(forComputers: maxComputers), access: access, maxComputers: maxComputers,
            idleGrace: idleGrace, onHostClosed: onHostClosed)
        pools[region] = pool
        return pool
    }

    public func acquire(computerID: String) async throws -> PlacedHost {
        let current = await settings()
        let pool = await pool(current.region, maxComputers: current.maxComputers)
        let placed = try await pool.acquire(computerID: computerID)
        placedIn[computerID] = current.region
        return placed
    }

    public func release(computerID: String) async {
        guard let region = placedIn.removeValue(forKey: computerID) else { return }
        await pools[region]?.release(computerID: computerID)
    }

    public func sweepIdle() async { for pool in pools.values { await pool.sweepIdle() } }
    public func closeAll() async { for pool in pools.values { await pool.closeAll() } }
}

/// O que a tela Computers mostra da nuvem.
public struct CloudSnapshot: Sendable, Equatable {
    public struct Host: Sendable, Equatable, Identifiable {
        public var id: String
        public var region: String
        public var shape: String
        public var startedAt: Date
        public var hourlyUSD: Double
        public var computers: Int
    }
    public var hosts: [Host] = []
    public var records: [SpendRecord] = []
    public var todayUSD: Double = 0
    public var monthUSD: Double = 0
    public var lastReaperError: String?
    public init() {}
}

/// A nuvem montada: gerente (teto de gasto, livro-caixa em arquivo), colocação por região, conector SSH e supervisor (heartbeat da
/// chave morta, reaper por tag a cada 10 min, hosts ociosos). Um por app; o provedor é a AWS pelo CLI.
public actor CloudStack {
    public let cli: AWSCLI
    public let manager: CloudHostManager
    public let placement: RegionalHostPlacement
    public let connector: SSHHostConnector
    public let provisioning: CloudComputerProvisioning
    private var supervisor: CloudHostSupervisor?
    private var starting = false
    private let regions: @Sendable () async -> [String]
    private let calendar: Calendar

    /// `owner`: installId (tag `racky:owner`). `root`: `…/Racky/cloud` (chaves e livro-caixa). `make`: provisionador de um host.
    public init(
        cli: AWSCLI, owner: String, root: URL, keys: CloudKeys, runtimeRoot: URL?, caps: SpendCaps, idleGrace: Duration = .seconds(300),
        settings: @escaping @Sendable () async -> (region: String, maxComputers: Int), regions: @escaping @Sendable () async -> [String],
        acceptedAUP: @escaping @Sendable (CloudProviderID, String) async -> Bool,
        progress: @escaping @Sendable (String, CloudHostProgress) -> Void = { _, _ in },
        make: @escaping @Sendable (any ComputerHostAccess) -> any ComputerProvisioning
    ) {
        self.cli = cli
        self.regions = regions
        self.calendar = .current
        let manager = CloudHostManager(
            provider: AWSProvider(cli: cli),
            settings: CloudHostManager.Settings(owner: owner, caps: caps, policy: DeadManPolicy(idleShutdown: .seconds(900))),
            ledgerStore: FileSpendLedgerStore(url: root.appendingPathComponent("spend.json")), acceptedAUP: acceptedAUP)
        self.manager = manager
        let connector = SSHHostConnector(keys: keys, runtimeRoot: runtimeRoot, progress: progress)
        self.connector = connector
        let holder = ProvisioningHolder()
        let placement = RegionalHostPlacement(
            manager: manager, access: keys.access, idleGrace: idleGrace, settings: settings,
            onHostClosed: { id in await holder.value?.hostClosed(id) })
        self.placement = placement
        let provisioning = CloudComputerProvisioning(
            placement: placement, connector: connector, preflight: { _ = try await cli.identity() }, make: make)
        self.provisioning = provisioning
        Task { await holder.set(provisioning) }
    }

    /// Liga o supervisor (readota hosts vivos pelas tags, heartbeat, reaper). Só com sessão válida na AWS.
    public func start() async {
        // Reserva o lugar ANTES de qualquer await: duas chamadas simultâneas não criam dois supervisores.
        guard supervisor == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let connector = connector
        let supervisor = CloudHostSupervisor(
            manager: manager, sender: TunnelHeartbeatSender(tunnel: { id in await connector.tunnel(id) }), regions: await regions())
        self.supervisor = supervisor
        await supervisor.start()
    }

    public func updateCaps(_ caps: SpendCaps) async { await manager.updateCaps(caps) }

    /// Fim do app: encerra TODOS os hosts (não ficam cobrando à espera da chave morta) e para os laços.
    public func shutdown() async {
        await supervisor?.stop()
        await placement.closeAll()
        for host in await manager.activeHosts { try? await manager.releaseHost(id: host.id) }
    }

    /// Encerra um host pela tela (os computadores nele param).
    public func stopHost(_ id: String) async throws {
        try await manager.releaseHost(id: id)
        await provisioning.hostClosed(id)
    }

    public func snapshot(now: Date = Date()) async -> CloudSnapshot {
        var snapshot = CloudSnapshot()
        let ledger = await manager.ledger
        snapshot.records = ledger.records.sorted { $0.startedAt > $1.startedAt }
        for host in await manager.activeHosts {
            snapshot.hosts.append(CloudSnapshot.Host(
                id: host.id, region: host.region, shape: host.shape.id, startedAt: host.launchedAt, hourlyUSD: host.hourlyUSD, computers: 0))
        }
        if let day = calendar.dateInterval(of: .day, for: now) { snapshot.todayUSD = ledger.accrued(in: day, now: now) }
        if let month = calendar.dateInterval(of: .month, for: now) { snapshot.monthUSD = ledger.accrued(in: month, now: now) }
        snapshot.lastReaperError = await supervisor?.lastReaperError
        return snapshot
    }
}

/// Referência tardia (o pool avisa o provisionador, que só existe depois do pool).
private actor ProvisioningHolder {
    var value: CloudComputerProvisioning?
    func set(_ value: CloudComputerProvisioning) { self.value = value }
}
