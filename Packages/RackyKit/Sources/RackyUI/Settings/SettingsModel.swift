import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation

/// Estado do Settings em página inteira (03 §14): seção aberta, configuração, perfis e agentes detectados.
/// Toda mudança passa por uma ação do registro e salva sozinha (03 §14.1): sem Save nem Apply, com debounce de 300 ms no Store.
@MainActor @Observable
public final class SettingsModel {
    public static let sectionStateKey = "settings.section"

    public private(set) var settings = AppSettings()
    public private(set) var isOpen = false
    public private(set) var section: String
    public private(set) var agents: [AgentInfo] = AgentCatalog.providers.map { AgentInfo(provider: $0) }
    /// Perfis gravados (os prontos entram por `catalog`).
    public private(set) var profiles: [LaunchProfile] = []
    public private(set) var editingProfileID: UUID?
    /// Permissão de notificações do sistema (Settings › Notifications). Só lida; quem a pede é o botão `Allow`.
    public private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    /// Mensagem de validação por campo (`general.worktreeFolder`, `agents.profileArgs`...): o valor salvo continua valendo.
    public private(set) var fieldErrors: [String: String] = [:]
    /// O LaunchAgent do daemon espera aprovação em Itens de Início: o app roda no modo de fallback (06 §1.2) e Settings › General
    /// mostra "Background agents need approval".
    public var backgroundNeedsApproval = false

    /// Estado do Docker e das imagens do computador (Settings › Computers).
    var dockerStatus = DockerStatusInfo()
    /// Runtime dos computadores: o nativo (VMs, sem Docker) serve a este Mac? (Settings › Computers › Computer runtime.)
    var runtimeInfo = ComputerRuntimeInfo()
    /// O runtime nativo (VMs, sem Docker) é o que serve os computadores agora: este Mac o suporta e o usuário não forçou o Docker.
    var usesNativeRuntime: Bool { runtimeInfo.nativeAvailable && !settings.computers.forceDocker }
    /// Página Computers com computadores na lista: a escolha local/nuvem fica recolhida numa faixa até "Change".
    var computersWhereOpen = false
    /// Conta da nuvem (Connect AWS): estado da sessão do `aws login`, hosts vivos e gasto (lidos do `CloudStack` pela fiação).
    var cloudConnection = CloudConnectionState.unknown
    var cloudSnapshot = CloudSnapshot()
    /// "Starting a computer in AWS…" enquanto um host sobe (SSH, imagem); `nil` parado.
    var cloudProgress: String?
    /// Passos da nuvem abertos de novo por "Edit" depois de salvos.
    var cloudEditing = false
    /// A nuvem está escolhida e salva: os computers vão para ela.
    var cloudActive: Bool { settings.computers.runOn == .cloud && settings.computers.cloud.confirmed }
    /// Fiação do app (ComputersWiring): entrar na conta, encerrar um host, encerrar tudo ao sair.
    /// O `aws login` em andamento (cancelável: o navegador pode ter sido fechado e o CLI esperaria 5 min).
    @ObservationIgnored var cloudLoginTask: Task<Void, any Error>?
    @ObservationIgnored var cloudConnect: (@MainActor () async -> Void)?
    @ObservationIgnored var cloudStopHost: (@MainActor (String) async throws -> Void)?
    @ObservationIgnored var cloudShutdown: (@Sendable () async -> Void)?
    /// Abre os links do provedor (testes trocam).
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Proxies de Settings › Computers › Proxies (P13): lista, padrão global, formulário aberto e teste em andamento.
    public internal(set) var proxies: [ProxyProfile] = []
    public internal(set) var defaultProxyID: UUID?
    var proxyDraft: ProxyDraft?
    var proxyTest: ProxyTestState = .idle
    /// Linha com "Delete this proxy?" aberta (confirmação inline).
    var proxyDeleteArmed: UUID?
    /// `.env` do CLI antigo tem chave Zyte e o botão `Import from racky CLI…` aparece (03 §14.2).
    var zyteImportAvailable = false
    var zyteImportArmed = false
    @ObservationIgnored var proxyService: ProxyService?
    @ObservationIgnored var proxyTester: @Sendable (ProxyProfile, String?) async -> ProxyTestResult = { profile, secret in
        await ProxyTester.test(profile: profile, secret: secret)
    }
    @ObservationIgnored var cliEnvFile: URL = ProxyService.defaultCLIEnvFile()

