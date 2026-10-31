import Foundation
import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore

/// O que a tela de flow runs mostra.
public enum PrefectRunsFilter: String, CaseIterable, Sendable {
    case running, scheduled, failed

    var states: [PrefectClient.StateType] {
        switch self {
        case .running: [.running, .pending, .cancelling]
        case .scheduled: [.scheduled]
        case .failed: [.failed, .crashed]
        }
    }

    /// Falhas: só as das últimas 24 h; agendados: os próximos (a partir de agora).
    func since(now: Date) -> Date? {
        switch self {
        case .running: nil
        case .scheduled: now
        case .failed: now.addingTimeInterval(-86_400)
        }
    }
}

/// Última leitura dos flow runs de um Prefect.
public struct PrefectRunsState: Equatable, Sendable {
    public var rows: [PrefectClient.FlowRun] = []
    public var deployments: [String: String] = [:]
    public var error: String?
    public var loadedAt: Date?
    public var loading = false
}

extension DataHubController {
    static let savedKey = "data.connections"

    /// Liga o banco do app: carrega as conexões salvas e abre o cofre das senhas.
    public func attach(store: RackyStore, vault: SecretVault? = nil) async {
        self.store = store
        self.vault = vault ?? SecretVault(store: store, keyring: VaultKeyring(backend: SystemKeychainBackend.system()))
        saved = (try? await store.uiState(Self.savedKey, as: [SavedConnection].self)) ?? []
        rebuildConnections()
    }

    /// Exemplo (se ligado) + as salvas + os bancos dos computadores.
    func rebuildConnections() {
        connections = (isDemo ? DataHubFixtures.connections : []) + saved.map { savedConnection($0) } + computerDatabases.map { computerConnection($0) }
    }

    /// Id da conexão de um banco de computador (estável enquanto o cluster vive no mesmo lugar).
    static func computerConnectionID(_ database: ComputerDatabase) -> String { "cdb:\(database.id)" }

    func computerDatabase(_ connection: String) -> ComputerDatabase? {
        computerDatabases.first { Self.computerConnectionID($0) == connection }
    }

    private func computerConnection(_ database: ComputerDatabase) -> DataConnection {
        let id = Self.computerConnectionID(database)
        let entry = SavedConnection(id: id, kind: .postgres, name: "\(database.computer) · \(database.path)", url: "", auth: .none, secretID: nil)
        var c = entry.connection
        c.address = String(localized: "In computer \(database.computer)", bundle: .module)
        c.tags = [String(localized: "computer", bundle: .module)]
        c.children = postgresChildren(of: entry)
        return c
    }

    /// O app achou (ou perdeu) bancos nos computadores: entram na árvore e os novos têm o catálogo lido.
    public func setComputerDatabases(_ databases: [ComputerDatabase]) async {
        guard databases != computerDatabases else { return }  // a passada de 10 s repete a lista: só muda a árvore quando muda
        let before = Set(computerDatabases.map(Self.computerConnectionID))
        computerDatabases = databases
        rebuildConnections()
        for database in databases where !before.contains(Self.computerConnectionID(database)) {
            await loadCatalog(Self.computerConnectionID(database))
        }
    }

    private func savedConnection(_ s: SavedConnection) -> DataConnection {
        var c = s.connection
        if s.kind == .prefect {
            c.children = [DataNode(id: "\(s.id)/runs", kind: .runs, name: String(localized: "Flow runs", bundle: .module))]
        } else if s.kind.speaksPostgres {
            c.children = postgresChildren(of: s)
        }
        if s.kind == .s3 { c.children = s3RootChildren(s) }
        return c
    }

    // MARK: Formulário

    func startConnecting(_ kind: DataConnectionKind?) {
        connecting = kind
        connectError = nil
    }

    /// O que o formulário manda: testa e, se responder, salva (a senha vai para o cofre, aqui só o id).
    struct ConnectForm: Decodable {
        var name: String
        var url: String
        var auth: SavedConnection.AuthKind
        var user: String?
        var secret: String?
    }

