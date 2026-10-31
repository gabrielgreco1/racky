import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation

// Datasets v1 (docs/rebuild/spec/datasets.md): a lista de datasets e a tabela viva de um dataset. A UI nunca lê arquivo nem SQL: tudo passa
// por este controlador, que consulta o `RackyStore` fora da thread principal (`DatasetLoader`) e só publica o resultado já pronto.

/// Uma linha para mostrar: o registro e as células já em texto (decodificadas fora do main).
nonisolated public struct DatasetDisplayRow: Sendable, Equatable, Identifiable {
    public var row: DatasetRow
    public var cells: [String]
    /// Por coluna, o problema curto daquela célula quando a linha é inválida ("missing", `"four"`); nil = célula ok.
    public var problems: [String?] = []
    public var id: String { row.rowKey }
}

/// Período da página (gráfico, facetas e grade): só linhas que chegaram nele.
nonisolated public enum DatasetRange: String, Sendable, CaseIterable {
    case minutes15 = "15m", hour = "1h", hours6 = "6h", day = "24h", week = "7d", all

    public var seconds: TimeInterval? {
        switch self {
        case .minutes15: 900
        case .hour: 3600
        case .hours6: 21_600
        case .day: 86_400
        case .week: 604_800
        case .all: nil
        }
    }
}

/// Aba do painel da linha.
nonisolated public enum DatasetPanelTab: String, Sendable, CaseIterable {
    case attributes, source, history
}

/// O que a página de um dataset mostra agora.
nonisolated public struct DatasetPageSnapshot: Sendable, Equatable {
    public var summary: DatasetSummary
    public var rows: [DatasetDisplayRow]
    /// Linhas que casam a consulta (a paginação usa).
    public var matching: Int
    /// Linhas novas por faixa no período (o gráfico de volume), o início do período e o ritmo recente por minuto.
    public var activity: [DatasetActivityBucket] = []
    public var activityStart: Date?
    /// Fim do gráfico e largura de cada barra (s): "All time" acaba na última linha quando a coleta parou, não em "agora".
    public var activityEnd: Date?
    public var bucketSeconds: TimeInterval = 60
    /// Fracionário: 1 linha em 5 min é "0.2/min", não "0" ao lado de "+1 in 5 min".
    public var perMinute: Double = 0
    public var facets: [DatasetFacet: [DatasetFacetCount]] = [:]
    public var stats = DatasetStats()
    /// Perfil de cada coluna (preenchimento, valores, faixa, histograma) com a consulta aplicada.
    public var profiles: [String: DatasetColumnProfile] = [:]
    /// Janela escolhida no gráfico (o gráfico não a aplica; a grade, as facetas e os perfis sim).
    public var window: ClosedRange<Date>?
}

/// O que o controlador pede ao loader.
nonisolated struct DatasetPageRequest: Sendable, Equatable {
    var id: String
    var query: DatasetQuery
    var range: DatasetRange
    var page: Int
    var pageSize: Int
    var window: ClosedRange<Date>?
}