    /// Settings › General › Storage: pastas para medir e limpar, o último tamanho lido e se a medida está em curso.
    @ObservationIgnored var storage: StorageHooks?
    var storageUsage: StorageUsage?
    var storageMeasuring = false

    /// Página Settings › Diagnostics (T4-04): o controlador é do `AppEnvironment`; aqui só a referência fraca.
    @ObservationIgnored weak var diagnostics: DiagnosticsController?

    public let flags: SliceFlags
    @ObservationIgnored let sections: [SettingsSectionSpec]
    @ObservationIgnored public var onPresentationChange: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored public weak var toasts: ToastCenter?
    /// Botão "Allow in Login Items": abre Ajustes do Sistema › Itens de Início. Só por clique.
    @ObservationIgnored public var openLoginItems: @MainActor () -> Void = {}
    @ObservationIgnored var probe: AgentProbe
    @ObservationIgnored var system: SettingsSystemActions
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Notificações do sistema (Fatia 2): ligado pelo `AppEnvironment`. Sem ele a seção mostra a permissão como não pedida.
    @ObservationIgnored public var attention: AttentionCoordinator?

    @ObservationIgnored var store: RackyStore?
    /// `Check Again` do onboarding (todos os agentes): refaz também as sondas de `gh`, Docker e conflitos.
    @ObservationIgnored var onDetectAll: (@MainActor () async -> Void)?
    @ObservationIgnored private var persisted = AppSettings()
    @ObservationIgnored private var pending: [Task<Void, Never>] = []
    @ObservationIgnored private var detecting: [TerminalProvider: Task<Void, Never>] = [:]
    @ObservationIgnored let log = LogFacade(.app, category: "settings")

    public init(
        flags: SliceFlags, probe: @escaping AgentProbe, system: SettingsSystemActions = SettingsSystemActions(),
        sections: [SettingsSectionSpec] = SettingsCatalog.all, implemented: Set<String> = SettingsCatalog.implemented
    ) {
        self.flags = flags
        self.probe = probe
        self.system = system
        self.sections = SettingsCatalog.visible(flags: flags, among: sections, implemented: implemented)
        self.section = self.sections.first?.id ?? "general"
    }

    // MARK: Leitura

    public var visibleSections: [SettingsSectionSpec] { sections }
    public var catalog: ProfileCatalog { ProfileCatalog(userProfiles: profiles) }
    public func agent(_ provider: TerminalProvider) -> AgentInfo? { agents.first { $0.provider == provider } }

    /// Perfis de um provider: os do usuário primeiro, depois os prontos que ele não sobrescreveu.
    public func profiles(for provider: TerminalProvider) -> [LaunchProfile] { catalog.profiles.filter { $0.provider == provider } }

    /// Perfil padrão global efetivo do provider (`ProfileCatalog.resolve`).
    public func defaultProfile(for provider: TerminalProvider) -> LaunchProfile? {
        catalog.resolve(provider: provider, explicitID: nil, projectID: nil)
    }

    public var editingProfile: LaunchProfile? { editingProfileID.flatMap { id in catalog.profiles.first { $0.id == id } } }

    // MARK: Navegação

    /// `app.settings` abre na última seção; `agent.openSettings` abre direto na do agente.
    public func open(section: String? = nil) {
        if let section { select(section) }
        guard !isOpen else { return }
        isOpen = true
        onPresentationChange(true)
        Task { await refreshAgents(force: false) }
        if section == "notifications" { Task { await refreshNotificationAuthorization() } }
        if self.section == "general" { refreshStorage() }
    }

    public func close() {
        guard isOpen else { return }
        // Campo inválido descartado sem perguntar (03 §14.1 regra 3).
        fieldErrors = [:]
        isOpen = false
        onPresentationChange(false)
    }