    func saveConnection(_ form: ConnectForm) async -> Bool {
        if let kind = connecting, kind.speaksPostgres { return await savePostgres(form, kind: kind) }
        guard let kind = connecting, kind == .prefect else { connectError = String(localized: "This connection type is not available yet.", bundle: .module); return false }
        guard let url = PrefectClient.apiURL(from: form.url) else { connectError = String(localized: "The server URL is not valid.", bundle: .module); return false }
        let auth: PrefectClient.Auth
        switch form.auth {
        case .none: auth = .none
        case .basic: auth = .basic("\(form.user ?? ""):\(form.secret ?? "")")
        case .apiKey: auth = .apiKey(form.secret ?? "")
        case .connectionString: auth = .none
        }
        connectBusy = true
        defer { connectBusy = false }
        do {
            try await PrefectClient(baseURL: url, auth: auth, transport: prefectTransport).check()
        } catch {
            connectError = (error as? PrefectClient.Failure)?.description ?? error.localizedDescription
            return false
        }
        let id = "conn-\(UUID().uuidString.lowercased().prefix(8))"
        var secretID: UUID?
        if form.auth != .none, let vault {
            let value = form.auth == .basic ? "\(form.user ?? ""):\(form.secret ?? "")" : (form.secret ?? "")
            let name = form.name.isEmpty ? kind.title : form.name
            secretID = try? await vault.create(NewSecret(
                name: "\(name) · \(kind.title) connection (\(id))", value: value, kind: .envVar, delivery: .sidecarOnly,
                note: String(localized: "Data connection credential: only Racky reads it, never an agent's terminal.", bundle: .module))).id
        }
        let entry = SavedConnection(
            id: id, kind: kind, name: form.name.isEmpty ? kind.title : form.name, url: url.absoluteString, auth: form.auth, secretID: secretID)
        saved.append(entry)
        try? await store?.setUIState(Self.savedKey, saved)
        rebuildConnections()
        connecting = nil
        connectError = nil
        showingConnect = false
        expanded.insert(id)
        open(.runs(connection: id))
        return true
    }

    func removeConnection(_ id: String) async {
        guard let entry = saved.first(where: { $0.id == id }) else { return }
        if let secretID = entry.secretID { try? await vault?.delete(id: secretID) }
        saved.removeAll { $0.id == id }
        try? await store?.setUIState(Self.savedKey, saved)
        for object in tabs where object.connectionID == id { close(object) }
        runs[id] = nil
        forgetPostgres(id)
        forgetS3(id)
        rebuildConnections()
    }

    // MARK: Prefect

    func filter(of connection: String) -> PrefectRunsFilter { runsFilter[connection] ?? .running }

    func setRunsFilter(_ filter: PrefectRunsFilter, for connection: String) async {
        runsFilter[connection] = filter
        await refreshRuns(connection)
    }

    /// Relê os flow runs do filtro escolhido (a tela chama a cada 5 s enquanto está aberta).
    func refreshRuns(_ connection: String) async {
        guard let entry = saved.first(where: { $0.id == connection }), let url = URL(string: entry.url) else { return }
        var state = runs[connection] ?? PrefectRunsState()
        state.loading = true
        runs[connection] = state
        let auth: PrefectClient.Auth
        if let secretID = entry.secretID, let vault, let value = try? await vault.reveal(id: secretID) {
            auth = entry.auth == .basic ? .basic(value.text) : .apiKey(value.text)
        } else {
            auth = .none
        }
        let client = PrefectClient(baseURL: url, auth: auth, transport: prefectTransport)
        let filter = filter(of: connection)
        do {
            let rows = try await client.flowRuns(states: filter.states, since: filter.since(now: now()), limit: 100)
            let missing = Set(rows.compactMap(\.deploymentID)).subtracting(state.deployments.keys)
            if !missing.isEmpty, let names = try? await client.deploymentNames(ids: Array(missing)) {
                state.deployments.merge(names) { $1 }
            }
            state.rows = rows
            state.error = nil
            state.loadedAt = now()
        } catch {
            state.error = (error as? PrefectClient.Failure)?.description ?? error.localizedDescription
        }
        state.loading = false
        runs[connection] = state
    }
}