/// A barra de consulta como pills: cada token que o `parse` entende vira uma condição; o resto é texto livre. Funções puras sobre o texto.
nonisolated public enum DatasetSearchText {
    public struct Pill: Sendable, Equatable {
        /// O token como foi digitado (aspas mantidas).
        public var raw: String
        public var column: String
        public var comparison: DatasetComparison
        public var value: String
    }

    public static func split(_ text: String, columns: [DatasetColumn]) -> (pills: [Pill], free: String) {
        let known = DatasetLoader.knownColumns(columns)
        var pills: [Pill] = []
        var free: [String] = []
        for raw in DatasetLoader.rawTokens(text) {
            let plain = raw.replacingOccurrences(of: "\"", with: "")
            if let c = DatasetLoader.condition(plain, known: known) {
                pills.append(Pill(raw: raw, column: c.column, comparison: c.comparison, value: c.value))
            } else if !plain.isEmpty {
                free.append(plain)
            }
        }
        return (pills, free.joined(separator: " "))
    }

    public static func removing(pillAt index: Int, from text: String, columns: [DatasetColumn]) -> String {
        let known = DatasetLoader.knownColumns(columns)
        var seen = 0
        var kept: [String] = []
        for raw in DatasetLoader.rawTokens(text) {
            if DatasetLoader.condition(raw.replacingOccurrences(of: "\"", with: ""), known: known) != nil {
                defer { seen += 1 }
                if seen == index { continue }
            }
            kept.append(raw)
        }
        return kept.joined(separator: " ")
    }

    /// Acrescenta `coluna:op"valor"`. "Contém" some o operador em coluna de texto (é o padrão do `parse`); as outras comparações o mantêm.
    public static func adding(column: String, comparison: DatasetComparison, value: String, to text: String, columns: [DatasetColumn] = []) -> String {
        let textual = columns.first { $0.name == column }.map { [.string, .url, .json].contains($0.type) } ?? true
        let op = comparison == .contains && textual ? "" : comparison.rawValue
        let clean = value.replacingOccurrences(of: "\"", with: "")
        let body = clean.contains(" ") ? "\"\(clean)\"" : clean
        return append("\(column):\(op)\(body)", to: text)
    }

    /// Troca os `>`, `>=`, `<`, `<=` da coluna por `col:>=min col:<=max` (lado nil = aberto).
    public static func replacingRange(column: String, min: Double?, max: Double?, in text: String, columns: [DatasetColumn] = []) -> String {
        let name = columns.first { $0.name.lowercased() == column.lowercased() }?.name ?? column
        let known = DatasetLoader.knownColumns(columns.isEmpty ? [DatasetColumn(name: column, type: .number)] : columns)
        let bounds: Set<DatasetComparison> = [.greater, .greaterOrEqual, .less, .lessOrEqual]
        var result = DatasetLoader.rawTokens(text).filter { raw in
            guard let c = DatasetLoader.condition(raw.replacingOccurrences(of: "\"", with: ""), known: known) else { return true }
            return !(c.column.lowercased() == name.lowercased() && bounds.contains(c.comparison))
        }.joined(separator: " ")
        if let min { result = append("\(name):>=\(number(min))", to: result) }
        if let max { result = append("\(name):<=\(number(max))", to: result) }
        return result
    }

    private static func append(_ token: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? token : trimmed + " " + token
    }

    /// `20`, `4.5` (sem `.0` no fim).
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

nonisolated enum DatasetLoader {
    @concurrent
    static func summaries(store: RackyStore) async -> [DatasetSummary] {
        (try? await store.datasetSummaries()) ?? []
    }

    /// `reuse`: facetas e perfis das colunas da última leitura completa com o mesmo pedido (as consultas mais caras); com eles a
    /// atualização de cada segundo só lê linhas, contagens e o gráfico.
    @concurrent
    static func page(
        store: RackyStore, request: DatasetPageRequest, now: Date = Date(), reuse: DatasetPageSnapshot? = nil
    ) async -> DatasetPageSnapshot? {
        guard let summary = try? await store.datasetSummary(id: request.id) else { return nil }
        let id = request.id
        var query = request.query
        let stats = (try? await store.datasetStats(
            datasetID: id, columns: summary.dataset.columns.map(\.name), recentSince: now.addingTimeInterval(-recentWindow))) ?? DatasetStats()
        let first = stats.firstSeen ?? summary.dataset.createdAt
        // "All time": da primeira à última linha (com folga), ou até agora se ainda chega coisa; senão, o período escolhido até agora.
        let end: Date
        if request.range.seconds == nil, let last = stats.lastSeen, now.timeIntervalSince(last) > idleAfter {
            end = last.addingTimeInterval(max(last.timeIntervalSince(first) * 0.08, 60))
        } else {
            end = now
        }
        // Dataset novo: o eixo começa logo antes da primeira linha (6% de folga), sem minutos vazios à esquerda.
        let lead = max(end.timeIntervalSince(first) * 0.06, 1)
        let start: Date = request.range.seconds.map { now.addingTimeInterval(-$0) } ?? first.addingTimeInterval(-lead)
        if request.range.seconds != nil { query.since = start }
        // O gráfico mantém o período inteiro (contexto); só linhas, facetas e perfis seguem a janela.
        let chartQuery = query
        if let window = request.window {
            query.since = window.lowerBound
            query.until = window.upperBound.addingTimeInterval(0.001)
        }
        let rows = (try? await store.datasetRows(datasetID: id, query: query, limit: request.pageSize, offset: request.page * request.pageSize)) ?? []
        let matching = (try? await store.datasetRowCount(datasetID: id, query: query)) ?? rows.count
        let columns = summary.dataset.columns
        let display = rows.map { row -> DatasetDisplayRow in
            let object = DatasetExporter.decode(row)
            let problems = Self.problems(row.error)
            return DatasetDisplayRow(row: row, cells: columns.map { Self.text(object[$0.name]) }, problems: columns.map { problems[$0.name] })
        }
        let span = max(end.timeIntervalSince(start), minimumSpan)
        // Períodos curtos usam faixas fracionárias (arredondar para segundos inteiros esticaria o eixo além dos dados).
        let bucket = span >= Double(activityBuckets) ? (span / Double(activityBuckets)).rounded(.up) : span / Double(activityBuckets)
        let activity = (try? await store.datasetActivity(datasetID: id, until: end, bucket: bucket, buckets: activityBuckets, query: chartQuery)) ?? []
        // Ritmo: linhas novas nos últimos 5 minutos, por minuto.
        let recent = (try? await store.datasetActivity(datasetID: id, until: now, bucket: 300, buckets: 1))?.first
        let perMinute = Double((recent?.valid ?? 0) + (recent?.invalid ?? 0)) / 5
        let facets = if let reuse { reuse.facets } else { (try? await store.datasetFacets(datasetID: id, query: query)) ?? [:] }
        let profiles = if let reuse { reuse.profiles } else { (try? await store.datasetColumnProfiles(datasetID: id, columns: columns, query: query)) ?? [:] }
        return DatasetPageSnapshot(
            summary: summary, rows: display, matching: matching, activity: activity, activityStart: end.addingTimeInterval(-bucket * Double(activityBuckets)),
            activityEnd: end, bucketSeconds: bucket, perMinute: perMinute, facets: facets, stats: stats,
            profiles: profiles, window: request.window)
    }

    /// O período vira 48 barras.
    static let activityBuckets = 48
    /// Menor período do gráfico (segundos): poucas linhas num instante não viram uma barra só.
    static let minimumSpan: TimeInterval = 12
    /// "+N" do topo: linhas dos últimos 5 minutos. Sem linha nova há 10 minutos, o gráfico de "All time" para na última.
    static let recentWindow: TimeInterval = 300
    static let idleAfter: TimeInterval = 600

    /// `price:>200 rating:>=4.5 Union` vira condições sobre colunas conhecidas e o texto livre que sobra. `coluna:valor` numa coluna de texto
    /// é "contém"; em número, data e booleano é "igual". Palavras com `:` que não são coluna ficam no texto.
    static func parse(_ input: String, columns: [DatasetColumn]) -> (conditions: [DatasetCondition], text: String) {
        let known = knownColumns(columns)
        var conditions: [DatasetCondition] = []
        var free: [String] = []
        for token in tokens(input) {
            if let condition = condition(token, known: known) { conditions.append(condition) } else { free.append(token) }
        }
        return (conditions, free.joined(separator: " "))
    }

    static func knownColumns(_ columns: [DatasetColumn]) -> [String: DatasetColumn] {
        Dictionary(columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A condição de um token já sem aspas (`price:>200`), ou nil quando ele é texto livre.
    static func condition(_ token: String, known: [String: DatasetColumn]) -> DatasetCondition? {
        guard let colon = token.firstIndex(of: ":"), let column = known[token[..<colon].lowercased()] else { return nil }
        var rest = String(token[token.index(after: colon)...])
        var comparison: DatasetComparison?
        for op in [DatasetComparison.greaterOrEqual, .lessOrEqual, .notEquals, .greater, .less, .equals, .contains] where rest.hasPrefix(op.rawValue) {
            comparison = op
            rest.removeFirst(op.rawValue.count)
            break
        }
        guard !rest.isEmpty else { return nil }
        let fallback: DatasetComparison = column.type == .string || column.type == .url || column.type == .json ? .contains : .equals
        return DatasetCondition(column: column.name, comparison: comparison ?? fallback, value: rest)
    }

    /// Divide por espaço respeitando aspas (`name:"grand plaza"`), sem as aspas.
    static func tokens(_ input: String) -> [String] {
        rawTokens(input).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
    }

    /// Como `tokens`, mas cada token como foi digitado (aspas mantidas).
    static func rawTokens(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for char in input {
            if char == "\"" { quoted.toggle(); current.append(char); continue }
            if char == " ", !quoted {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// `"price: required; rating: expected number, got \"four\""` vira `["price": "missing", "rating": "\"four\""]`.
    static func problems(_ error: String?) -> [String: String] {
        guard let error else { return [:] }
        var result: [String: String] = [:]
        for part in error.components(separatedBy: "; ") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let column = String(part[..<colon])
            let message = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if message == "required" {
                result[column] = "missing"
            } else if let got = message.range(of: ", got ") {
                result[column] = String(message[got.upperBound...])
            } else {
                result[column] = message
            }
        }
        return result
    }

    static func text(_ value: JSON?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let s): return s.replacingOccurrences(of: "\n", with: " ")
        default: return value.text
        }
    }
}

enum DatasetExportFormat: String, CaseIterable {
    case csv, jsonl, json

    var exporter: DatasetExporter.Format {
        switch self {
        case .csv: .csv
        case .jsonl: .jsonl
        case .json: .json
        }
    }
}

/// Estado de um dataset aberto (uma tab, um pane ou a página): consulta, facetas, período, página, colunas visíveis, linha
/// selecionada e o que está na tela. Dois panes do mesmo dataset dividem o mesmo estado.
@MainActor
@Observable
public final class DatasetViewModel: Identifiable {
    public let id: String
    public fileprivate(set) var snapshot: DatasetPageSnapshot?
    /// Texto da barra de consulta (`price:>200 rating:>=4.5 plaza`).
    public var search = ""
    public fileprivate(set) var range: DatasetRange = .all
    /// Janela escolhida no gráfico (arrastar); limita grade, facetas e perfis, não o gráfico.
    public fileprivate(set) var window: ClosedRange<Date>?
    /// Valores desmarcados por faceta e tipos de erro escolhidos.
    public fileprivate(set) var excluded: [DatasetFacet: Set<String>] = [:]
    public fileprivate(set) var errorKinds: Set<String> = []
    public fileprivate(set) var hiddenColumns: Set<String> = []
    public fileprivate(set) var page = 0
    public fileprivate(set) var selectedRowKey: String?
    public fileprivate(set) var panelTab: DatasetPanelTab = .attributes
    @ObservationIgnored fileprivate var visibleCount = 0
    /// Texto da última consulta que chegou ao store (o campo atualiza `search` antes de a ação rodar).
    @ObservationIgnored fileprivate var loadedSearch: String?

    init(id: String) { self.id = id }

    /// Filtro antigo `All | Invalid` (automação): equivale a desmarcar `valid` na faceta de status.
    public var filter: DatasetRowFilter { excluded[.status]?.contains("valid") == true ? .invalid : .all }
    public var columns: [DatasetColumn] { snapshot?.summary.dataset.columns ?? [] }
    public var visibleColumns: [DatasetColumn] { columns.filter { !hiddenColumns.contains($0.name) } }
    public var selectedRow: DatasetDisplayRow? { snapshot?.rows.first { $0.row.rowKey == selectedRowKey } }
    public var pageCount: Int { max(Int((Double(snapshot?.matching ?? 0) / Double(DatasetsController.pageSize)).rounded(.up)), 1) }

    /// Valor marcado na faceta (`error` começa todo desmarcado: marcar filtra).
    public func isChecked(_ facet: DatasetFacet, _ value: String) -> Bool {
        facet == .error ? errorKinds.contains(value) : !(excluded[facet]?.contains(value) ?? false)
    }

    fileprivate var request: DatasetPageRequest {
        let parsed = DatasetLoader.parse(search, columns: columns)
        let query = DatasetQuery(excluded: excluded, errorKinds: errorKinds, text: parsed.text, conditions: parsed.conditions)
        return DatasetPageRequest(id: id, query: query, range: range, page: page, pageSize: DatasetsController.pageSize, window: window)
    }

    /// Última leitura completa (com facetas e perfis) e o pedido dela: até `fullEvery` depois, com o mesmo pedido, a leitura é leve.
    @ObservationIgnored private var lastFull: (at: Date, request: DatasetPageRequest)?
    static let fullEvery: TimeInterval = 10

    fileprivate func reload(store: RackyStore, now: Date) async {
        let wanted = request
        let light = lastFull.map { $0.request == wanted && now.timeIntervalSince($0.at) < Self.fullEvery } ?? false
        let loaded = await DatasetLoader.page(store: store, request: wanted, now: now, reuse: light ? snapshot : nil)
        if !light { lastFull = (now, wanted) }
        // Uma consulta lenta não sobrescreve o que o usuário mudou enquanto ela rodava.
        guard request == wanted else { return }
        loadedSearch = search
        if loaded != snapshot { snapshot = loaded }
    }
}

@MainActor
@Observable
public final class DatasetsController {
    public static let pageSize = 50

    public private(set) var summaries: [DatasetSummary] = []
    public private(set) var listLoaded = false
    /// Datasets abertos (tabs, panes, página) e o ativo: o último em que o mouse passou ou que foi aberto. As ações agem nele.
    public private(set) var models: [String: DatasetViewModel] = [:]
    public private(set) var currentID: String?

    public var active: DatasetViewModel? { currentID.flatMap { models[$0] } }

    // Atalhos para o dataset ativo (automação e testes).
    public var snapshot: DatasetPageSnapshot? { active?.snapshot }
    public var search: String {
        get { active?.search ?? "" }
        set { active?.search = newValue }
    }
    public var range: DatasetRange { active?.range ?? .all }
    public var excluded: [DatasetFacet: Set<String>] { active?.excluded ?? [:] }
    public var errorKinds: Set<String> { active?.errorKinds ?? [] }
    public var hiddenColumns: Set<String> { active?.hiddenColumns ?? [] }
    public var page: Int { active?.page ?? 0 }
    public var selectedRowKey: String? { active?.selectedRowKey }
    public var panelTab: DatasetPanelTab { active?.panelTab ?? .attributes }
    public var filter: DatasetRowFilter { active?.filter ?? .all }
    public var columns: [DatasetColumn] { active?.columns ?? [] }
    public var visibleColumns: [DatasetColumn] { active?.visibleColumns ?? [] }
    public var selectedRow: DatasetDisplayRow? { active?.selectedRow }
    public var pageCount: Int { active?.pageCount ?? 1 }
    public func isChecked(_ facet: DatasetFacet, _ value: String) -> Bool { active?.isChecked(facet, value) ?? true }

    @ObservationIgnored public private(set) var store: RackyStore?
    /// Título da sessão (sidebar) e se algum computador dela está rodando (atualização a cada 1 s); ligados pelo `AppEnvironment`.
    @ObservationIgnored public var sessionTitle: (UUID) -> String? = { _ in nil }
    /// Agente principal da sessão (o logo e o nome no caminho do dado) e o terminal do worker de um computador ("Codex 1").
    @ObservationIgnored public var sessionAgent: (UUID) -> TerminalProvider? = { _ in nil }
    @ObservationIgnored public var workerTerminal: (String) -> UUID? = { _ in nil }
    @ObservationIgnored public var isRunning: (UUID) -> Bool = { _ in false }
    @ObservationIgnored public var currentPage: () -> CenterPage = { .workspace }
    @ObservationIgnored public var showPage: (CenterPage) -> Void = { _ in }
    @ObservationIgnored public var hidePage: () -> Void = {}
    /// Abre o dataset como tab da sessão dele (`beside` = ao lado do agente). Devolve false se não deu (sem workspace): cai na página.
    @ObservationIgnored public var openInSession: (_ datasetID: String, _ sessionID: UUID, _ beside: Bool) -> Bool = { _, _, _ in false }
    /// Fecha o pane de dataset (`nil` = não está num pane: fecha a página).
    @ObservationIgnored public var closePane: (UUID) -> Void = { _ in }
    /// Sessão aberta no workspace e "o dataset já está numa tab ou pane dela?" (abrir sozinho só quando não está).
    @ObservationIgnored public var currentSession: () -> UUID? = { nil }
    /// Dataset que o módulo Data do painel direito mostra (`nil` = o mais recente da sessão aberta).
    public var panelDatasetID: String?
    /// Mostra o módulo Data no painel direito (abre o painel se estava fechado).
    @ObservationIgnored public var showDataPanel: () -> Void = {}
    @ObservationIgnored public var hideDataPanel: () -> Void = {}
    /// Nome do agente que usa um computador ("Codex 1"), para a faceta Computer.
    @ObservationIgnored public var computerLabel: (String) -> String? = { _ in nil }
    @ObservationIgnored public var isShownInSession: (_ datasetID: String, _ sessionID: UUID) -> Bool = { _, _ in false }
    /// O pane está sozinho na tab (sem agente ao lado); ligado pelo `AppEnvironment`.
    @ObservationIgnored public var paneIsAlone: (_ paneID: UUID) -> Bool = { _ in false }
    /// Tira o pane do dataset da tab dividida e põe numa tab própria; ligado pelo `AppEnvironment`.
    @ObservationIgnored public var detachDataset: (_ datasetID: String) -> Bool = { _ in false }
    /// Abrir a tabela ao lado assim que as primeiras linhas de um dataset novo chegam (uma vez por dataset).
    @ObservationIgnored public var autoOpenEnabled = true
    /// Datasets já abertos sozinhos uma vez (gravado no store: fechar a tabela não faz ela voltar).
    @ObservationIgnored private var autoOpened: Set<String> = []
    @ObservationIgnored private var autoOpenedLoaded = false
    static let autoOpenedKey = "datasets.autoOpened"
    /// Só datasets criados há pouco abrem sozinhos (os antigos não aparecem de surpresa ao abrir o app).
    static let autoOpenWindow: TimeInterval = 600
    @ObservationIgnored public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored public var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// A ação do viewer que abre a evidência de um request (a mesma do painel `Result`).
    @ObservationIgnored public var openEvidence: (_ computer: String, _ requestID: String) async throws -> Void = { _, _ in }
    @ObservationIgnored public var automationEnabled = false
    /// Relógio, fuso e idioma dos textos de data (testes fixam os três para a imagem não depender de quando roda).
    @ObservationIgnored public var now: () -> Date = { Date() }
    @ObservationIgnored public var timeZone: TimeZone = .current
    @ObservationIgnored public var locale: Locale = .current
    @ObservationIgnored private var refresher: Task<Void, Never>?

    public init() {}

    public func attach(store: RackyStore) async {
        self.store = store
        displayNames = (try? await store.uiState(Self.displayNamesKey, as: [String: String].self)) ?? [:]
        await reloadList()
    }

    // MARK: Nome mostrado

    /// Nome que o usuário deu ao dataset (renomear com dois cliques). Os agentes continuam gravando no nome original.
    public private(set) var displayNames: [String: String] = [:]
    static let displayNamesKey = "datasets.displayNames"

    public func displayName(_ summary: DatasetSummary) -> String { displayNames[summary.dataset.id] ?? summary.dataset.name }

    public func rename(_ id: String, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = summaries.first { $0.dataset.id == id }?.dataset.name
        if trimmed.isEmpty || trimmed == original { displayNames[id] = nil } else { displayNames[id] = trimmed }
        try? await store?.setUIState(Self.displayNamesKey, displayNames)
    }

    // MARK: Datas

    /// Idade curta, relativa ao relógio do controlador: `just now`, `12s ago`, `4m ago`, `3h ago`, `yesterday`, depois a data.
    /// Uma data um pouco no futuro (relógios de processos diferentes) conta como agora.
    public func relative(_ date: Date) -> String {
        let seconds = max(Int(now().timeIntervalSince(date)), 0)
        switch seconds {
        case ..<5: return String(localized: "just now", bundle: .module)
        case ..<60: return String(localized: "\(seconds)s ago", bundle: .module)
        case ..<3600: return String(localized: "\(seconds / 60)m ago", bundle: .module)
        case ..<86_400: return String(localized: "\(seconds / 3600)h ago", bundle: .module)
        case ..<172_800: return String(localized: "yesterday", bundle: .module)
        default: return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
        }
    }

    /// Hora na grade e no eixo do gráfico (`22:51:08`, `22:50`).
    public func clock(_ date: Date, seconds: Bool = true) -> String {
        // Hora com dois dígitos: "0:08:15" parecia uma duração.
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour(Self.hourStyle(locale)).minute(.twoDigits)
        return date.formatted(seconds ? style.second(.twoDigits) : style)
    }

    /// 24 h: dois dígitos ("00:08"). 12 h: como o sistema escreve ("7:59 AM").
    static func hourStyle(_ locale: Locale) -> Date.FormatStyle.Symbol.Hour {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return pattern.contains("a") ? .defaultDigits(amPM: .abbreviated) : .twoDigits(amPM: .omitted)
    }

    public func absolute(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, locale: locale, timeZone: timeZone))
    }

    /// Algum computador da sessão do dataset está rodando (o "Collecting" e a atualização a cada segundo).
    public func isCollecting(_ summary: DatasetSummary) -> Bool { isRunning(summary.dataset.sessionID) }

    // MARK: Dados

    public func title(of summary: DatasetSummary) -> String { sessionTitle(summary.dataset.sessionID) ?? String(localized: "Unknown session", bundle: .module) }

    /// Nome do dataset (título da tab), da lista já carregada ou do snapshot de um aberto.
    public func name(of id: String) -> String? {
        displayNames[id] ?? summaries.first { $0.dataset.id == id }?.dataset.name ?? models[id]?.snapshot?.summary.dataset.name
    }

    public func reloadList() async {
        guard let store else { return }
        let loaded = await DatasetLoader.summaries(store: store)
        if loaded != summaries { summaries = loaded }
        listLoaded = true
    }

    /// Contagens novas da sessão aberta entram na lista inteira (que recarrega só a cada 10 s): a sidebar e o painel Data mostram o
    /// mesmo número enquanto o agente coleta.
    func mergeCounts(_ fresh: [DatasetSummary]) {
        guard !fresh.isEmpty else { return }
        var updated = summaries
        for item in fresh {
            if let index = updated.firstIndex(where: { $0.dataset.id == item.dataset.id }) { updated[index] = item }
        }
        if updated != summaries { summaries = updated }
    }

    /// Estado do dataset (cria e carrega na primeira vez).
    public func model(for id: String) -> DatasetViewModel {
        if let existing = models[id] { return existing }
        let created = DatasetViewModel(id: id)
        models[id] = created
        Task { await reload(created) }
        return created
    }

    /// O dataset vira o ativo (o mouse entrou no pane dele): as ações e a automação passam a agir nele.
    public func activate(_ id: String) {
        if currentID != id { currentID = id }
    }

    /// Pane ou tab apareceu / saiu da tela: só os visíveis atualizam.
    public func noteVisible(_ id: String, _ visible: Bool) {
        let m = model(for: id)
        m.visibleCount = max(m.visibleCount + (visible ? 1 : -1), 0)
    }

    func reload(_ m: DatasetViewModel) async {
        guard let store else { return }
        await m.reload(store: store, now: now())
    }

    public func reloadPage() async {
        guard let m = active else { return }
        await reload(m)
    }

    /// Abre o dataset como tab da sessão dele; sem workspace (testes), na página do centro.
    public func open(_ id: String, beside: Bool = false) async -> Bool {
        guard let store, let dataset = try? await store.dataset(id: id) else { return false }
        let m = model(for: id)
        if m.snapshot == nil {
            m.snapshot = DatasetPageSnapshot(summary: DatasetSummary(dataset: dataset, rowCount: 0, invalidCount: 0), rows: [], matching: 0)
        }
        currentID = id
        await reload(m)
        if !openInSession(id, dataset.sessionID, beside) { showPage(.dataset(id)) }
        return true
    }

    /// Carrega o dataset sem abrir nada (a visão geral de uma tabela alimentada por ele precisa dos números).
    public func prepare(_ id: String) async {
        let m = model(for: id)
        if m.snapshot == nil { await reload(m) }
    }

    /// Abre o dataset dentro da área Data (tab da Data, não da sessão): só carrega e ativa.
    public func openInHub(_ id: String) async -> Bool {
        guard let store, let dataset = try? await store.dataset(id: id) else { return false }
        let m = model(for: id)
        if m.snapshot == nil {
            m.snapshot = DatasetPageSnapshot(summary: DatasetSummary(dataset: dataset, rowCount: 0, invalidCount: 0), rows: [], matching: 0)
        }
        currentID = id
        await reload(m)
        return true
    }

    // MARK: Atualização

    /// 1 s com um computador da sessão rodando; 5 s fora disso. Só trabalha nos datasets que estão na tela.
    public func startRefreshing() {
        refresher?.cancel()
        refresher = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                tick += 1
                await self.refreshVisible(tick: tick)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopRefreshing() { refresher?.cancel() }

    func refreshVisible(tick: Int) async {
        // A lista inteira (todas as sessões) a cada 10 s; o "abre sozinho" a cada 2 s olha só a sessão aberta.
        if tick % 2 == 0 { await autoOpenNewData() }
        if tick == 1 || tick % 10 == 0 || (currentPage() == .datasets && !listLoaded) { await reloadList() }
        let pageID = currentPage().datasetID
        for m in models.values where m.visibleCount > 0 || m.id == pageID {
            let running = m.snapshot.map { isRunning($0.summary.dataset.sessionID) } ?? false
            if running || tick % 5 == 0 || m.snapshot == nil { await reload(m) }
        }
    }

    /// Dados começaram a entrar num dataset novo da sessão aberta: o módulo Data abre no painel direito com a tabela ao vivo, sem mexer
    /// na tela do usuário nem no teclado. Uma vez por dataset; fechar o módulo não faz ele voltar.
    func autoOpenNewData() async {
        guard autoOpenEnabled, let store, let session = currentSession() else { return }
        if !autoOpenedLoaded {
            autoOpened = Set((try? await store.uiState(Self.autoOpenedKey, as: [String].self)) ?? [])
            autoOpenedLoaded = true
        }
        let mine = (try? await store.datasetSummaries(sessionID: session)) ?? []
        mergeCounts(mine)
        let now = now()
        for summary in mine where summary.rowCount > 0 && !autoOpened.contains(summary.dataset.id) {
            guard now.timeIntervalSince(summary.dataset.createdAt) <= Self.autoOpenWindow else { continue }
            autoOpened.insert(summary.dataset.id)
            let saved = Array(autoOpened).sorted()
            try? await store.setUIState(Self.autoOpenedKey, saved)
            if isShownInSession(summary.dataset.id, session) { continue }
            await reloadList()
            // No painel direito, no lugar dos Insights: a tela do usuário não muda.
            let m = model(for: summary.dataset.id)
            await reload(m)
            panelDatasetID = summary.dataset.id
            showDataPanel()
        }
    }

    /// Datasets da sessão aberta, mais recente primeiro (módulo Data do painel direito).
    public var sessionSummaries: [DatasetSummary] {
        guard let session = currentSession() else { return [] }
        return summaries.filter { $0.dataset.sessionID == session }
    }

    /// O dataset que o módulo Data mostra: o escolhido, se for da sessão aberta, senão o mais recente dela.
    public var panelSummary: DatasetSummary? {
        let list = sessionSummaries
        return list.first { $0.dataset.id == panelDatasetID } ?? list.first
    }

    // MARK: Ações

    public func register(in registry: ActionRegistry) throws {
        let noDataset = String(localized: "Open a dataset first.", bundle: .module)
        let hasDataset: ActionRegistry.Enablement = { [unowned self] in active == nil ? .disabled(reason: noDataset) : .enabled }
        try registry.register(.pageDatasets) { [unowned self] _ in
            guard currentPage() != .datasets else { return "datasets" }
            // Abre na hora; a lista chega logo depois (antes o clique esperava uma varredura de todas as linhas).
            showPage(.datasets)
            Task { [weak self] in await self?.reloadList() }
            return "datasets"
        }
        try registry.register(.datasetOpen) { [unowned self] arg in
            // `select(<id>)` abre a tab do dataset; `select(<id>|beside)` coloca a tabela ao lado do agente.
            // `<id>|beside` ao lado do agente; `|panel` (pode vir junto) diz que veio da prévia do painel Data.
            let parts = (arg.kind == .select ? arg.value ?? "" : "").split(separator: "|").map(String.init)
            let flags = Set(parts.dropFirst())
            // `<id>|tab`: tira a tabela do lado do agente e devolve para uma tab própria.
            if let id = parts.first, flags.contains("tab") {
                guard detachDataset(id) else { throw ActionError.failed(.datasetOpen, message: String(localized: "No such dataset.", bundle: .module)) }
                return id
            }
            guard let id = parts.first, !id.isEmpty, await open(id, beside: flags.contains("beside")) else {
                throw ActionError.failed(.datasetOpen, message: String(localized: "No such dataset.", bundle: .module))
            }
            // Aberta pelo painel Data: a tabela inteira toma o lugar da prévia, não ficam as duas.
            if flags.contains("panel") { hideDataPanel() }
            return id
        }
        try registry.register(.datasetFilter, enablement: hasDataset) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let filter = DatasetRowFilter(rawValue: raw) else {
                throw ActionError.failed(.datasetFilter, message: "expected select(all|invalid)")
            }
            guard let m = active else { return filter.rawValue }
            m.excluded[.status] = filter == .invalid ? ["valid"] : nil
            m.page = 0
            await reload(m)
            return filter.rawValue
        }
        try registry.register(.datasetSearch, enablement: hasDataset) { [unowned self] arg in
            let text = arg.value ?? ""
            guard let m = active else { return text }
            guard text != m.loadedSearch || m.snapshot == nil else { return text }
            m.search = text
            m.page = 0
            await reload(m)
            return text
        }
        try registry.register(.datasetRange, enablement: hasDataset) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let range = DatasetRange(rawValue: raw) else {
                throw ActionError.failed(.datasetRange, message: "expected select(15m|1h|6h|24h|7d|all)")
            }
            guard let m = active else { return range.rawValue }
            m.range = range
            m.window = nil
            m.page = 0
            await reload(m)
            return range.rawValue
        }
        try registry.register(.datasetTimeWindow, enablement: hasDataset) { [unowned self] arg in
            let raw = arg.kind == .select ? arg.value ?? "" : "clear"
            var window: ClosedRange<Date>?
            if raw != "clear", !raw.isEmpty {
                let parts = raw.split(separator: "-", omittingEmptySubsequences: false).compactMap { Double($0) }
                guard parts.count == 2, parts[0] <= parts[1] else {
                    throw ActionError.failed(.datasetTimeWindow, message: "expected select(<startMs>-<endMs>|clear)")
                }
                window = Date(timeIntervalSince1970: parts[0] / 1000)...Date(timeIntervalSince1970: parts[1] / 1000)
            }
            guard let m = active else { return raw }
            m.window = window
            m.page = 0
            await reload(m)
            return window == nil ? "clear" : raw
        }
        try registry.register(.datasetAddFilter, enablement: hasDataset) { [unowned self] arg in
            let parts = (arg.kind == .select ? arg.value ?? "" : "").split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty, let op = DatasetComparison(rawValue: parts[1]) else {
                throw ActionError.failed(.datasetAddFilter, message: "expected select(<column>|<op>|<value>)")
            }
            guard let m = active else { return "" }
            m.search = DatasetSearchText.adding(column: parts[0], comparison: op, value: parts[2], to: m.search, columns: m.columns)
            m.page = 0
            await reload(m)
            return m.search
        }
        try registry.register(.datasetRemoveFilter, enablement: hasDataset) { [unowned self] arg in
            guard arg.kind == .select, let index = arg.value.flatMap({ Int($0) }), index >= 0 else {
                throw ActionError.failed(.datasetRemoveFilter, message: "expected select(<index>)")
            }
            guard let m = active else { return "" }
            m.search = DatasetSearchText.removing(pillAt: index, from: m.search, columns: m.columns)
            m.page = 0
            await reload(m)
            return m.search
        }
        try registry.register(.datasetColumnRange, enablement: hasDataset) { [unowned self] arg in
            let parts = (arg.kind == .select ? arg.value ?? "" : "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty, parts[1].isEmpty || Double(parts[1]) != nil, parts[2].isEmpty || Double(parts[2]) != nil else {
                throw ActionError.failed(.datasetColumnRange, message: "expected select(<column>|<min>|<max>)")
            }
            guard let m = active else { return "" }
            m.search = DatasetSearchText.replacingRange(column: parts[0], min: Double(parts[1]), max: Double(parts[2]), in: m.search, columns: m.columns)
            m.page = 0
            await reload(m)
            return m.search
        }
        try registry.register(.datasetFacet, enablement: hasDataset) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let colon = raw.firstIndex(of: ":"),
                  let facet = DatasetFacet(rawValue: String(raw[..<colon])) else {
                throw ActionError.failed(.datasetFacet, message: "expected select(<facet>:<value>)")
            }
            let value = String(raw[raw.index(after: colon)...])
            guard let m = active else { return raw }
            if value == "*" {
                if facet == .error { m.errorKinds = [] } else { m.excluded[facet] = nil }
            } else if value.hasPrefix("="), facet != .error {
                // `=valor`: só esse valor ("only" do Datadog); de novo no mesmo valor volta a mostrar todos.
                let only = String(value.dropFirst())
                let others = Set((m.snapshot?.facets[facet] ?? []).map(\.value)).subtracting([only])
                m.excluded[facet] = m.excluded[facet] == others || others.isEmpty ? nil : others
            } else if facet == .error {
                if m.errorKinds.contains(value) { m.errorKinds.remove(value) } else { m.errorKinds.insert(value) }
            } else {
                var set = m.excluded[facet] ?? []
                if set.contains(value) { set.remove(value) } else { set.insert(value) }
                m.excluded[facet] = set.isEmpty ? nil : set
            }
            m.page = 0
            await reload(m)
            return raw
        }
        try registry.register(.datasetFacetsReset, enablement: hasDataset) { [unowned self] _ in
            guard let m = active else { return "" }
            m.excluded = [:]
            m.errorKinds = []
            m.page = 0
            await reload(m)
            return ""
        }
        try registry.register(.datasetPage, enablement: hasDataset) { [unowned self] arg in
            guard let m = active else { return "1" }
            switch arg.value {
            case "next": m.page = min(m.page + 1, m.pageCount - 1)
            case "prev": m.page = max(m.page - 1, 0)
            case "first": m.page = 0
            default: throw ActionError.failed(.datasetPage, message: "expected select(next|prev|first)")
            }
            await reload(m)
            return "\(m.page + 1)"
        }
        try registry.register(.datasetLoadMore, enablement: hasDataset) { [unowned self] _ in
            guard let m = active else { return "1" }
            m.page = min(m.page + 1, m.pageCount - 1)
            await reload(m)
            return "\(m.page + 1)"
        }
        try registry.register(.datasetColumns, enablement: hasDataset) { [unowned self] arg in
            guard arg.kind == .select, let name = arg.value, let m = active, m.columns.contains(where: { $0.name == name }) else {
                throw ActionError.failed(.datasetColumns, message: String(localized: "No such column.", bundle: .module))
            }
            if m.hiddenColumns.contains(name) { m.hiddenColumns.remove(name) } else if m.hiddenColumns.count + 1 < m.columns.count { m.hiddenColumns.insert(name) }
            return m.hiddenColumns.contains(name) ? "hidden" : "shown"
        }
        try registry.register(.datasetSelectRow, enablement: hasDataset) { [unowned self] arg in
            guard let m = active else { return nil }
            m.selectedRowKey = arg.kind == .select ? arg.value.flatMap { $0.isEmpty ? nil : $0 } : nil
            return m.selectedRowKey
        }
        try registry.register(.datasetPanelTab, enablement: hasDataset) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let tab = DatasetPanelTab(rawValue: raw) else {
                throw ActionError.failed(.datasetPanelTab, message: "expected select(attributes|source|history)")
            }
            active?.panelTab = tab
            return tab.rawValue
        }
        try registry.register(.datasetCopyRow, enablement: hasDataset) { [unowned self] arg in
            let key = arg.kind == .select ? arg.value : selectedRowKey
            guard let row = snapshot?.rows.first(where: { $0.row.rowKey == key })?.row else {
                throw ActionError.failed(.datasetCopyRow, message: String(localized: "Select a row first.", bundle: .module))
            }
            let text = String(data: JSON.object(DatasetExporter.decode(row)).data(pretty: true), encoding: .utf8) ?? row.data
            copyText(text)
            return "copied"
        }
        try registry.register(.datasetOpenSource, enablement: hasDataset) { [unowned self] arg in
            let key = arg.value ?? selectedRowKey
            guard let row = snapshot?.rows.first(where: { $0.row.rowKey == key })?.row, let raw = row.sourceURL, let url = Self.webURL(raw) else {
                throw ActionError.failed(.datasetOpenSource, message: String(localized: "This row has no source URL.", bundle: .module))
            }
            openURL(url)
            return url.absoluteString
        }
        try registry.register(.rightPanelDataPick) { [unowned self] arg in
            guard arg.kind == .select, let id = arg.value, summaries.contains(where: { $0.dataset.id == id }) else {
                throw ActionError.failed(.rightPanelDataPick, message: String(localized: "No such dataset.", bundle: .module))
            }
            panelDatasetID = id
            return id
        }
        try registry.register(.datasetExport, enablement: hasDataset) { [unowned self] arg in
            try await export(arg)
        }
    }

    /// Só `http(s)` abre no navegador (o texto da coluna veio de uma página).
    static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func export(_ arg: ActionArgument) async throws -> String {
        guard let store, let id = active?.id, let dataset = try await store.dataset(id: id) else {
            throw ActionError.failed(.datasetExport, message: String(localized: "Open a dataset first.", bundle: .module))
        }
        if arg.kind == .set, let value = arg.value, let split = value.firstIndex(of: "=") {
            guard automationEnabled else { throw ActionError.failed(.datasetExport, message: "Automation is off") }
            guard let format = DatasetExportFormat(rawValue: String(value[..<split])) else { throw ActionError.failed(.datasetExport, message: "expected set(csv|jsonl|json=<path>)") }
            let url = URL(fileURLWithPath: String(value[value.index(after: split)...]))
            try await DatasetExporter.write(store: store, dataset: dataset, format: format.exporter, to: url)
            return url.path
        }
        guard arg.kind == .select, let raw = arg.value, let format = DatasetExportFormat(rawValue: raw) else {
            throw ActionError.failed(.datasetExport, message: "expected select(csv|jsonl|json)")
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DatasetExporter.suggestedName(dataset: dataset.name, format: format.exporter)
        let response = await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in panel.begin { c.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { return "cancelled" }
        try await DatasetExporter.write(store: store, dataset: dataset, format: format.exporter, to: url)
        return url.path
    }
}

extension CenterPage {
    /// Id do dataset da página aberta.
    var datasetID: String? { if case .dataset(let id) = self { id } else { nil } }
}