    @discardableResult
    public func select(_ id: String) -> Bool {
        guard sections.contains(where: { $0.id == id }) else { return false }
        if id != section { editingProfileID = nil }
        section = id
        fieldErrors = [:]
        persistSection()
        if id == "notifications" { Task { await refreshNotificationAuthorization() } }
        if id == "general" { refreshStorage() }
        return true
    }

    /// Lê a permissão atual (nunca abre o diálogo do sistema).
    public func refreshNotificationAuthorization() async {
        notificationAuthorization = await attention?.notificationCenter.authorization() ?? .notDetermined
    }

    /// `notifications.request`: o único caminho que pede a permissão ao sistema, sempre por clique do usuário.
    @discardableResult
    func requestNotificationAuthorization() async -> NotificationAuthorization {
        guard let center = attention?.notificationCenter else { return notificationAuthorization }
        notificationAuthorization = await center.requestAuthorization()
        return notificationAuthorization
    }

    // MARK: Store

    public func attach(store: RackyStore) async {
        self.store = store
        if let saved = try? await store.setting(AppSettings.storeKey, as: AppSettings.self) {
            settings = saved
            persisted = saved
        }
        if let id = try? await store.uiState(Self.sectionStateKey, as: String.self), sections.contains(where: { $0.id == id }) { section = id }
        await reloadProfiles()
        if proxyService == nil {
            proxyService = ProxyService(store: store, vault: SecretVault(store: store, keyring: VaultKeyring(backend: SystemKeychainBackend.system())))
        }
        await reloadProxies()
    }

    func reloadProfiles() async {
        guard let store else { return }
        do { profiles = try await store.profiles() } catch { log.error("could not load launch profiles: \(error)") }
    }

    /// Espera as gravações já agendadas (testes e ⌘Q).
    public func settle() async {
        let tasks = pending
        pending = []
        for task in tasks { await task.value }
        try? await store?.flush()
    }

    private func persistSection() {
        guard let store else { return }
        let id = section
        Task { try? await store.scheduleUIState(Self.sectionStateKey, id) }
    }

    /// Aplica a mudança na hora (o controle reflete o novo valor) e grava com debounce; se a gravação falha, volta ao salvo.
    /// "Don't ask again" do overlay de quit (03 §16.10): desliga `Ask before quitting with running agents`.
    func disableAskBeforeQuit() {
        change("Ask before quitting") { $0.general.askBeforeQuit = false }
    }

    func change(_ name: String, _ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        guard settings != persisted else { return }
        let value = settings
        persisted = value
        guard let store else { return }
        let task = Task { [weak self] in
            do {
                try await store.scheduleSetting(AppSettings.storeKey, value)
            } catch {
                self?.revert(name, error)
            }
        }
        pending.append(task)
    }

    private func revert(_ name: String, _ error: any Error) {
        log.error("could not save setting: \(error)")
        // O que está gravado no banco é o valor anterior; recarrega para o controle mostrar o valor salvo.
        Task { [weak self] in
            guard let self, let store else { return }
            let saved = (try? await store.setting(AppSettings.storeKey, as: AppSettings.self)) ?? AppSettings()
            settings = saved
            persisted = saved
        }
        toasts?.show(kind: .error, title: String(localized: "Couldn't save \(name).", bundle: .module), detail: "\(error)")
    }

    // MARK: Perfis

    private func save(_ profile: LaunchProfile) async throws {
        guard let store else { throw SettingsError.noStore }
        try await store.save(profile)
        await reloadProfiles()
    }

    func newProfile(provider: TerminalProvider) async throws {
        guard provider.isAgent else { throw SettingsError.invalid("Profiles are for Claude Code, Codex and OpenCode.") }
        let names = Set(profiles(for: provider).map(\.name))
        var name = "New profile"
        var n = 2
        while names.contains(name) { name = "New profile \(n)"; n += 1 }
        let profile = LaunchProfile(name: name, provider: provider, createdAt: clock(), updatedAt: clock())
        try await save(profile)
        editingProfileID = profile.id
    }

