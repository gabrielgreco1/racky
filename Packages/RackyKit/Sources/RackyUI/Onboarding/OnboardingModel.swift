import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation
import Synchronization

/// Registro gravado quando o onboarding termina (Done ou Skip). Sem ele, a primeira abertura mostra o overlay.
public nonisolated struct OnboardingRecord: Codable, Equatable, Sendable {
    public nonisolated enum Outcome: String, Codable, Sendable { case done, skipped }
    public var outcome: Outcome
    public var at: Date
}

/// Escolha para a skill global `racky`, compartilhada com a sonda de conflitos (que roda fora da main).
public nonisolated final class ConflictChoiceBox: Sendable {
    private let state: Mutex<ConflictChoice?>
    public init(_ choice: ConflictChoice? = nil) { state = Mutex(choice) }
    public var value: ConflictChoice? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Onboarding (03 §15): checklist de diagnóstico não bloqueante. Os CLIs de agente vêm do Settings (`SettingsModel.agents`:
/// instalado, versão e login, sem nunca rodar `login`); `gh`, Docker, imagem e conflitos vêm do `DiagnosticsEngine`.
@MainActor @Observable
public final class OnboardingModel {
    public static let storeKey = "onboarding.state"
    public static let choiceKey = "onboarding.conflictChoice"

    public private(set) var isVisible = false
    /// `Skip setup?` inline (03 §15): `Keep Setting Up` / `Skip`.
    public private(set) var confirmingSkip = false
    public private(set) var record: OnboardingRecord?
    /// Itens além dos CLIs (gh, Docker, imagem, conflitos), na ordem de 03 §15. Vazio sem motor de diagnóstico.
    public private(set) var diagnostics: [DiagnosticKey: DiagnosticItem] = [:]
    /// `Disable Globally…` pede confirmação inline antes de mover a skill para o backup.
    public private(set) var confirmingDisable = false

    let settings: SettingsModel
    @ObservationIgnored let engine: DiagnosticsEngine?
    @ObservationIgnored let conflictChoice: ConflictChoiceBox
    @ObservationIgnored let backup: GlobalSkillBackup?
    @ObservationIgnored var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private var checked = false
    @ObservationIgnored private let log = LogFacade(.app, category: "onboarding")

    /// Abre o terminal inline com o comando oficial de login (`claude /login`, `codex login`). Sem painel de terminal
    /// disponível (T1-14 ainda não existe nesta base) fica nulo e `account.logIn` aparece desabilitado com o motivo.
    @ObservationIgnored public var loginLauncher: (@MainActor (TerminalProvider, [String]) async -> Void)?
    @ObservationIgnored var present: @MainActor () -> Void = {}
    @ObservationIgnored var dismiss: @MainActor () -> Void = {}

    public init(
        settings: SettingsModel, diagnostics engine: DiagnosticsEngine? = nil, conflictChoice: ConflictChoiceBox = ConflictChoiceBox(),
        backup: GlobalSkillBackup? = nil
    ) {
        self.settings = settings
        self.engine = engine
        self.conflictChoice = conflictChoice
        self.backup = backup
        settings.onDetectAll = { [weak self] in await self?.runDiagnostics(force: true) }
    }

    public static let loginUnavailableReason = "Terminal panes aren't available yet."

    // MARK: Ciclo de vida

    /// Liga ao Store e abre o onboarding se for a primeira abertura (sem registro gravado).
    public func attach(store: RackyStore, forceVisible: Bool = false) async {
        self.store = store
        record = try? await store.setting(Self.storeKey, as: OnboardingRecord.self)
        if let saved = try? await store.setting(Self.choiceKey, as: ConflictChoice.self) { conflictChoice.value = saved }
        guard !checked else { return }
        checked = true
        if record == nil || forceVisible { show() }
    }

    /// `app.setup`: abre o onboarding quando o usuário pede (menu do app, Diagnostics).
    public func show() {
        guard !isVisible else { return }
        isVisible = true
        confirmingSkip = false
        present()
        Task { await settings.refreshAgents(force: false) }
        Task { await runDiagnostics(force: false) }
    }

    /// Fecha o overlay sem registrar nada (o usuário foi para o Settings; o onboarding volta na próxima abertura).
    public func hide() {
        guard isVisible else { return }
        isVisible = false
        confirmingSkip = false
        dismiss()
    }

    func finish(_ outcome: OnboardingRecord.Outcome) async {
        let value = OnboardingRecord(outcome: outcome, at: clock())
        record = value
        if let store {
            do { try await store.setSetting(Self.storeKey, value) } catch { log.error("could not save onboarding state: \(error)") }
        }
        hide()
    }

    // MARK: Itens da checklist

    /// Os CLIs de agente: Claude Code, Codex e OpenCode (opcional).
    public var items: [AgentInfo] { settings.agents }

    public func isOptional(_ provider: TerminalProvider) -> Bool { provider == .opencode }

    /// Itens além dos CLIs que a fatia atual mostra: `gh` desde a Fatia 2, Docker e imagem desde a 3 (03 §15); conflitos só se houver.
    public var diagnosticItems: [DiagnosticItem] {
        DiagnosticKey.allCases.compactMap { key in
            switch key {
            case .gh where !settings.flags.isEnabled(.slice2): return nil
            case .runtime where !settings.flags.isEnabled(.slice3), .docker where !settings.flags.isEnabled(.slice3),
                .image where !settings.flags.isEnabled(.slice3): return nil
            default: return diagnostics[key]
            }
        }
    }

    /// Roda as sondas (paralelas, com timeout e cache no motor) e atualiza cada item assim que chega.
    public func runDiagnostics(force: Bool, keys: Set<DiagnosticKey> = Set(DiagnosticKey.allCases)) async {
        guard let engine else { return }
        let updates = AsyncStream<(DiagnosticKey, DiagnosticItem?)>.makeStream()
        let runner = Task {
            await engine.run(keys, force: force) { updates.continuation.yield(($0, $1)) }
            updates.continuation.finish()
        }
        for await (key, item) in updates.stream { diagnostics[key] = item }
        await runner.value
    }

    /// Secundárias sem repetir a primária (sem terminal, `Log In` já virou `Copy Command`).
    public func secondaryFixes(of item: DiagnosticItem) -> [DiagnosticFix] {
        let primary = item.fix.map(effective)
        return item.secondaryFixes.filter { effective($0) != primary }
    }

    /// A correção que a UI mostra de fato: sem painel de terminal, `Log In` vira `Copy Command` (o usuário cola no Terminal).
    public func effective(_ fix: DiagnosticFix) -> DiagnosticFix {
        if case .logIn(let command) = fix, loginLauncher == nil { return .copyCommand(command.joined(separator: " ")) }
        return fix
    }

    // MARK: Ações

    func registerActions(in registry: ActionRegistry) throws {
        try registry.register(.appSetup) { [unowned self] _ in
            show()
            return "opened"
        }
        try registry.register(.onboardingSkip) { [unowned self] _ in
            confirmingSkip = true
            return "confirming"
        }
        try registry.register(.onboardingKeepSettingUp) { [unowned self] _ in
            confirmingSkip = false
            return "kept"
        }
        try registry.register(.onboardingConfirmSkip) { [unowned self] _ in
            await finish(.skipped)
            return "skipped"
        }
        try registry.register(.onboardingDone) { [unowned self] _ in
            await finish(.done)
            return "done"
        }
        try registry.register(
            .accountLogIn,
            enablement: { [unowned self] in loginLauncher == nil ? .disabled(reason: Self.loginUnavailableReason) : .enabled }
        ) { [unowned self] arg in
            if arg.value == "gh" {
                guard let launcher = loginLauncher else { throw ActionError.failed(.accountLogIn, message: Self.loginUnavailableReason) }
                await launcher(.shell, DiagnosticsEvaluator.ghLoginCommand)
                await runDiagnostics(force: true, keys: [.gh])
                return diagnostics[.gh]?.detail
            }
            guard let raw = arg.value, let provider = TerminalProvider(rawValue: raw), let info = settings.agent(provider) else {
                throw ActionError.failed(.accountLogIn, message: "unknown agent")
            }
            guard info.isInstalled else { throw ActionError.failed(.accountLogIn, message: "\(info.displayName) isn't installed.") }
            guard let command = info.loginCommand else {
                throw ActionError.failed(.accountLogIn, message: "\(info.displayName) has no login command.")
            }
            guard let launcher = loginLauncher else { throw ActionError.failed(.accountLogIn, message: Self.loginUnavailableReason) }
            await launcher(provider, command)
            // Ao fim do login o item vira "Logged in" sem reiniciar o onboarding (AC-104).
            await settings.refreshAgents(force: true, only: provider)
            return settings.agent(provider)?.statusText
        }
        try registerDiagnosticActions(in: registry)
    }
}

// MARK: Diagnóstico: Retry, Copy Command e conflitos (03 §15, §24.6)

extension OnboardingModel {
    private func key(_ arg: ActionArgument, _ id: ActionID) throws -> DiagnosticKey {
        guard arg.kind == .select, let raw = arg.value, let key = DiagnosticKey(rawValue: raw) else {
            throw ActionError.failed(id, message: "expected select(gh|docker|image|conflicts)")
        }
        return key
    }

    private func saveChoice(_ choice: ConflictChoice) async {
        conflictChoice.value = choice
        guard let store else { return }
        do { try await store.setSetting(Self.choiceKey, choice) } catch { log.error("could not save conflict choice: \(error)") }
    }

    func registerDiagnosticActions(in registry: ActionRegistry) throws {
        try registry.register(.onboardingRetry) { [unowned self] arg in
            let key = try key(arg, .onboardingRetry)
            // A imagem depende do Docker: o motor refaz os dois juntos.
            await runDiagnostics(force: true, keys: [key])
            return diagnostics[key]?.detail
        }
        try registry.register(.onboardingCopyCommand) { [unowned self] arg in
            let key = try key(arg, .onboardingCopyCommand)
            guard let item = diagnostics[key] else { throw ActionError.failed(.onboardingCopyCommand, message: "Nothing to copy.") }
            let command = ([item.fix].compactMap { $0 } + item.secondaryFixes).lazy.compactMap { fix -> String? in
                switch self.effective(fix) {
                case .copyCommand(let text): text
                default: nil
                }
            }.first
            guard let command else { throw ActionError.failed(.onboardingCopyCommand, message: "Nothing to copy.") }
            copyToPasteboard(command)
            settings.toasts?.show(kind: .success, title: String(localized: "Command copied.", bundle: .module))
            return command
        }
        // "Block in Racky" é o padrão: o lançamento já nega a skill (`permissions.deny`), nada global muda.
        try registry.register(.conflictBlock) { [unowned self] _ in
            await saveChoice(.block)
            await runDiagnostics(force: true, keys: [.conflicts])
            return "blocked"
        }
        try registry.register(.conflictKeep) { [unowned self] _ in
            confirmingDisable = false
            await saveChoice(.keep)
            await runDiagnostics(force: true, keys: [.conflicts])
            return "kept"
        }
        // Mover para o backup pede confirmação: o primeiro clique só pergunta; `select(confirm)` executa, `select(cancel)` volta.
        try registry.register(
            .conflictDisableGlobal,
            enablement: { [unowned self] in backup == nil ? .disabled(reason: "The skill can't be moved right now.") : .enabled }
        ) { [unowned self] arg in
            guard let backup else { throw ActionError.failed(.conflictDisableGlobal, message: "The skill can't be moved right now.") }
            switch arg.value {
            case "confirm":
                confirmingDisable = false
                do { try backup.disable() } catch {
                    throw ActionError.failed(.conflictDisableGlobal, message: "Couldn't move the skill: \(error).")
                }
                await runDiagnostics(force: true, keys: [.conflicts])
                return "disabled"
            case "cancel":
                confirmingDisable = false
                return "cancelled"
            default:
                confirmingDisable = true
                return "confirming"
            }
        }
        try registry.register(
            .conflictRestore,
            enablement: { [unowned self] in backup?.hasBackup == true ? .enabled : .disabled(reason: "There's no backup to restore.") }
        ) { [unowned self] _ in
            guard let backup else { throw ActionError.failed(.conflictRestore, message: "There's no backup to restore.") }
            do { try backup.restore() } catch {
                throw ActionError.failed(.conflictRestore, message: "Couldn't restore the skill: \(error).")
            }
            await runDiagnostics(force: true, keys: [.conflicts])
            return "restored"
        }
    }
}
