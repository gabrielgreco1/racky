import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation
import Observation
import SwiftUI

/// Segmentos da status bar que o usuário pode ligar e desligar (03 §5). `background` entra quando o background service
/// chegar à barra; `agents` abre o Inbox em vez de um popover.
enum StatusBarSegment: String, CaseIterable, Sendable {
    case claude, codex, agents, computers, proxyUsage, docker

    var a11yID: A11yID {
        switch self {
        case .claude: .statusBarUsageClaude
        case .codex: .statusBarUsageCodex
        case .agents: .statusBarAgents
        case .computers: .statusBarComputers
        case .proxyUsage: .statusBarProxyUsage
        case .docker: .statusBarDocker
        }
    }

    var menuTitle: String {
        switch self {
        case .claude: String(localized: "Claude usage", bundle: .module)
        case .codex: String(localized: "Codex usage", bundle: .module)
        case .agents: String(localized: "Agents", bundle: .module)
        case .computers: String(localized: "Computers", bundle: .module)
        case .proxyUsage: String(localized: "Proxy usage", bundle: .module)
        case .docker: String(localized: "Computer runtime", bundle: .module)
        }
    }

    var onLeft: Bool { self == .claude || self == .codex }
}

nonisolated struct StatusBarPersisted: Codable, Sendable, Equatable {
    var hidden = false
    var hiddenSegments: [String] = []
}

/// Estado e ações da status bar (03 §5, T4-01). Só lê: o `InsightsService` é a fonte dos limites, das amostras e do uso do proxy;
/// os computadores vêm do `ComputersModel`. Nada aqui agenda amostragem (a leitura dos computadores é avulsa, quando a lista muda).
@MainActor @Observable
final class StatusBarController {
    static let uiStateKey = "statusBar"

    private(set) var content = StatusBarContent()
    private(set) var snapshot = InsightsSnapshot.empty
    private(set) var hidden = false
    private(set) var hiddenSegments: Set<String> = []

    @ObservationIgnored private let service: InsightsService?
    @ObservationIgnored private let computers: ComputersController
    @ObservationIgnored private let overlays: OverlayRouter
    @ObservationIgnored private let elements: UIElementStore
    @ObservationIgnored private let flags: SliceFlags
    @ObservationIgnored var dockerStopped: @MainActor () -> Bool = { false }
    /// Resumo dos agentes (trabalhando / pedindo você), calculado na leitura a partir da fila de atenção; ligado no `AppEnvironment`.
    @ObservationIgnored var agentsSource: @MainActor () -> StatusBarAgents? = { nil }
    @ObservationIgnored var startDocker: @MainActor () -> Void = {}
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored var calendar = Calendar.current
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastLive = -1

    init(insights: InsightsModel, computers: ComputersController, overlays: OverlayRouter, elements: UIElementStore, flags: SliceFlags) {
        self.service = insights.service
        self.computers = computers
        self.overlays = overlays
        self.elements = elements
        self.flags = flags
    }

    /// Modelo estático (previews e snapshots): sem serviço, conteúdo fixo.
    init(
        preview content: StatusBarContent, computers: ComputersController = ComputersController(), overlays: OverlayRouter = OverlayRouter(),
        flags: SliceFlags = SliceFlags(current: .slice4, restricted: false)
    ) {
        self.service = nil
        self.computers = computers
        self.overlays = overlays
        self.elements = UIElementStore()
        self.flags = flags
        self.content = content
    }

    /// Fatia 4 ligada, ou app sem restrição de fatia (padrão do produto). `RACKY_SLICE=1…3` esconde a barra.
    var availableInSlice: Bool { flags.isEnabled(.slice4) || !flags.restricted }
    var isShown: Bool { availableInSlice && !hidden }

    /// Lido direto da fila de atenção (observável), sem cópia: a barra acompanha o Inbox.
    var agents: StatusBarAgents? { agentsSource() }

    func isOn(_ segment: StatusBarSegment) -> Bool { !hiddenSegments.contains(segment.rawValue) }

    func hasData(_ segment: StatusBarSegment) -> Bool {
        switch segment {
        case .claude: content.claude != nil
        case .codex: content.codex != nil
        case .agents: agents != nil
        case .computers: content.computers != nil
        case .proxyUsage: content.proxy != nil
        case .docker: content.dockerProblem
        }
    }

    /// O que a barra mostra agora: segmento ligado e com dado.
    func shows(_ segment: StatusBarSegment) -> Bool { isOn(segment) && hasData(segment) }

    // MARK: Ciclo de vida

    func attach(store: RackyStore) async {
        self.store = store
        if let saved = try? await store.uiState(Self.uiStateKey, as: StatusBarPersisted.self) {
            hidden = saved.hidden
            hiddenSegments = Set(saved.hiddenSegments)
        }
    }

