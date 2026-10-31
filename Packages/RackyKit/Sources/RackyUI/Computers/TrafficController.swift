import AppKit
import RackyCore
import RackyProtocol
import SwiftUI

/// O tráfego de cada computador para a aba Computers do painel e a tela Traffic (o "mini Burp"): lê o log de requests e de comandos
/// do run aos poucos (`TrafficLog`), guarda o estado de cada tela (filtro, host, request escolhida, abas) e responde às ações
/// `rightPanel.computersPick`, `computer.openTraffic`, `traffic.set` e `traffic.copyCurl`.
@MainActor
@Observable
public final class TrafficController {
    /// Como a tela Traffic de um computador está: o que filtra, o que está escolhido e qual aba do detalhe aparece.
    public struct ViewState: Equatable, Sendable {
        public var filter = "all"
        public var host: String?
        public var query = ""
        public var selected: String?
        public var requestTab = "headers"
        public var responseTab = "body"
        public var mode = "traffic"
        public var hideNoise = false
        /// No arranjo estreito, qual lado do detalhe aparece (`request` ou `response`).
        public var detailSide = "response"
    }

    public internal(set) var stats: [String: TrafficStats] = [:]
    public internal(set) var entries: [String: [TrafficEntry]] = [:]
    public internal(set) var activity: [String: [ActivityEntry]] = [:]
    public var states: [String: ViewState] = [:]
    /// O computador que a aba Computers mostra (`nil`: o primeiro da sessão) e o filtro da lista ao vivo dela.
    public var panelComputer: String?
    public var panelFilter = "all"
    /// O que o app sabe de cada proxy salvo (pelo nome): o host, que diz o provedor (o logo), e o preço por request.
    public struct ProxyInfo: Equatable, Sendable {
        public var host: String
        public var pricePerRequestMicros: Int64?
        public init(host: String, pricePerRequestMicros: Int64? = nil) { self.host = host; self.pricePerRequestMicros = pricePerRequestMicros }
    }
    public internal(set) var proxies: [String: ProxyInfo] = [:]
    /// Preço por request de cada proxy (micro-dólares), pelo nome; sem preço, o proxy não entra na conta de custo.
    public var prices: [String: Int64] { proxies.compactMapValues(\.pricePerRequestMicros) }
    /// Runs da sessão atual que já terminaram (o computador saiu da lista viva, o log ficou): nome → pasta do run.
    public internal(set) var finished: [String: URL] = [:]

    @ObservationIgnored let computers: ComputersController
    @ObservationIgnored private var logs: [String: TrafficLog] = [:]
    @ObservationIgnored private var polling: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPrices = Date.distantPast
    /// Telas Traffic abertas (a leitura ao vivo segue também para elas).
    @ObservationIgnored var openTraffic: Set<String> = []
    /// Ligados pelo app.
    @ObservationIgnored public var proxySource: () async -> [String: ProxyInfo] = { [:] }
    @ObservationIgnored public var openPane: (_ computer: String) -> Bool = { _ in false }
    @ObservationIgnored public var currentSession: () -> UUID? = { nil }
    /// Menu `Direct` + proxies salvos ancorado no botão `Change` da saída (ligado pelo app).
    @ObservationIgnored public var presentExitMenu: (_ computer: String, _ current: String, _ names: [String]) -> Void = { _, _, _ in }
    /// Runs da sessão atual no disco (`runs/<sessão>/<computador>`), vivos ou não.
    @ObservationIgnored public var sessionRuns: () -> [String: URL] = { [:] }
    @ObservationIgnored public var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public init(computers: ComputersController) { self.computers = computers }

    // MARK: Quais computadores

    /// Computadores da sessão atual (os da sessão que ainda existem); sem sessão, todos.
    public var sessionComputers: [String] {
        let rows = computers.model.rows.map(\.id)
        guard let session = currentSession() else { return rows }
        let mine = rows.filter { computers.model.sessionIDs[$0] == session }
        let done = finished.keys.filter { !mine.contains($0) }.sorted()
        let list = mine + done
        return list.isEmpty ? rows : list
    }

    /// O computador que a aba Computers mostra agora.
    public var shownComputer: String? {
        let list = sessionComputers
        if let picked = panelComputer, list.contains(picked) || entries[picked] != nil { return picked }
        return list.first
    }

