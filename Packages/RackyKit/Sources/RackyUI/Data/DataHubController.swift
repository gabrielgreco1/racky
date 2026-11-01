import Foundation
import Observation
import RackyCore
import RackyProtocol
import RackyStore

/// Estado da área Data: conexões, o que está expandido no explorer, as tabs abertas e a ativa. Os datasets do Racky vêm do
/// `DatasetsController` (a página de dataset continua sendo a dele); as conexões são de exemplo na etapa 2.
@MainActor
@Observable
public final class DataHubController {
    public let datasets: DatasetsController
    public let notebooks: NotebookController
    public internal(set) var connections: [DataConnection] = []
    public private(set) var tabs: [DataObject] = []
    public private(set) var active: DataObject?
    public internal(set) var expanded: Set<String> = []
    /// Página da grade de cada tabela de conexão.
    public internal(set) var tablePages: [DataObject: Int] = [:]
    public func tablePage(_ object: DataObject) -> Int { tablePages[object] ?? 0 }

    /// Sub-aba de cada tabela aberta (`data`, `structure`, `writers`).
    public private(set) var tableTabs: [DataObject: DataTableTab] = [:]
    /// Texto de cada consulta aberta e o resultado da última execução.
    public var queryText: [DataObject: String] = [:]
    public internal(set) var queryResult: [DataObject: (grid: DataGrid, milliseconds: Int)] = [:]
    public internal(set) var showingConnect = false
    /// Explorer: largura arrastada pelo usuário e se está recolhido.
    public var explorerWidth: CGFloat = 268
    public private(set) var explorerHidden = false
    /// Conexão com o "Remove connection" pedindo confirmação inline.
    public private(set) var confirmingRemoval: String?
    /// O usuário pediu a lista com a janela estreita: ela aparece mesmo sem a largura que o recolhimento automático exige.
    public private(set) var explorerForced = false
    /// A área Data foi aberta de dentro de uma sessão (clique na trilha): mostra "‹ Session" para voltar.
    public var cameFromSession = false
    /// Quem o usuário pausou (agentes e cópias), por id.
    public private(set) var paused: Set<String> = []
    private var nextQuery = 1
    @ObservationIgnored var now: () -> Date = { Date() }

    /// Conexões de exemplo (RACKY_DATA_DEMO=1): a página avisa que nada está conectado.
    public let isDemo: Bool

    // MARK: Conexões de verdade (etapa 3)

    /// As que o usuário adicionou (salvas no app; a senha no cofre).
    public internal(set) var saved: [SavedConnection] = []
    /// Postgres que os agentes subiram nos computadores (o smoke): aparecem enquanto o cluster roda, sem salvar nada.
    public internal(set) var computerDatabases: [ComputerDatabase] = []
    /// Formulário de conexão aberto (o tipo escolhido no "Add connection").
    public internal(set) var connecting: DataConnectionKind?
    public internal(set) var connectError: String?
    public internal(set) var connectBusy = false
    /// Flow runs de cada orquestrador aberto e o filtro escolhido.
    public internal(set) var runs: [String: PrefectRunsState] = [:]
    public internal(set) var runsFilter: [String: PrefectRunsFilter] = [:]
    /// Postgres/Supabase de verdade: o catálogo (schemas e tabelas) de cada conexão, a última leitura de cada tabela aberta e o erro
    /// da última consulta de cada query.
    public internal(set) var catalogs: [String: PostgresCatalogState] = [:]
    public internal(set) var tableStates: [DataObject: PostgresTableState] = [:]
    public internal(set) var queryErrors: [DataObject: String] = [:]
    public internal(set) var queryTruncated: Set<DataObject> = []
    public internal(set) var queryBusy: Set<DataObject> = []
    /// Abre o conector de uma conexão (trocável nos testes por um servidor falso; nunca toca a rede).
    @ObservationIgnored var postgresFactory: @Sendable (PostgresConnectionInfo) -> any PostgresBrowsing = { PostgresConnector(info: $0) }
    /// Amazon S3 (conexões de verdade): o que o explorer já listou, cada pasta aberta e as prévias de arquivos.
    var s3Tree: [String: S3Level] = [:]
    var s3Folders: [DataObject: S3FolderState] = [:]
    var s3Previews: [String: S3Preview] = [:]
    @ObservationIgnored var s3Clients: [String: S3Client] = [:]
    @ObservationIgnored var s3Providers: [String: AWSProfileCredentials] = [:]
    @ObservationIgnored var s3Tasks: [String: Task<Void, Never>] = [:]
    /// Leitura do S3 e do AWS CLI (trocáveis nos testes).
    @ObservationIgnored var s3Transport: S3Client.Transport?
    @ObservationIgnored var s3Runner: AWSProfileCredentials.Runner?
    @ObservationIgnored var store: RackyStore?
    @ObservationIgnored var vault: SecretVault?
    /// Leitura do Prefect (trocável nos testes por um servidor falso).
    @ObservationIgnored var prefectTransport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?

