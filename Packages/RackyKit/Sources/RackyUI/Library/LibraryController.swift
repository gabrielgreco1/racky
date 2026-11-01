import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Observation

extension SliceFlags {
    /// Controles da Fatia 4: ligados com `RACKY_SLICE=4` ou no app sem restrição de fatia (padrão do produto, F13).
    var offersSlice4: Bool { isEnabled(.slice4) || !restricted }
}

/// Sessão em foco para a Library: onde "Enable in This Session" liga o item.
struct LibrarySessionTarget: Equatable, Sendable {
    var id: UUID
    var title: String
    /// Pasta da sessão: decide se um item de projeto já vale nela ("Always on").
    var folder: String?
}

/// Library só leitura (03 §13, T4-02): Agents, Skills e Profiles. Fonte da verdade são os arquivos nativos dos CLIs; o app indexa
/// por referência (`CatalogService`), mostra o preview lido sob demanda, abre no editor e liga itens só numa sessão
/// (`SessionActivationStore` → plugin gerado no próximo lançamento). Nada é escrito em pasta nativa.
@MainActor @Observable
final class LibraryController {
    enum Section: String, CaseIterable, Sendable {
        case agents, skills, profiles

        var kind: LibraryKind? {
            switch self {
            case .agents: .agent
            case .skills: .skill
            case .profiles: nil
            }
        }
    }

    static let sectionStateKey = "library.section"

    private(set) var items: [LibraryEntry] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    private(set) var section: Section = .agents
    private(set) var query = ""
    private(set) var category: LibraryCategory?
    /// Linha aberta no detalhe: ID do item, ou do perfil.
    private(set) var selectedID: String?
    private(set) var preview: LibraryPreview?
    /// Itens ligados na sessão em foco e o aviso de mudança que espera o próximo lançamento.
    private(set) var added: Set<String> = []
    private(set) var hasPendingChange = false
    private(set) var target: LibrarySessionTarget?

    @ObservationIgnored let activations: SessionActivationStore
    /// Linhas do catálogo (índice do app). Recebe as pastas dos projetos abertos.
    @ObservationIgnored var loadRows: @Sendable ([URL]) async -> [CatalogRow] = { _ in [] }
    @ObservationIgnored var projectRoots: @MainActor () -> [URL] = { [] }
    @ObservationIgnored var currentSession: @MainActor () -> LibrarySessionTarget? = { nil }
    @ObservationIgnored var profiles: @MainActor () -> [LaunchProfile] = { [] }
    /// `Open in Editor` e `Reveal in Finder` (efeitos de sistema, trocáveis nos testes).
    @ObservationIgnored var openFile: @MainActor (URL) async throws -> Void = { _ in }
    @ObservationIgnored var reveal: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored var showPage: @MainActor () -> Void = {}
    @ObservationIgnored var hidePage: @MainActor () -> Void = {}
    @ObservationIgnored var isPageOpen: @MainActor () -> Bool = { false }
    @ObservationIgnored var openSettings: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var changes: Task<Void, Never>?

    init(activations: SessionActivationStore = SessionActivationStore()) { self.activations = activations }

    // MARK: Ciclo de vida

    func attach(store: RackyStore) async {
        self.store = store
        await activations.attach(store: store)
        if let raw = try? await store.uiState(Self.sectionStateKey, as: String.self), let saved = Section(rawValue: raw) { section = saved }
        startObserving()
    }

    /// Reage a mudanças de ativação (Context e Library mostram o mesmo estado) e ao lançamento de um agente.
    func startObserving() {
        guard changes == nil else { return }
        changes = Task { [weak self, activations] in
            for await _ in await activations.changes() {
                guard let self else { return }
                await self.refreshSession()
            }
        }
    }