    public func state(_ computer: String) -> ViewState { states[computer] ?? ViewState() }

    /// Requests da tela Traffic depois dos filtros, a mais nova primeiro.
    public func visibleEntries(_ computer: String) -> [TrafficEntry] {
        let s = state(computer)
        let query = s.query.trimmingCharacters(in: .whitespaces).lowercased()
        return (entries[computer] ?? []).reversed().filter { e in
            switch s.filter {
            case "all": break
            case "errors": if !e.isError { return false }
            case let key: if let category = TrafficCategory(rawValue: key), e.category != category { return false }
            }
            if s.hideNoise, Self.noise.contains(e.type) { return false }
            if let host = s.host, e.host != host { return false }
            if !query.isEmpty, !(e.url.lowercased().contains(query) || e.host.lowercased().contains(query) || e.method.lowercased() == query
                                 || e.status.map(String.init) == query) { return false }
            return true
        }
    }

    /// Lista ao vivo da aba Computers: as 60 mais novas que passam no filtro dela.
    public func panelEntries(_ computer: String) -> [TrafficEntry] {
        let all = (entries[computer] ?? []).reversed()
        let picked: [TrafficEntry] = switch panelFilter {
        case "api": all.filter { $0.category == .api || $0.category == .page }
        case "errors": all.filter { $0.isError || $0.blocked }
        default: all.filter { $0.category != .asset }
        }
        return Array(picked.prefix(60))
    }

    static let noise: Set<String> = ["script", "stylesheet", "image", "font", "media"]

    public func entry(_ computer: String, _ id: String?) -> TrafficEntry? {
        guard let id else { return nil }
        return entries[computer]?.last { $0.id == id }
    }

    public func body(_ computer: String, _ entry: TrafficEntry, kind: String) -> Data? { logs[computer]?.body(entry, kind: kind) }

    public func cost(_ via: TrafficVia) -> Double? { TrafficStats.cost(via, pricePerRequestMicros: prices[via.name]) }

    // MARK: Leitura ao vivo

    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func tick() async {
        let runs = sessionRuns()
        if runs != finished { finished = runs }
        var names = Set(sessionComputers)
        names.formUnion(openTraffic)
        if let picked = panelComputer { names.insert(picked) }
        for name in names where !polling.contains(name) {
            guard let log = log(for: name) else { continue }
            polling.insert(name)
            // DETACHED: ler e contar milhares de linhas não pode travar a UI.
            let result = await Task.detached(priority: .utility) { () -> (Int, [TrafficEntry], [ActivityEntry], TrafficStats) in
                let fresh = log.poll()
                return (fresh, log.entries, log.activity, TrafficStats.compute(log.entries))
            }.value
            polling.remove(name)
            if result.0 > 0 || entries[name] == nil || activity[name]?.count != result.2.count {
                entries[name] = result.1
                activity[name] = result.2
            }
            if stats[name] != result.3 { stats[name] = result.3 }
        }
        if Date().timeIntervalSince(lastPrices) > 30 {
            lastPrices = Date()
            let next = await proxySource()
            if next != proxies { proxies = next }
        }
    }

    private func log(for name: String) -> TrafficLog? {
        if let log = logs[name] { return log }
        guard let run = computers.runURL(forComputer: name) ?? finished[name] else { return nil }
        let log = TrafficLog(logs: run.appendingPathComponent("logs", isDirectory: true))
        logs[name] = log
        return log
    }

    /// Lê já (as ações e os testes não esperam o próximo ciclo).
    func refresh(_ name: String) async {
        openTraffic.insert(name)
        await tick()
    }

    // MARK: Ações

    /// Pasta do run de um computador vivo ou já terminado (relê a lista da sessão se ainda não conhece o nome).
    func knows(_ name: String) -> Bool {
        if computers.runURL(forComputer: name) != nil || finished[name] != nil { return true }
        finished = sessionRuns()
        return finished[name] != nil
    }

