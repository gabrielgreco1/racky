import Foundation

/// Orquestra o ciclo de vida de VMs host do ponto de vista do app: AUP aceito, cota, teto de gasto, criação com tags e cloud-init,
/// encerramento, reaper. É a ÚNICA porta de entrada para criar VM (nada cria recurso sem passar pelo teto de gasto).
public actor CloudHostManager {
    public struct Settings: Sendable {
        public var owner: String
        public var caps: SpendCaps
        public var policy: DeadManPolicy
        public var calendar: Calendar
        public init(owner: String, caps: SpendCaps = SpendCaps(), policy: DeadManPolicy = DeadManPolicy(), calendar: Calendar = .current) {
            self.owner = owner; self.caps = caps; self.policy = policy; self.calendar = calendar
        }
    }

    /// Chaves do host para o cloud-init (geradas pelo app; ver `SSHKeyPair`).
    public struct Access: Sendable {
        public var authorizedKey: String
        public var hostKey: CloudInit.HostKey
        public init(authorizedKey: String, hostKey: CloudInit.HostKey) { self.authorizedKey = authorizedKey; self.hostKey = hostKey }
    }

    public let provider: any CloudProvider
    public var settings: Settings
    public private(set) var ledger = SpendLedger()
    private let clock: @Sendable () -> Date
    private let acceptedAUP: @Sendable (CloudProviderID, String) async -> Bool
    private var hosts: [String: CloudHost] = [:]
    private let ledgerStore: (any SpendLedgerStore)?
    /// Registro encerrado há mais que isto sai do arquivo (a janela mensal é de 31 dias).
    static let ledgerRetention: TimeInterval = 62 * 86_400

    /// `acceptedAUP(provider, versão)`: o usuário já confirmou este AUP? (P27.7)
    public init(provider: any CloudProvider, settings: Settings, clock: @escaping @Sendable () -> Date = { Date() },
                ledgerStore: (any SpendLedgerStore)? = nil, acceptedAUP: @escaping @Sendable (CloudProviderID, String) async -> Bool) {
        self.provider = provider; self.settings = settings; self.clock = clock; self.acceptedAUP = acceptedAUP
        self.ledgerStore = ledgerStore
        // O livro-caixa sobrevive ao reinício: o teto diário/mensal não zera ao fechar o app.
        if let loaded = try? ledgerStore?.load() { ledger = loaded }
    }

    private func persistLedger() {
        ledger.prune(endedBefore: clock().addingTimeInterval(-Self.ledgerRetention))
        try? ledgerStore?.save(ledger)
    }

    public var activeHosts: [CloudHost] { hosts.values.filter { $0.state.isLive }.sorted { $0.id < $1.id } }
    public func updateCaps(_ caps: SpendCaps) { settings.caps = caps }

    /// Cria um host. Falha ANTES de criar qualquer coisa se: o AUP não foi aceito, falta cota ou o teto de gasto estouraria.
    public func acquireHost(region: String, shape: HostShape, runID: String? = nil, access: Access) async throws -> CloudHost {
        let now = clock()
        let aup = try await provider.acceptableUsePolicy()
        guard await acceptedAUP(provider.id, aup.version) else { throw CloudError.acceptableUseNotAccepted(provider: provider.id, version: aup.version) }
        let quota = try await provider.quota(region: region)
        guard quota.vcpuAvailable >= shape.vcpus else { throw CloudError.quotaExceeded(region: region, needed: shape.vcpus, available: quota.vcpuAvailable) }
        let estimate = try await provider.estimate(shape: shape, region: region)
        let lifetime = settings.policy.maxLifetime
        let expires = now.addingTimeInterval(TimeInterval(lifetime.components.seconds))
        let hostID = UUID().uuidString.lowercased()
        let candidate = SpendRecord(
            hostID: hostID, startedAt: now, expiresAt: expires, hourlyUSD: estimate.hourlyUSD, region: region, shape: shape.id, provider: provider.id.rawValue)
        // Checa o teto e RESERVA no livro-caixa sem nenhum await no meio: duas aquisições simultâneas não passam juntas pelo mesmo teto.
        if let denial = SpendGuard(caps: settings.caps, calendar: settings.calendar).evaluate(newHost: candidate, ledger: ledger, now: now) {
            throw CloudError.spendCapExceeded(denial)
        }
        ledger.open(candidate)
        let tags = RackyTags(owner: settings.owner, host: hostID, run: runID, created: now, expires: expires, provider: provider.id)
        let userData = CloudInit.userData(policy: settings.policy, authorizedKey: access.authorizedKey, hostKey: access.hostKey)
        let host: CloudHost
        do {
            host = try await provider.provisionHost(HostRequest(region: region, shape: shape, tags: tags, userData: userData, maxLifetime: lifetime))
        } catch {
            ledger.discard(hostID: hostID)  // a criação falhou: solta a reserva
            throw error
        }
        ledger.discard(hostID: hostID)
        var record = candidate
        record.hostID = host.id
        // O provedor pode ter subido outro formato (plano gratuito): o registro guarda o que de fato roda e o preço dele.
        record.shape = host.shape.id
        record.hourlyUSD = host.hourlyUSD
        ledger.open(record)
        persistLedger()
        hosts[host.id] = host
        return host
    }

    public func releaseHost(id: String) async throws {
        guard let host = hosts[id] else { throw CloudError.notFound(id) }
        try await provider.terminateHost(id: id, region: host.region)
        ledger.close(hostID: id, at: clock())
        persistLedger()
        hosts[id]?.state = .terminated
    }

    /// Ao reabrir o app: acha PELAS TAGS do dono os hosts vivos que o provedor ainda tem e volta a gerenciá-los (heartbeat, teto, reaper).
    /// Host que já venceu fica de fora (o reaper o encerra). Sem registro no livro-caixa, abre um a partir das tags.
    @discardableResult
    public func adoptExisting(regions: [String]) async throws -> [CloudHost] {
        let now = clock()
        var found: [CloudHost] = []
        var firstError: (any Error)?
        var anyOK = false
        // Região por região: uma que falha não impede readotar os hosts das outras.
        for region in regions {
            do {
                found += try await provider.listHosts(tags: RackyTags.filter(owner: settings.owner), regions: [region])
                anyOK = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if !anyOK, let firstError { throw firstError }
        var adopted: [CloudHost] = []
        for host in found where host.state.isLive {
            guard let tags = RackyTags(host.tags), tags.owner == settings.owner, tags.expires > now else { continue }
            if hosts[host.id] == nil { hosts[host.id] = host; adopted.append(host) }
            if !ledger.records.contains(where: { $0.hostID == host.id && $0.endedAt == nil }) {
                ledger.open(SpendRecord(
                    hostID: host.id, startedAt: tags.created, expiresAt: tags.expires, hourlyUSD: host.hourlyUSD, region: host.region, shape: host.shape.id,
                    provider: host.provider.rawValue))
            }
        }
        persistLedger()
        return adopted
    }

    public struct CapEnforcement: Sendable, Equatable {
        public var denial: SpendDenial
        public var terminated: [String]
    }

    /// Durante o uso: se o ACUMULADO passou de um teto, encerra TODOS os hosts. Devolve o motivo e os ids.
    @discardableResult
    public func enforceCaps() async -> CapEnforcement? {
        let now = clock()
        guard let denial = SpendGuard(caps: settings.caps, calendar: settings.calendar).breach(ledger: ledger, now: now) else { return nil }
        var done: [String] = []
        for host in activeHosts {
            if (try? await releaseHost(id: host.id)) != nil { done.append(host.id) }
        }
        return CapEnforcement(denial: denial, terminated: done)
    }

    /// Reaper por tag em `regions`; fecha no livro-caixa o que foi encerrado.
    public func reap(regions: [String]) async throws -> ReaperReport {
        let report = try await HostReaper(provider: provider, owner: settings.owner).sweep(
            knownHostIDs: Set(activeHosts.map(\.id)), regions: regions, now: clock())
        let now = clock()
        var changed = false
        for id in report.terminated {
            ledger.close(hostID: id, at: now)
            hosts[id]?.state = .terminated
            changed = true
        }
        // Host que o provedor não lista mais como vivo (a VM se apagou pela chave morta, parou ou foi encerrada fora do app): sai do
        // gerenciamento e para de acumular no livro-caixa. Só vale para região listada com sucesso e host com mais de 2 min de vida
        // (a listagem pode atrasar em relação ao `run-instances`).
        for host in activeHosts where report.scannedRegions.contains(host.region) && !report.liveIDs.contains(host.id)
            && now.timeIntervalSince(host.launchedAt) > Self.goneGrace {
            markGone(host.id, at: now)
            changed = true
        }
        if changed { persistLedger() }
        return report
    }

    static let goneGrace: TimeInterval = 120

    /// O host não existe mais no provedor: fecha o registro de gasto e o tira dos vivos.
    func markGone(_ id: String, at date: Date) {
        ledger.close(hostID: id, at: date)
        hosts[id]?.state = .terminated
    }
}