    /// Relê o índice (a página abriu, ou uma pasta nativa mudou). Itens vêm do catálogo; o preview do arquivo.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        let rows = await loadRows(projectRoots())
        items = LibraryIndex.items(from: rows)
        if let selectedID, section.kind != nil, !items.contains(where: { $0.id == selectedID }) { select(nil) }
        await refreshSession()
        if selectedID == nil { select(firstVisible()?.id) }
    }

    /// Sessão em foco, itens ligados e se há mudança esperando o próximo lançamento.
    func refreshSession() async {
        target = currentSession()
        if let target {
            added = await activations.ids(for: target.id)
            hasPendingChange = await activations.hasPendingChange(session: target.id)
        } else {
            added = []
            hasPendingChange = false
        }
    }

    // MARK: Lista

    var kind: LibraryKind? { section.kind }
    var allOfSection: [LibraryEntry] { kind.map { k in items.filter { $0.kind == k } } ?? [] }
    var visibleItems: [LibraryEntry] { kind.map { LibraryIndex.filter(items, kind: $0, category: category, query: query) } ?? [] }
    var counts: [LibraryCategory: Int] { kind.map { LibraryIndex.counts(items, kind: $0) } ?? [:] }
    var presentCategories: [LibraryCategory] { LibraryCategory.allCases.filter { (counts[$0] ?? 0) > 0 } }
    var selectedItem: LibraryEntry? { selectedID.flatMap { id in items.first { $0.id == id } } }
    var profileList: [LaunchProfile] { profiles() }
    var selectedProfile: LaunchProfile? { selectedID.flatMap { id in profileList.first { $0.id.uuidString == id } } }

    func firstVisible() -> (id: String, _: Void)? {
        if section == .profiles { return profileList.first.map { ($0.id.uuidString, ()) } }
        return visibleItems.first.map { ($0.id, ()) }
    }

    func activation(of item: LibraryEntry) -> LibraryActivation {
        item.activation(sessionFolder: target?.folder, added: added)
    }

    // MARK: Mudanças de estado (as ações chamam estas)

    func setSection(_ value: Section) {
        guard value != section else { return }
        section = value
        category = nil
        query = ""
        select(firstVisible()?.id)
        if let store { Task { try? await store.setUIState(Self.sectionStateKey, value.rawValue) } }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        if let selectedID, !visibleItems.contains(where: { $0.id == selectedID }), section.kind != nil { select(visibleItems.first?.id) }
    }

    func setCategory(_ value: LibraryCategory?) {
        guard value != category else { return }
        category = value
        if let selectedID, !visibleItems.contains(where: { $0.id == selectedID }), section.kind != nil { select(visibleItems.first?.id) }
    }

    func select(_ id: String?) {
        selectedID = id
        previewTask?.cancel()
        preview = nil
        guard let item = selectedItem else { return }
        previewTask = Task { [weak self] in
            let loaded = await LibraryPreviewRunner.load(item)
            guard !Task.isCancelled, let self, self.selectedID == item.id else { return }
            self.preview = loaded
        }
    }

    /// Liga ou desliga um item só na sessão em foco. `nil` = inverte.
    @discardableResult
    func setInSession(_ item: LibraryEntry, on: Bool?) async throws -> Bool {
        guard let target else { throw ActionError.failed(.libraryToggleInSession, message: String(localized: "Select a session first.", bundle: .module)) }
        switch activation(of: item) {
        case .alwaysOn:
            throw ActionError.failed(.libraryToggleInSession, message: String(localized: "Claude Code loads global skills in every session", bundle: .module))
        case .unavailable(let reason):
            throw ActionError.failed(.libraryToggleInSession, message: reason)
        case .thisSession, .off: break
        }
        let want = on ?? !added.contains(item.id)
        await activations.set(ActivationRef(item), on: want, session: target.id)
        await refreshSession()
        return want
    }

    // MARK: Ações

    func item(for arg: ActionArgument, _ action: ActionID) throws -> LibraryEntry {
        if arg.kind == .select, let id = arg.value, !id.isEmpty {
            guard let hit = items.first(where: { $0.id == id }) else { throw ActionError.failed(action, message: String(localized: "No such item.", bundle: .module)) }
            return hit
        }
        guard let selectedItem else { throw ActionError.failed(action, message: String(localized: "Select an item first.", bundle: .module)) }
        return selectedItem
    }

    func register(in registry: ActionRegistry) throws {
        try registry.register(.pageLibrary) { [unowned self] _ in
            if !isPageOpen() { showPage() }
            return "open"
        }
        try registry.register(.librarySetSection) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let value = Section(rawValue: raw) else {
                throw ActionError.failed(.librarySetSection, message: "expected select(agents|skills|profiles)")
            }
            setSection(value)
            return value.rawValue
        }
        try registry.register(.librarySetSearch) { [unowned self] arg in
            guard arg.kind == .set else { throw ActionError.failed(.librarySetSearch, message: "expected set(<text>)") }
            setQuery(arg.value ?? "")
            return "\(visibleItems.count)"
        }
        try registry.register(.librarySetSource) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value else { throw ActionError.failed(.librarySetSource, message: "expected select(all|<source>)") }
            if raw == "all" { setCategory(nil); return "all" }
            guard let value = LibraryCategory(rawValue: raw) else { throw ActionError.failed(.librarySetSource, message: "unknown source \(raw)") }
            setCategory(value)
            return value.rawValue
        }
        try registry.register(.librarySelectItem) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, !raw.isEmpty else { throw ActionError.failed(.librarySelectItem, message: "expected select(<id>)") }
            guard items.contains(where: { $0.id == raw }) || profileList.contains(where: { $0.id.uuidString == raw }) else {
                throw ActionError.failed(.librarySelectItem, message: String(localized: "No such item.", bundle: .module))
            }
            select(raw)
            return raw
        }
        try registry.register(
            .libraryToggleInSession,
            enablement: { [unowned self] in
                target == nil ? .disabled(reason: String(localized: "Select a session first.", bundle: .module)) : .enabled
            }
        ) { [unowned self] arg in
            let item = try item(for: arg, .libraryToggleInSession)
            let want = arg.kind == .set ? arg.value.map { $0 == "on" } : nil
            return try await setInSession(item, on: want) ? "on" : "off"
        }
        try registry.register(.libraryOpenInEditor) { [unowned self] arg in
            let item = try item(for: arg, .libraryOpenInEditor)
            do { try await openFile(item.url) } catch let error as ActionError { throw error } catch {
                throw ActionError.failed(.libraryOpenInEditor, message: error.localizedDescription)
            }
            return item.path
        }
        try registry.register(.libraryReveal) { [unowned self] arg in
            let item = try item(for: arg, .libraryReveal)
            reveal(item.url)
            return item.path
        }
        try registry.register(.libraryEditProfiles) { [unowned self] _ in
            openSettings("agents")
            return "agents"
        }
    }
}

/// Lê o preview fora da thread principal (arquivos de skill podem ser grandes).
enum LibraryPreviewRunner {
    static func load(_ item: LibraryEntry) async -> LibraryPreview {
        await BlockingIOBridge.run { LibraryPreviewLoader.load(item) }
    }
}