    func duplicateProfile(id: UUID) async throws {
        guard let source = catalog.profiles.first(where: { $0.id == id }) else { throw SettingsError.invalid("Profile not found.") }
        let copy = source.duplicated(now: clock())
        try await save(copy)
        editingProfileID = copy.id
    }

    func toggleEditing(id: UUID) throws {
        guard let profile = catalog.profiles.first(where: { $0.id == id }) else { throw SettingsError.invalid("Profile not found.") }
        guard !profile.isBuiltin else { throw SettingsError.invalid(Self.builtinEditReason) }
        editingProfileID = editingProfileID == id ? nil : id
        fieldErrors = [:]
    }

    func deleteProfile(id: UUID) async throws {
        guard let profile = catalog.profiles.first(where: { $0.id == id }) else { throw SettingsError.invalid("Profile not found.") }
        guard !profile.isBuiltin else { throw SettingsError.invalid(Self.builtinDeleteReason) }
        guard let store else { throw SettingsError.noStore }
        try await store.deleteProfile(id: id)
        if editingProfileID == id { editingProfileID = nil }
        await reloadProfiles()
    }

    func setDefaultProfile(id: UUID) async throws {
        guard let store else { throw SettingsError.noStore }
        let writes = ProfileDefaults.assigning(profileID: id, saved: profiles, now: clock())
        guard !writes.isEmpty else { throw SettingsError.invalid("Profile not found.") }
        for profile in writes { try await store.save(profile) }
        await reloadProfiles()
    }

    /// Edita o perfil aberto. Valor inválido deixa o salvo como está e mostra a mensagem no campo.
    func editProfile(field: String, _ mutate: (inout LaunchProfile) throws -> Void) async throws {
        guard var profile = editingProfile, !profile.isBuiltin else { throw SettingsError.invalid("Open a profile to edit it.") }
        do { try mutate(&profile) } catch let error as SettingsError {
            if case .invalid(let message) = error { fieldErrors[field] = message }
            throw error
        }
        fieldErrors[field] = nil
        profile.updatedAt = clock()
        try await save(profile)
    }

    static let builtinEditReason = "Built-in profiles can't be edited. Duplicate it to change flags."
    static let builtinDeleteReason = "Built-in profiles can't be deleted."

    // MARK: Campos de texto

    func fail(_ key: String, _ error: SettingsValidationError) -> SettingsError {
        fieldErrors[key] = error.message
        return .invalid(error.message)
    }

    func clearError(_ key: String) { fieldErrors[key] = nil }

    // MARK: Agentes

    /// Refaz a detecção (instalação, versão, login) de todos ou de um. Nunca roda `login`.
    public func refreshAgents(force: Bool, only provider: TerminalProvider? = nil) async {
        let targets = provider.map { [$0] } ?? AgentCatalog.providers
        for p in targets { setAgent(AgentInfo(provider: p, phase: .checking), keepIfKnown: !force) }
        let probe = self.probe
        await withTaskGroup(of: (TerminalProvider, CLIProbeResult).self) { group in
            for p in targets { group.addTask { (p, await probe(p, force)) } }
            for await (p, result) in group { setAgent(AgentInfo(provider: p, result: result), keepIfKnown: false) }
        }
    }

    private func setAgent(_ info: AgentInfo, keepIfKnown: Bool) {
        guard let index = agents.firstIndex(where: { $0.provider == info.provider }) else { return }
        // Primeiro abrir: mostra `Checking…`; reabrir: mantém o último resultado até o novo chegar.
        if keepIfKnown, info.phase == .checking, agents[index].phase != .checking { return }
        agents[index] = info
    }
}

public nonisolated enum AgentCatalog {
    /// Agentes com CLI detectável (03 §14.2). O Blank Terminal é só uma escolha de padrão.
    public static let providers: [TerminalProvider] = [.claude, .codex, .opencode]
}

public nonisolated enum SettingsError: Error, Equatable {
    case invalid(String)
    case noStore
}