    public func register(in registry: ActionRegistry) throws {
        try registry.register(.rightPanelComputersPick) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard arg.kind == .select, let name = parts.first, !name.isEmpty, knows(name) else {
                throw ActionError.failed(.rightPanelComputersPick, message: String(localized: "No such computer.", bundle: .module))
            }
            panelComputer = name
            if parts.count == 2 { panelFilter = ["api", "errors"].contains(parts[1]) ? parts[1] : "all" }
            await tick()
            return name
        }
        try registry.register(.computerOpenTraffic) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard arg.kind == .select, let name = parts.first, knows(name) else {
                throw ActionError.failed(.computerOpenTraffic, message: String(localized: "No run folder for this computer.", bundle: .module))
            }
            if parts.count == 2 {
                var s = state(name)
                s.selected = parts[1]
                s.mode = "traffic"
                states[name] = s
            }
            await refresh(name)
            guard openPane(name) else {
                throw ActionError.failed(.computerOpenTraffic, message: String(localized: "Open a session first.", bundle: .module))
            }
            return name
        }
        try registry.register(.trafficSet) { [unowned self] arg in
            guard let raw = arg.value, let bar = raw.firstIndex(of: "|") else {
                throw ActionError.failed(.trafficSet, message: "expected select(<computer>|<key>=<value>)")
            }
            let name = String(raw[..<bar])
            let pair = raw[raw.index(after: bar)...].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2 else { throw ActionError.failed(.trafficSet, message: "expected <key>=<value>") }
            var s = state(name)
            switch pair[0] {
            case "filter": s.filter = pair[1] == "errors" || TrafficCategory(rawValue: pair[1]) != nil ? pair[1] : "all"
            case "host": s.host = pair[1].isEmpty || s.host == pair[1] ? nil : pair[1]
            case "query": s.query = pair[1]
            case "select": s.selected = pair[1].isEmpty || s.selected == pair[1] ? nil : pair[1]
            case "requestTab": s.requestTab = pair[1]
            case "responseTab": s.responseTab = pair[1]
            case "mode": s.mode = pair[1] == "activity" ? "activity" : "traffic"
            case "side": s.detailSide = pair[1] == "request" ? "request" : "response"
            case "noise": s.hideNoise = pair[1] == "on" ? true : pair[1] == "off" ? false : !s.hideNoise
            default: throw ActionError.failed(.trafficSet, message: "unknown key \(pair[0])")
            }
            states[name] = s
            return raw
        }
        // A saída do computador escolhida pelo usuário (vale na hora; o egress fecha os túneis abertos).
        try registry.register(.computerSetProxy) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard let name = parts.first, let computer = computers.model.computer(named: name) else {
                throw ActionError.failed(.computerSetProxy, message: String(localized: "This computer has finished.", bundle: .module))
            }
            guard parts.count == 2 else {
                presentExitMenu(name, await computer.proxy, proxies.keys.sorted())
                return "menu"
            }
            let proxy = parts[1]
            guard proxy == "direct" || proxies[proxy] != nil else {
                throw ActionError.failed(.computerSetProxy, message: String(localized: "No such proxy.", bundle: .module))
            }
            do {
                try await computer.switchProxyByUser(to: proxy)
            } catch {
                throw ActionError.failed(.computerSetProxy, message: error.localizedDescription)
            }
            await computers.model.refresh()
            return proxy
        }
        try registry.register(.trafficCopyCurl) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let entry = entry(parts[0], parts[1]) else {
                throw ActionError.failed(.trafficCopyCurl, message: String(localized: "No such request.", bundle: .module))
            }
            copy(entry.curl(body: body(parts[0], entry, kind: "request")))
            return parts[1]
        }
    }
}

extension TrafficController {
    /// `444 B`, `2 KB`, `1.4 MB`: curto, cabe na coluna.
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes < 1_000 { return "\(bytes) B" }
        if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1_000).rounded())) KB" }
        let mb = Double(bytes) / 1_000_000
        return mb < 100 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
    }

    /// `200 OK`, `403 Forbidden`, `429 Too Many Requests` (o texto do sistema dizia "200 No Error").
    static func statusLine(_ code: Int) -> String {
        let names = [200: "OK", 201: "Created", 204: "No Content", 301: "Moved Permanently", 302: "Found", 304: "Not Modified",
                     400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Timeout",
                     409: "Conflict", 429: "Too Many Requests", 500: "Server Error", 502: "Bad Gateway", 503: "Unavailable", 504: "Gateway Timeout"]
        return names[code].map { "\(code) \($0)" } ?? String(code)
    }

    static func money(_ value: Double) -> String {
        value < 0.01 && value > 0 ? "< $0.01" : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