    /// Começa a ler o Insights (uma assinatura, sem timer) e acompanha a lista de computadores.
    func start() {
        guard readTask == nil else { return }
        track()
        guard let service else { return }
        readTask = Task { [weak self] in
            await service.start()
            for await next in await service.subscribe() {
                guard let self else { return }
                self.apply(next)
            }
        }
    }

    func stop() {
        readTask?.cancel(); readTask = nil
        sampleTask?.cancel(); sampleTask = nil
    }

    func apply(_ next: InsightsSnapshot) {
        snapshot = next
        recompute()
    }

    func recompute() {
        content = StatusBarContent.make(snapshot: snapshot, rows: computers.model.rows, dockerStopped: dockerStopped(), now: now(), calendar: calendar)
    }

    /// Recalcula quando os computadores mudam e, se a quantidade de ativos mudou, pede uma leitura avulsa de RAM e CPU.
    private func track() {
        let live = withObservationTracking {
            _ = dockerStopped()
            return computers.model.rows.filter { $0.snapshot.state != .stopped && $0.snapshot.state != .failed }.count
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        recompute()
        guard live != lastLive else { return }
        lastLive = live
        requestComputerSample()
    }

    /// Uma leitura avulsa dos computadores (RAM, CPU). Chamada ao abrir o popover e quando a quantidade muda; nunca em laço.
    func requestComputerSample() {
        guard let service else { return }
        sampleTask?.cancel()
        sampleTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await service.refreshComputers()
        }
    }

    // MARK: Persistência

    private func persist() {
        guard let store else { return }
        let state = StatusBarPersisted(hidden: hidden, hiddenSegments: hiddenSegments.sorted())
        Task { try? await store.setUIState(Self.uiStateKey, state) }
    }

    func setHidden(_ value: Bool) {
        guard value != hidden else { return }
        hidden = value
        persist()
    }

    func toggle(_ segment: StatusBarSegment) {
        if hiddenSegments.contains(segment.rawValue) { hiddenSegments.remove(segment.rawValue) } else { hiddenSegments.insert(segment.rawValue) }
        persist()
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        try registry.register(.viewToggleStatusBar) { [unowned self] _ in
            setHidden(!hidden)
            return hidden ? "hidden" : "shown"
        }
        func segment(_ arg: ActionArgument, _ id: ActionID) throws -> StatusBarSegment {
            guard arg.kind == .select, let raw = arg.value, let seg = StatusBarSegment(rawValue: raw) else {
                throw ActionError.failed(id, message: "expected select(claude|codex|agents|computers|proxyUsage|docker)")
            }
            return seg
        }
        try registry.register(
            .statusBarOpenSegment,
            enablement: { [unowned self] in isShown ? .enabled : .disabled(reason: String(localized: "The status bar is hidden.", bundle: .module)) }
        ) { [unowned self] arg in
            let seg = try segment(arg, .statusBarOpenSegment)
            // `Agents` não tem popover: o clique é a ação do Inbox.
            guard seg != .agents else { throw ActionError.failed(.statusBarOpenSegment, message: String(localized: "Agents opens the Inbox.", bundle: .module)) }
            guard shows(seg) else { throw ActionError.failed(.statusBarOpenSegment, message: String(localized: "Nothing to show yet.", bundle: .module)) }
            if seg == .computers { requestComputerSample() }
            return present(popover: seg) ? seg.rawValue : "busy"
        }
        try registry.register(.statusBarToggleSegment) { [unowned self] arg in
            let seg = try segment(arg, .statusBarToggleSegment)
            toggle(seg)
            return isOn(seg) ? "on" : "off"
        }
    }

    private func present(popover segment: StatusBarSegment) -> Bool {
        let anchor = elements.frame(of: segment.a11yID) ?? .zero
        let width = segment == .computers ? StatusBarMetrics.computersPopover : StatusBarMetrics.popover
        let spec = PopoverSpec(
            name: "statusBar", id: .statusBarPopover(segment.rawValue), anchor: anchor, width: width, alignment: segment.onLeft ? .leading : .trailing
        ) { [unowned self] dismiss in AnyView(StatusBarPopoverContent(controller: self, segment: segment, dismiss: dismiss)) }
        return overlays.presentPopover(spec)
    }

    /// Itens do menu de contexto da barra: um checkbox por segmento e `Hide Status Bar` (03 §5).
    func contextEntries() -> [DSMenuEntry] {
        var entries: [DSMenuEntry] = StatusBarSegment.allCases.map { seg in
            .item(DSMenuItem("segment.\(seg.rawValue)", seg.menuTitle, checked: isOn(seg), action: .statusBarToggleSegment, argument: .select(seg.rawValue)))
        }
        entries.append(.separator("hide"))
        entries.append(.item(DSMenuItem("hide", String(localized: "Hide Status Bar", bundle: .module), action: .viewToggleStatusBar)))
        return entries
    }
}