    public init(datasets: DatasetsController, demo: Bool) {
        self.datasets = datasets
        notebooks = NotebookController(datasets: datasets)
        isDemo = demo
        if demo {
            connections = DataHubFixtures.connections
            expanded = [DataHubFixtures.supabase, "\(DataHubFixtures.supabase)/public"]
        }
    }

    // MARK: Leitura

    public func connection(_ id: String?) -> DataConnection? { connections.first { $0.id == id } }
    /// Abre o notebook na sessão atual, ao lado do agente (ligado pelo app). `false` sem sessão aberta.
    @ObservationIgnored public var openNotebookInSession: ((String) -> Bool)?

    /// Sessões com datasets, na ordem da lista (a mais recente primeiro).
    public var rackyGroups: [(session: String, datasets: [DatasetSummary])] {
        var order: [String] = []
        var groups: [String: [DatasetSummary]] = [:]
        for summary in datasets.summaries {
            let title = datasets.title(of: summary)
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(summary)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    public func summary(ofDataset id: String) -> DatasetSummary? { datasets.summaries.first { $0.dataset.id == id } }

    public func datasetID(named name: String) -> String? { datasets.summaries.first { $0.dataset.name == name }?.dataset.id }

    public func writers(of object: DataObject) -> [DataWriter] {
        if case .dataset(let id) = object, let summary = summary(ofDataset: id) {
            // Os agentes da sessão que coletaram (computadores do dataset).
            // Cada computador que coletou, com o nome do agente que o usou ("Codex 1"; id = o computador).
            let agents = (datasets.models[id]?.snapshot?.facets[.computer] ?? []).map { (computer: $0.value, name: datasets.computerLabel($0.value) ?? $0.value) }
            let live = datasets.isCollecting(summary)
            let session = datasets.title(of: summary)
            guard !agents.isEmpty else {
                // Sem o nome do agente (dataset antigo): pelo menos a sessão que coletou.
                return summary.rowCount == 0 ? [] : [DataWriter(id: "session", kind: .agent(session: session), name: String(localized: "Agents", bundle: .module), live: live, detail: live ? "writing now" : "")]
            }
            return agents.map { DataWriter(id: $0.computer, kind: .agent(session: session), name: $0.name, live: live && !paused.contains($0.computer), detail: live ? "writing now" : "") }
        }
        return DataHubFixtures.writers(of: object) { [weak self] in self?.datasetID(named: $0) }.map { writer in
            var writer = writer
            if paused.contains(writer.id) { writer.live = false; writer.detail = String(localized: "paused", bundle: .module) }
            return writer
        }
    }

    public func destinations(of object: DataObject) -> [DataDestination] {
        guard case .dataset(let id) = object, let name = summary(ofDataset: id)?.dataset.name, !connections.isEmpty else { return [] }
        return DataHubFixtures.destinations(ofDataset: name)
    }

    /// A fonte de uma cópia: o dataset do Racky que um sync copia para cá (a "fonte de verdade").
    public func copySource(of object: DataObject) -> String? {
        for writer in writers(of: object) { if case .sync(let from) = writer.kind, case .dataset(let name) = from { return name } }
        return nil
    }

    /// Nome mostrado de um dataset do Mac a partir do nome original (depois de renomear, os textos usam o novo).
    public func displayName(ofDatasetNamed name: String) -> String {
        datasetID(named: name).flatMap { datasets.name(of: $0) } ?? name
    }

    /// Algo está gravando neste nó agora (ponto "live" no explorer)?
    public func isLive(_ object: DataObject) -> Bool { writers(of: object).contains { $0.live } }

    // MARK: Ações locais

    public func open(_ object: DataObject) {
        if !tabs.contains(object) { tabs.append(object) }
        active = object
        if case .dataset(let id) = object { Task { _ = await datasets.openInHub(id) } }
        if tableTabs[object] == nil { tableTabs[object] = .data }
        if let feeding = feedingDataset(of: object) { Task { await datasets.prepare(feeding) } }
        if case .query = object, queryText[object] == nil {
            queryText[object] = isLivePostgres(object.connectionID) ? PostgresStarter.query : DataHubFixtures.sampleQuery
        }
        if case .table = object, isLivePostgres(object.connectionID) { Task { await loadTable(object) } }
        if case .folder = object, isLiveS3(object.connectionID) { Task { await loadS3Folder(object) } }
    }

    public func close(_ object: DataObject) {
        guard let index = tabs.firstIndex(of: object) else { return }
        tabs.remove(at: index)
        if active == object { active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
        if let active, case .dataset(let id) = active { Task { _ = await datasets.openInHub(id) } }
    }

    public func activate(_ object: DataObject) {
        active = object
        if case .dataset(let id) = object { Task { _ = await datasets.openInHub(id) } }
    }

    public func toggle(_ node: String) {
        if expanded.contains(node) { expanded.remove(node) } else {
            expanded.insert(node)
            // Abrir uma conexão Postgres lê os schemas e tabelas dela (uma vez; de novo se a leitura falhou).
            if isLivePostgres(node), catalogs[node]?.schemas == nil { Task { await loadCatalog(node) } }
            s3Expanded(node)
        }
    }

    public func newQuery(on connection: String) -> DataObject {
        let object = DataObject.query(connection: connection, id: nextQuery)
        nextQuery += 1
        open(object)
        return object
    }

    public func run(_ object: DataObject) {
        guard case .query = object else { return }
        if isLivePostgres(object.connectionID) { Task { await runQuery(object) }; return }
        queryResult[object] = (DataHubFixtures.grid(for: object), 42)
    }

    public func tableTab(_ object: DataObject) -> DataTableTab {
        let tab = tableTabs[object] ?? .data
        return tabs(for: object).contains(tab) ? tab : .data
    }

    /// Mesmas abas para o que os agentes alimentam, no Mac ou numa conexão; tabela que o Racky não alimenta é só navegação.
    public func tabs(for object: DataObject) -> [DataTableTab] {
        switch object {
        case .dataset: return [.data, .overview, .structure, .writers]
        case .table: return copySource(of: object) != nil ? [.data, .overview, .structure, .writers] : [.data, .structure]
        default: return []
        }
    }

    /// O dataset do Mac que alimenta este objeto (ele mesmo, se for um dataset).
    public func feedingDataset(of object: DataObject) -> String? {
        if case .dataset(let id) = object { return id }
        return copySource(of: object).flatMap(datasetID(named:))
    }

    /// Dataset sendo renomeado no lugar (título da barra ou linha do explorer).
    public private(set) var renaming: String?
    /// Onde a edição começou (`title` na barra, `explorer` na lista): só ali aparece o campo.
    public private(set) var renamingIn = "title"
    public func beginRename(_ id: String?, in place: String = "title") {
        renaming = id
        renamingIn = place
    }

    /// Opções de "Save data to" no formulário de nova sessão: o Racky e cada tabela, pasta, aba ou webhook das conexões.
    func composerDestinations() -> [ComposerDataDestination] {
        var out = [ComposerDataDestination.thisMac]
        for connection in connections {
            let prod = connection.protected
            let place = connection.name + (prod ? " (protected)" : "")
            func add(_ object: DataObject, _ title: String, _ explanation: String) {
                out.append(ComposerDataDestination(
                    key: object.key, title: title, group: connection.name, production: prod, explanation: explanation, brand: connection.kind.brand))
            }
            switch connection.kind.family {
            case .database, .warehouse:
                // Conexão Postgres de verdade é só leitura: ninguém grava nela, então não é destino de "Save data to".
                if isLivePostgres(connection.id) { break }
                for schema in connection.children {
                    for table in schema.children where table.kind == .table {
                        let object = DataObject.table(connection: connection.id, schema: schema.name, name: table.name)
                        add(object, "\(connection.name) › \(schema.name).\(table.name)",
                            String(localized: "Collected on this Mac first, then copied one way to \(schema.name).\(table.name) on \(place) as rows arrive.", bundle: .module))
                    }
                }
            case .storage:
                for folder in connection.children {
                    add(.folder(connection: connection.id, path: [folder.name]), "\(connection.name) › \(folder.name)/",
                        String(localized: "Agents collect into a dataset on this Mac and Racky writes it as Parquet files into \(folder.name)/ on \(connection.name).", bundle: .module))
                }
            case .spreadsheet:
                for book in connection.children {
                    for tab in book.children {
                        add(.tab(connection: connection.id, spreadsheet: book.name, name: tab.name), "\(connection.name) › \(tab.name)",
                            String(localized: "Agents collect into a dataset on this Mac and Racky appends each new row to the \(tab.name) tab of \(book.name).", bundle: .module))
                    }
                }
            case .orchestrator:
                // Orquestrador (Prefect): só se lê o que roda; agentes não gravam lá.
                break
            case .outgoing:
                add(.webhook(connection: connection.id), connection.name,
                    String(localized: "Agents collect into a dataset on this Mac and Racky posts each new row to \(connection.address).", bundle: .module))
            }
        }
        return out
    }

    // MARK: Registro

    public func register(in registry: ActionRegistry) throws {
        try notebooks.register(in: registry) { [unowned self] id, inSession in
            if inSession, openNotebookInSession?(id) == true { return }
            open(.notebook(id))
            if datasets.currentPage() != .datasets { datasets.showPage(.datasets) }
        }
        // O notebook aberto na área Data vai para a sessão, ao lado do agente (as tabs de Data e da sessão se falam).
        try registry.register(.notebookOpenBeside) { [unowned self] arg in
            guard arg.kind == .select, let id = arg.value, notebooks.notebooks[id] != nil else {
                throw ActionError.failed(.notebookOpenBeside, message: "expected select(<notebookId>) of an open notebook")
            }
            guard openNotebookInSession?(id) == true else {
                throw ActionError.failed(.notebookOpenBeside, message: String(localized: "Open a session first.", bundle: .module))
            }
            close(.notebook(id))
            return id
        }
        try registry.register(.dataOpen) { [unowned self] arg in
            guard let raw = arg.value, let object = DataObject(key: raw) else {
                throw ActionError.failed(.dataOpen, message: String(localized: "No such object.", bundle: .module))
            }
            // Objeto de uma conexão que não existe mais (removida): erro, em vez de uma tabela vazia rotulada "This Mac". Dataset e
            // notebook não pertencem a conexão (o notebook era recusado aqui e a tab dele não reabria).
            if object.connectionID != nil, connection(object.connectionID) == nil {
                throw ActionError.failed(.dataOpen, message: String(localized: "No such object.", bundle: .module))
            }
            open(object)
            // Clicado de dentro de uma sessão (a trilha do dataset numa tab): leva para a área Data, já no lugar.
            if datasets.currentPage() != .datasets {
                await datasets.reloadList()
                datasets.showPage(.datasets)
                cameFromSession = true
            }
            return raw
        }
        try registry.register(.dataClose) { [unowned self] arg in
            guard let object = arg.value.flatMap(DataObject.init(key:)) ?? active else { return "" }
            close(object)
            return object.key
        }
        try registry.register(.dataToggleNode) { [unowned self] arg in
            guard let id = arg.value else { throw ActionError.failed(.dataToggleNode, message: "expected select(<node>)") }
            toggle(id)
            return expanded.contains(id) ? "open" : "closed"
        }
        try registry.register(.dataNewQuery) { [unowned self] arg in
            guard let id = arg.value, connection(id)?.kind.speaksSQL == true else {
                throw ActionError.failed(.dataNewQuery, message: String(localized: "This connection doesn't run SQL.", bundle: .module))
            }
            return newQuery(on: id).key
        }
        try registry.register(.dataTableTab) { [unowned self] arg in
            // `select(<aba>)` age no objeto aberto na área Data; `select(<aba>|<objeto>)` no objeto do pane que foi clicado.
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.count > 1 ? DataObject(key: parts[1]) : active
            guard let target, let raw = parts.first, let tab = DataTableTab(rawValue: raw), tabs(for: target).contains(tab) else {
                throw ActionError.failed(.dataTableTab, message: "expected select(data|overview|structure|writers) with a dataset or table open")
            }
            tableTabs[target] = tab
            return raw
        }
        try registry.register(.dataQueryRun) { [unowned self] arg in
            guard let active, case .query = active else { throw ActionError.failed(.dataQueryRun, message: "no query open") }
            // `set <sql>` escreve no editor antes de rodar (o editor não tem ação própria: sem isso a automação não digitava SQL).
            if arg.kind == .set, let sql = arg.value { queryText[active] = sql }
            if isLivePostgres(active.connectionID) { await runQuery(active) } else { run(active) }
            return "ok"
        }
        try registry.register(.dataAddConnection) { [unowned self] arg in
            showingConnect = arg.value != "close"
            return showingConnect ? "open" : "closed"
        }
        try registry.register(.dataSendTo) { _ in "" }
        try registry.register(.dataConnectStart) { [unowned self] arg in
            guard let raw = arg.value, raw != "close" else { startConnecting(nil); return "closed" }
            guard let kind = DataConnectionKind(rawValue: raw), kind.connectable else {
                throw ActionError.failed(.dataConnectStart, message: String(localized: "This connection type is not available yet.", bundle: .module))
            }
            startConnecting(kind)
            return kind.rawValue
        }
        try registry.register(.dataS3Page) { [unowned self] arg in try await s3PageAction(arg) }
        try registry.register(.dataConnectSave) { [unowned self] arg in
            if connecting == .s3 { return try await saveS3(arg) }
            guard arg.kind == .set, let raw = arg.value, let form = try? JSONDecoder().decode(ConnectForm.self, from: Data(raw.utf8)) else {
                throw ActionError.failed(.dataConnectSave, message: "expected set({\"name\",\"url\",\"auth\",\"user\",\"secret\"})")
            }
            guard await saveConnection(form) else { throw ActionError.failed(.dataConnectSave, message: connectError ?? "") }
            return "saved"
        }
        // Remover apaga a conexão e a senha do cofre: o primeiro clique pede confirmação ali mesmo (`<id>`), só `<id>|confirm`
        // remove e `cancel` desiste. Antes um clique solto (ou a varredura de cliques do teste completo) apagava sem perguntar.
        try registry.register(.dataConnectionRemove) { [unowned self] arg in
            guard let raw = arg.value else { throw ActionError.failed(.dataConnectionRemove, message: "expected select(<id>|<id>|confirm|cancel)") }
            if raw == "cancel" { confirmingRemoval = nil; return "kept" }
            let parts = raw.split(separator: "|").map(String.init)
            guard parts.count == 2, parts[1] == "confirm" else { confirmingRemoval = raw; return "confirm" }
            confirmingRemoval = nil
            await removeConnection(parts[0])
            return parts[0]
        }
        try registry.register(.dataRunsFilter) { [unowned self] arg in
            guard case .runs(let connection) = active, let raw = arg.value, let filter = PrefectRunsFilter(rawValue: raw) else {
                throw ActionError.failed(.dataRunsFilter, message: "expected select(running|scheduled|failed) with flow runs open")
            }
            await setRunsFilter(filter, for: connection)
            return raw
        }
        try registry.register(.dataTablePage) { [unowned self] arg in
            guard let active, case .table = active else { throw ActionError.failed(.dataTablePage, message: "no table open") }
            let pages = pageCount(for: active)
            let page = tablePage(active)
            switch arg.value {
            case "next": tablePages[active] = min(page + 1, pages - 1)
            case "prev": tablePages[active] = max(page - 1, 0)
            default: throw ActionError.failed(.dataTablePage, message: "expected select(next|prev)")
            }
            if isLivePostgres(active.connectionID), tablePage(active) != page { await loadTable(active) }
            return "\(tablePage(active) + 1)"
        }
        try registry.register(.dataRenameDataset) { [unowned self] arg in
            // `@explorer:<id>`: a edição começa na linha do explorer (não no título).
            if let raw = arg.value, raw.hasPrefix("@explorer:") {
                let id = String(raw.dropFirst("@explorer:".count))
                guard summary(ofDataset: id) != nil else { throw ActionError.failed(.dataRenameDataset, message: String(localized: "No such dataset.", bundle: .module)) }
                beginRename(id, in: "explorer")
                return "editing"
            }
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let id = parts.first, summary(ofDataset: id) != nil else {
                throw ActionError.failed(.dataRenameDataset, message: String(localized: "No such dataset.", bundle: .module))
            }
            guard parts.count == 2 else { beginRename(id); return "editing" }
            renaming = nil
            await datasets.rename(id, to: parts[1])
            return datasets.name(of: id) ?? ""
        }
        try registry.register(.dataToggleExplorer) { [unowned self] arg in
            // O botão diz o que quer: com a lista recolhida por falta de espaço, "toggle" escondia o que já estava invisível e
            // clicar em "Show Data list" não fazia nada.
            switch arg.value {
            case "show": explorerHidden = false; explorerForced = true
            case "hide": explorerHidden = true; explorerForced = false
            default: explorerHidden.toggle(); explorerForced = !explorerHidden
            }
            return explorerHidden ? "hidden" : "shown"
        }
        try registry.register(.dataPauseWriter) { [unowned self] arg in
            guard let active else { return "" }
            let ids = arg.value == "all" || arg.value == nil ? writers(of: active).filter(\.live).map(\.id) : [arg.value ?? ""]
            for id in ids { if paused.contains(id) { paused.remove(id) } else { paused.insert(id) } }
            return ids.joined(separator: ",")
        }
        try registry.register(.dataWebhookTest) { _ in "sent" }
    }
}

/// Abas de um dataset ou tabela: os dados (padrão, ocupa a tela), a visão geral (números, gráfico, caminho), as colunas e quem grava.
public enum DataTableTab: String, CaseIterable, Sendable { case data, overview, structure, writers }

extension DataObject {
    /// Chave estável (argumento das ações e sufixo dos IDs de acessibilidade).
    public var key: String {
        switch self {
        case .dataset(let id): "dataset:\(id)"
        case .table(let c, let s, let n): "table:\(c):\(s):\(n)"
        case .query(let c, let n): "query:\(c):\(n)"
        case .folder(let c, let path): "folder:\(c):\(path.joined(separator: "/"))"
        case .webhook(let c): "webhook:\(c)"
        case .tab(let c, let s, let n): "sheet:\(c):\(s):\(n)"
        case .runs(let c): "runs:\(c)"
        case .notebook(let n): "notebook:\(n)"
        }
    }

    public init?(key: String) {
        var parts = key.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        // Pasta de bucket: o nome pode ter ":" (o resto depois da conexão é o caminho inteiro).
        if parts.first == "folder" { parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init) }
        guard let kind = parts.first else { return nil }
        switch (kind, parts.count) {
        case ("dataset", 2): self = .dataset(parts[1])
        case ("table", 4): self = .table(connection: parts[1], schema: parts[2], name: parts[3])
        case ("query", 3): guard let n = Int(parts[2]) else { return nil }; self = .query(connection: parts[1], id: n)
        case ("folder", 3): self = .folder(connection: parts[1], path: parts[2].split(separator: "/").map(String.init))
        case ("webhook", 2): self = .webhook(connection: parts[1])
        case ("sheet", 4): self = .tab(connection: parts[1], spreadsheet: parts[2], name: parts[3])
        case ("runs", 2): self = .runs(connection: parts[1])
        case ("notebook", 2): self = .notebook(parts[1])
        default: return nil
        }
    }
}
