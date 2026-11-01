import RackyCore
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyStore
@testable import RackyUI

/// Estado, ações e persistência do Settings e do onboarding (T1-26): regra de salvamento de 03 §14.1 (sem Save, debounce de 300 ms,
/// inválido não grava), perfis de lançamento, padrão por agente, deep link e seções por fatia. Store real em pasta temporária.
@MainActor
@Suite(.tags(.integration), .serialized, .offscreenAppKit) struct SettingsModelTests {
    nonisolated final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        func record(_ s: String) { lock.withLock { _calls.append(s) } }
    }

    /// Três estados de CLI: Claude instalado e logado, Codex instalado e deslogado, OpenCode ausente.
    nonisolated static func stub(_ log: ProbeLog = ProbeLog(), codexLoggedIn: @escaping @Sendable () -> Bool = { false }) -> AgentProbe {
        { provider, force in
            log.record("\(provider.rawValue):\(force)")
            switch provider {
            case .claude: return CLIProbeResult(provider: .claude, executable: "/bin/claude", version: CLIVersion(2, 1, 302), login: .loggedIn)
            case .codex:
                return CLIProbeResult(provider: .codex, executable: "/bin/codex", version: CLIVersion(0, 160, 0), login: codexLoggedIn() ? .loggedIn : .loggedOut)
            default: return CLIProbeResult(provider: provider, executable: nil, login: .unknown("not installed"))
            }
        }
    }

    struct Rig {
        let home: URL
        let store: RackyStore
        let model: SettingsModel
        let registry: ActionRegistry
    }

    static func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("racky-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func openStore(_ home: URL, debounce: Duration = .milliseconds(40)) async throws -> RackyStore {
        try await RackyStore.open(paths: StorePaths(root: home), clock: { Date(timeIntervalSince1970: 1_900_000_000) }, debounce: debounce)
    }

    func rig(home: URL? = nil, probe: AgentProbe? = nil, slice: ReleaseSlice = .slice1, system: SettingsSystemActions = SettingsSystemActions()) async throws -> Rig {
        let home = try home ?? Self.tempHome()
        let store = try await Self.openStore(home)
        let flags = SliceFlags(current: slice)
        let model = SettingsModel(flags: flags, probe: probe ?? Self.stub(), system: system)
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try model.registerActions(in: registry)
        await model.attach(store: store)
        return Rig(home: home, store: store, model: model, registry: registry)
    }

    func cleanup(_ rig: Rig) async {
        try? await rig.store.close()
        try? FileManager.default.removeItem(at: rig.home)
    }

    // MARK: Seções por fatia

    @Test func slice1NavShowsOnlyAgentsGeneralTerminal() {
        #expect(SettingsCatalog.visible(flags: SliceFlags(current: .slice1)).map(\.id) == ["agents", "general", "terminal"])
        // Fatias futuras ficam escondidas mesmo com a flag subida, enquanto não têm conteúdo (Notifications entra na Fatia 2).
        #expect(SettingsCatalog.visible(flags: SliceFlags(current: .slice2)).map(\.id) == ["agents", "general", "terminal", "notifications", "diagnostics"])
        #expect(SettingsCatalog.visible(flags: SliceFlags(current: .slice3)).map(\.id) == ["agents", "general", "computers", "terminal", "notifications", "diagnostics"])
        // E uma seção de fatia futura só aparece quando a flag chega à fatia dela.
        let specs = SettingsCatalog.all
        let ids: Set<String> = ["agents", "general", "terminal", "accounts"]
        #expect(!SettingsCatalog.visible(flags: SliceFlags(current: .slice1), among: specs, implemented: ids).contains { $0.id == "accounts" })
        #expect(SettingsCatalog.visible(flags: SliceFlags(current: .slice2), among: specs, implemented: ids).contains { $0.id == "accounts" })
    }

    @Test func groupsFollowTheSpecOrder() {
        let groups = SettingsCatalog.visible(flags: SliceFlags(current: .slice1)).map(\.group)
        #expect(groups == ["Agents", "Workspace", "Interface"])
    }

    // MARK: Salvamento automático

    @Test func changesSaveWithoutSaveButtonAndSurviveReopening() async throws {
        let r = try await rig()
        _ = try await r.registry.perform(.settingsGeneralAskBeforeQuit, .set("off"))
        _ = try await r.registry.perform(.settingsGeneralKeepAgentsRunning, .set("off"))
        _ = try await r.registry.perform(.settingsGeneralWorktreeFolder, .set("~/work/trees/"))
        _ = try await r.registry.perform(.settingsGeneralBranchPrefix, .select("custom"))
        _ = try await r.registry.perform(.settingsGeneralBranchPrefixCustom, .set("alex/"))
        _ = try await r.registry.perform(.settingsTerminalFont, .select("Menlo"))
        _ = try await r.registry.perform(.settingsTerminalCursor, .select("bar"))
        _ = try await r.registry.perform(.settingsTerminalCursorBlink, .set("off"))
        #expect(r.model.settings.general.askBeforeQuit == false, "o controle reflete na hora, antes da gravação")
        await r.model.settle()
        let home = r.home
        try await r.store.close()

        let again = try await Self.openStore(home)
        let model = SettingsModel(flags: SliceFlags(), probe: Self.stub())
        await model.attach(store: again)
        #expect(model.settings.general.askBeforeQuit == false)
        #expect(model.settings.general.keepAgentsRunning == false)
        #expect(model.settings.general.worktreeFolder == "~/work/trees")
        #expect(model.settings.general.branchPrefix == .custom)
        #expect(model.settings.general.branchPrefixCustom == "alex/")
        #expect(model.settings.terminal.fontFamily == "Menlo")
        #expect(model.settings.terminal.cursor == .bar)
        #expect(model.settings.terminal.cursorBlink == false)
        #expect(model.settings.general.cleanSessionFolder == "~/Racky/sessions", "o que não mudou fica no padrão")
        try await again.close()
        try? FileManager.default.removeItem(at: home)
    }

    @Test func stepperTapsCoalesceIntoOneDebouncedWrite() async throws {
        let home = try Self.tempHome()
        let store = try await Self.openStore(home, debounce: .milliseconds(150))
        let flags = SliceFlags()
        let model = SettingsModel(flags: flags, probe: Self.stub())
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try model.registerActions(in: registry)
        await model.attach(store: store)
        let before = await store.debouncedWriteCount
        for _ in 0..<5 { _ = try await registry.perform(.settingsTerminalSize, .select("inc")) }
        #expect(model.settings.terminal.fontSize == 19)
        for task in 0..<20 where await store.debouncedWriteCount == before { _ = task; try await Task.sleep(for: .milliseconds(50)) }
        #expect(await store.debouncedWriteCount == before + 1, "cinco toques, uma gravação")
        let saved = try await store.setting(AppSettings.storeKey, as: AppSettings.self)
        #expect(saved?.terminal.fontSize == 19)
        try await store.close()
        try? FileManager.default.removeItem(at: home)
    }

    @Test func invalidTextKeepsTheSavedValueAndShowsTheMessage() async throws {
        let r = try await rig()
        defer { Task { await cleanup(r) } }
        _ = try await r.registry.perform(.settingsGeneralWorktreeFolder, .set("/tmp/ok"))
        await #expect(throws: ActionError.failed(.settingsGeneralWorktreeFolder, message: "Use an absolute path, starting with / or ~.")) {
            try await r.registry.perform(.settingsGeneralWorktreeFolder, .set("relative"))
        }
        #expect(r.model.settings.general.worktreeFolder == "/tmp/ok", "o valor anterior continua valendo")
        #expect(r.model.fieldErrors["general.worktreeFolder"] == "Use an absolute path, starting with / or ~.")
        _ = try await r.registry.perform(.settingsGeneralWorktreeFolder, .set("~/fine"))
        #expect(r.model.fieldErrors["general.worktreeFolder"] == nil)
        await #expect(throws: ActionError.failed(.settingsTerminalSize, message: "Size must be between 8 and 32.")) {
            try await r.registry.perform(.settingsTerminalSize, .set("7"))
        }
        // Sair do Settings descarta o inválido sem perguntar.
        _ = try? await r.registry.perform(.settingsGeneralWorktreeFolder, .set(""))
        r.model.open()
        r.model.close()
        #expect(r.model.fieldErrors.isEmpty)
    }

    @Test func sizeStopsAtTheLimits() async throws {
        let r = try await rig()
        defer { Task { await cleanup(r) } }
        _ = try await r.registry.perform(.settingsTerminalSize, .set("32"))
        _ = try await r.registry.perform(.settingsTerminalSize, .select("inc"))
        #expect(r.model.settings.terminal.fontSize == 32)
        _ = try await r.registry.perform(.settingsTerminalSize, .set("8"))
        _ = try await r.registry.perform(.settingsTerminalSize, .select("dec"))
        #expect(r.model.settings.terminal.fontSize == 8)
    }

    @Test func customPrefixIsDisabledUntilCustomIsChosen() async throws {
        let r = try await rig()
        defer { Task { await cleanup(r) } }
        #expect(r.registry.availability(of: .settingsGeneralBranchPrefixCustom) == .disabled(reason: "Choose Custom to set a prefix."))
        _ = try await r.registry.perform(.settingsGeneralBranchPrefix, .select("custom"))
        #expect(r.registry.availability(of: .settingsGeneralBranchPrefixCustom) == .enabled)
    }

    @Test func resetConfirmationsTurnsThemBackOn() async throws {
        let r = try await rig()
        defer { Task { await cleanup(r) } }
        _ = try await r.registry.perform(.settingsGeneralAskBeforeQuit, .set("off"))
        _ = try await r.registry.perform(.settingsGeneralConfirmCloseTerminal, .set("off"))
        _ = try await r.registry.perform(.settingsGeneralConfirmDeleteSession, .set("off"))
        _ = try await r.registry.perform(.settingsResetConfirmations, .press)
        let g = r.model.settings.general
        #expect(g.askBeforeQuit && g.confirmCloseTerminal && g.confirmDeleteSession)
    }

    @Test func writeFailureRevertsToTheSavedValueAndToasts() async throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Banco "do futuro": abre somente leitura e toda gravação falha.
        let newer = try await RackyStore.open(
            paths: StorePaths(root: home), clock: { Date() }, debounce: .milliseconds(10), migrations: StoreMigrations.all + [StoreMigration(id: "v2_test") { _ in }])
        try await newer.close()
        let store = try await RackyStore.open(paths: StorePaths(root: home), clock: { Date() }, debounce: .milliseconds(10), migrations: StoreMigrations.all)
        #expect(await store.mode == .readOnly)
        let flags = SliceFlags()
        let model = SettingsModel(flags: flags, probe: Self.stub())
        let toasts = ToastCenter()
        model.toasts = toasts
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try model.registerActions(in: registry)
        await model.attach(store: store)
        _ = try await registry.perform(.settingsGeneralAskBeforeQuit, .set("off"))
        await model.settle()
        for _ in 0..<40 where model.settings.general.askBeforeQuit == false { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.settings.general.askBeforeQuit == true, "o controle volta ao valor salvo")
        #expect(toasts.items.first?.title == "Couldn't save Ask before quitting.")
        #expect(toasts.items.first?.kind == .error)
        try await store.close()
    }

    // MARK: Navegação e deep link

    @Test func settingsOpensOnTheLastSectionAndAgentSettingsDeepLinks() async throws {
        let r = try await rig()
        var presented: [Bool] = []
        r.model.onPresentationChange = { presented.append($0) }
        _ = try await r.registry.perform(.settingsOpenSection, .select("terminal"))
        _ = try await r.registry.perform(.appSettings, .press)
        #expect(r.model.isOpen && r.model.section == "terminal", "app.settings abre na última seção")
        _ = try await r.registry.perform(.settingsBack, .press)
        #expect(!r.model.isOpen)
        _ = try await r.registry.perform(.agentOpenSettings, .press)
        #expect(r.model.isOpen && r.model.section == "agents", "agent.openSettings abre direto em Agents")
        #expect(presented == [true, false, true])
        await #expect(throws: ActionError.failed(.settingsOpenSection, message: "Unknown section docker")) {
            try await r.registry.perform(.settingsOpenSection, .select("docker"))
        }
        await r.model.settle()
        let home = r.home
        try await r.store.close()
        let again = try await Self.openStore(home)
        let second = SettingsModel(flags: SliceFlags(), probe: Self.stub())
        await second.attach(store: again)
        #expect(second.section == "agents", "a seção escolhida é lembrada entre aberturas")
        try await again.close()
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Agentes

    @Test func detectionReportsInstalledLoggedOutAndAbsentWithoutLoggingIn() async throws {
        let log = ProbeLog()
        let r = try await rig(probe: Self.stub(log))
        defer { Task { await cleanup(r) } }
        await r.model.refreshAgents(force: false)
        #expect(r.model.agent(.claude)?.detailText == "2.1.302 · Logged in")
        #expect(r.model.agent(.codex)?.detailText == "0.160.0 · Not logged in")
        #expect(r.model.agent(.codex)?.isLoggedOut == true)
        #expect(r.model.agent(.opencode)?.detailText == "Not installed")
        #expect(r.model.agent(.claude)?.tone == .success && r.model.agent(.codex)?.tone == .warning)
        #expect(Set(log.calls) == ["claude:false", "codex:false", "opencode:false"])
        _ = try await r.registry.perform(.agentDetect, .select("codex"))
        #expect(log.calls.last == "codex:true", "Check Again força a detecção de um agente só")
        _ = try await r.registry.perform(.agentDetect, .press)
        #expect(log.calls.suffix(3).allSatisfy { $0.hasSuffix(":true") })
    }

    @Test func defaultAgentRejectsMissingCLIAndPersistsTheChoice() async throws {
        let r = try await rig()
        await r.model.refreshAgents(force: false)
        await #expect(throws: ActionError.failed(.settingsAgentsDefaultAgent, message: "OpenCode isn't installed.")) {
            try await r.registry.perform(.settingsAgentsDefaultAgent, .select("opencode"))
        }
        _ = try await r.registry.perform(.settingsAgentsDefaultAgent, .select("codex"))
        await r.model.settle()
        let saved = try await r.store.setting(AppSettings.storeKey, as: AppSettings.self)
        #expect(saved?.agents.defaultAgent == .codex)
        _ = try await r.registry.perform(.settingsAgentsDefaultAgent, .select("shell"))
        #expect(r.model.settings.agents.defaultAgent == .shell)
        await cleanup(r)
    }

    @Test func installHelpOpensTheInstallPage() async throws {
        nonisolated final class Opened: @unchecked Sendable { var urls: [URL] = [] }
        let opened = Opened()
        let r = try await rig(system: SettingsSystemActions(pickFolder: { _ in nil }, openURL: { opened.urls.append($0) }))
        defer { Task { await cleanup(r) } }
        _ = try await r.registry.perform(.agentInstallHelp, .select("opencode"))
        #expect(opened.urls == [URL(string: "https://opencode.ai")!])
    }

    @Test func pickPathUsesTheChosenFolderAndIgnoresCancel() async throws {
        let r = try await rig(system: SettingsSystemActions(pickFolder: { _ in "~/Picked" }, openURL: { _ in }))
        defer { Task { await cleanup(r) } }
        _ = try await r.registry.perform(.settingsPickPath, .select("cleanSessionFolder"))
        #expect(r.model.settings.general.cleanSessionFolder == "~/Picked")
        let cancel = try await rig(system: SettingsSystemActions(pickFolder: { _ in nil }, openURL: { _ in }))
        defer { Task { await cleanup(cancel) } }
        let result = try await cancel.registry.perform(.settingsPickPath, .select("worktreeFolder"))
        #expect(result.message == "cancelled")
        #expect(cancel.model.settings.general.worktreeFolder == "~/Racky/worktrees")
    }

    // MARK: Perfis

    @Test func profileLifecycleListCreateDuplicateEditDelete() async throws {
        let r = try await rig()
        defer { Task { await cleanup(r) } }
        // Listar: os prontos do agente, sem os de outro provider.
        let ready = r.model.profiles(for: .claude).map(\.name)
        #expect(ready.contains("Claude · Default") && ready.contains("Claude · Plan") && ready.contains("Claude · Skip permissions"))
        #expect(!ready.contains("Codex · Default"))

        // Criar: um perfil seu, sem bypass, já aberto para edição.
        _ = try await r.registry.perform(.settingsAgentsProfileNew, .select("claude"))
        let created = try #require(r.model.editingProfile)
        #expect(created.name == "New profile" && created.provider == .claude && created.permissionMode == nil && created.skipsPermissions == nil)

        // Editar nome, permissão, modelo e flags permitidas.
        _ = try await r.registry.perform(.settingsAgentsProfileName, .set("Review"))
        _ = try await r.registry.perform(.settingsAgentsProfilePermission, .select("plan"))
        _ = try await r.registry.perform(.settingsAgentsProfileModel, .set("opus"))
        _ = try await r.registry.perform(.settingsAgentsProfileArgs, .set("--add-dir ../shared"))
        var edited = try #require(r.model.editingProfile)
        #expect(edited.name == "Review" && edited.permissionMode == "plan" && edited.model == "opus" && edited.extraArgs == ["--add-dir", "../shared"])

        // Flag fora da lista permitida: nada grava e o campo mostra o motivo.
        await #expect(throws: ActionError.failed(.settingsAgentsProfileArgs, message: "--bare isn't an allowed flag for Claude Code.")) {
            try await r.registry.perform(.settingsAgentsProfileArgs, .set("--bare"))
        }
        #expect(r.model.fieldErrors["agents.profileArgs"] == "--bare isn't an allowed flag for Claude Code.")
        #expect(r.model.editingProfile?.extraArgs == ["--add-dir", "../shared"])
        await #expect(throws: ActionError.failed(.settingsAgentsProfileName, message: "Enter a name.")) {
            try await r.registry.perform(.settingsAgentsProfileName, .set("  "))
        }
        await #expect(throws: ActionError.failed(.settingsAgentsProfilePermission, message: "acceptEdits2 isn't a permission mode for Claude Code.")) {
            try await r.registry.perform(.settingsAgentsProfilePermission, .select("acceptEdits2"))
        }

        // Bypass sempre sinalizado, também ao escolher o modo pelo editor.
        _ = try await r.registry.perform(.settingsAgentsProfilePermission, .select("bypassPermissions"))
        edited = try #require(r.model.editingProfile)
        #expect(edited.skipsPermissions?.flag == "--dangerously-skip-permissions")

        // Persistiu no Store.
        let stored = try await r.store.profiles()
        #expect(stored.count == 1 && stored[0].name == "Review" && stored[0].model == "opus" && stored[0].permissionMode == "bypassPermissions")

        // Duplicar (inclusive um pronto): cópia editável, sem ser padrão.
        _ = try await r.registry.perform(.settingsAgentsProfileDuplicate, .select(BuiltinProfiles.claudeSkipPermissions.id.uuidString))
        let copy = try #require(r.model.editingProfile)
        #expect(copy.name == "Claude · Skip permissions copy" && !copy.isBuiltin && copy.skipsPermissions != nil && !copy.isDefault)
        #expect(try await r.store.profiles().count == 2)

        // Prontos não editam nem apagam.
        await #expect(throws: ActionError.failed(.settingsAgentsProfileEdit, message: "Built-in profiles can't be edited. Duplicate it to change flags.")) {
            try await r.registry.perform(.settingsAgentsProfileEdit, .select(BuiltinProfiles.claudePlan.id.uuidString))
        }
        await #expect(throws: ActionError.failed(.settingsAgentsProfileDelete, message: "Built-in profiles can't be deleted.")) {
            try await r.registry.perform(.settingsAgentsProfileDelete, .select(BuiltinProfiles.claudePlan.id.uuidString))
        }

        // Alternar a edição e apagar.
        _ = try await r.registry.perform(.settingsAgentsProfileEdit, .select(copy.id.uuidString))
        #expect(r.model.editingProfile == nil, "o segundo toque fecha a edição")
        _ = try await r.registry.perform(.settingsAgentsProfileDelete, .select(copy.id.uuidString))
        #expect(try await r.store.profiles().map(\.name) == ["Review"])
        #expect(r.registry.availability(of: .settingsAgentsProfileName) == .disabled(reason: "Open a profile to edit it."))
    }

    @Test func defaultProfilePerAgentPersistsAndResolves() async throws {
        let r = try await rig()
        #expect(r.model.defaultProfile(for: .claude)?.id == BuiltinProfiles.claudeDefault.id)
        _ = try await r.registry.perform(.settingsAgentsProfileNew, .select("claude"))
        let mine = try #require(r.model.editingProfile)
        _ = try await r.registry.perform(.settingsAgentsDefaultProfile, .select("claude:\(mine.id.uuidString)"))
        #expect(r.model.defaultProfile(for: .claude)?.id == mine.id)
        #expect(r.model.defaultProfile(for: .codex)?.id == BuiltinProfiles.codexDefault.id, "outro agente não muda")
        // Um pronto vira o padrão: grava uma cópia com o mesmo ID e desliga o do usuário.
        _ = try await r.registry.perform(.settingsAgentsDefaultProfile, .select("claude:\(BuiltinProfiles.claudePlan.id.uuidString)"))
        #expect(r.model.defaultProfile(for: .claude)?.id == BuiltinProfiles.claudePlan.id)
        let home = r.home
        try await r.store.close()

        let again = try await Self.openStore(home)
        let model = SettingsModel(flags: SliceFlags(), probe: Self.stub())
        await model.attach(store: again)
        #expect(model.defaultProfile(for: .claude)?.id == BuiltinProfiles.claudePlan.id, "o padrão sobrevive à reabertura")
        #expect(model.profiles.filter { $0.provider == .claude && $0.isDefault }.count == 1)
        try await again.close()
        try? FileManager.default.removeItem(at: home)
    }

    @Test func profilesOfTheShellAndInvalidProviderAreRejected() async throws {
        let r = try await rig()
        defer { Task { await cleanup(r) } }
        await #expect(throws: ActionError.failed(.settingsAgentsProfileNew, message: "Profiles are for Claude Code, Codex and OpenCode.")) {
            try await r.registry.perform(.settingsAgentsProfileNew, .select("shell"))
        }
        await #expect(throws: ActionError.failed(.settingsAgentsDefaultProfile, message: "expected <provider>:<profileId>")) {
            try await r.registry.perform(.settingsAgentsDefaultProfile, .select("nope"))
        }
    }

    // MARK: Onboarding

    @Test func onboardingShowsOnFirstRunOnlyAndRemembersDone() async throws {
        let home = try Self.tempHome()
        let store = try await Self.openStore(home)
        let settings = SettingsModel(flags: SliceFlags(), probe: Self.stub())
        let onboarding = OnboardingModel(settings: settings)
        var presents = 0
        onboarding.present = { presents += 1 }
        await onboarding.attach(store: store)
        #expect(presents == 1 && onboarding.isVisible, "primeira abertura mostra o onboarding")
        let registry = ActionRegistry(flags: SliceFlags(), surface: FakeSurface())
        try onboarding.registerActions(in: registry)
        _ = try await registry.perform(.onboardingDone, .press)
        #expect(!onboarding.isVisible && onboarding.record?.outcome == .done)
        try await store.close()

        let again = try await Self.openStore(home)
        let second = OnboardingModel(settings: SettingsModel(flags: SliceFlags(), probe: Self.stub()))
        var secondPresents = 0
        second.present = { secondPresents += 1 }
        await second.attach(store: again)
        #expect(secondPresents == 0 && !second.isVisible, "depois de concluído não volta sozinho")
        let registry2 = ActionRegistry(flags: SliceFlags(), surface: FakeSurface())
        try second.registerActions(in: registry2)
        _ = try await registry2.perform(.appSetup, .press)
        #expect(secondPresents == 1, "Set Up Racky… reabre quando o usuário pede")
        try await again.close()
        try? FileManager.default.removeItem(at: home)
    }

    @Test func skipAsksInlineAndKeepSettingUpGoesBack() async throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try await Self.openStore(home)
        let onboarding = OnboardingModel(settings: SettingsModel(flags: SliceFlags(), probe: Self.stub()))
        var dismisses = 0
        onboarding.dismiss = { dismisses += 1 }
        await onboarding.attach(store: store)
        let registry = ActionRegistry(flags: SliceFlags(), surface: FakeSurface())
        try onboarding.registerActions(in: registry)
        _ = try await registry.perform(.onboardingSkip, .press)
        #expect(onboarding.confirmingSkip && onboarding.isVisible, "Skip for Now pede confirmação inline")
        _ = try await registry.perform(.onboardingKeepSettingUp, .press)
        #expect(!onboarding.confirmingSkip && onboarding.isVisible)
        _ = try await registry.perform(.onboardingSkip, .press)
        _ = try await registry.perform(.onboardingConfirmSkip, .press)
        #expect(!onboarding.isVisible && onboarding.record?.outcome == .skipped && dismisses == 1)
        try await store.close()
    }

    @Test func logInIsDisabledWithReasonUntilAPaneExistsThenRunsTheOfficialCommand() async throws {
        nonisolated final class Ran: @unchecked Sendable { var commands: [[String]] = [] }
        let ran = Ran()
        let loggedIn = Ran()
        let settings = SettingsModel(flags: SliceFlags(), probe: Self.stub(codexLoggedIn: { !loggedIn.commands.isEmpty }))
        let onboarding = OnboardingModel(settings: settings)
        let registry = ActionRegistry(flags: SliceFlags(), surface: FakeSurface())
        try onboarding.registerActions(in: registry)
        await settings.refreshAgents(force: false)
        #expect(registry.availability(of: .accountLogIn) == .disabled(reason: "Terminal panes aren't available yet."))
        await #expect(throws: ActionError.disabled(.accountLogIn, reason: "Terminal panes aren't available yet.")) {
            try await registry.perform(.accountLogIn, .select("codex"))
        }
        onboarding.loginLauncher = { _, command in
            ran.commands.append(command)
            loggedIn.commands.append(command)
        }
        #expect(registry.availability(of: .accountLogIn) == .enabled)
        await #expect(throws: ActionError.failed(.accountLogIn, message: "OpenCode isn't installed.")) {
            try await registry.perform(.accountLogIn, .select("opencode"))
        }
        let result = try await registry.perform(.accountLogIn, .select("codex"))
        #expect(ran.commands == [["codex", "login"]], "o comando oficial, só quando o usuário pede")
        #expect(result.message == "Logged in", "ao fim do login o item vira Logged in sem reiniciar o onboarding (AC-104)")
        #expect(settings.agent(.codex)?.isLoggedOut == false)
        #expect(AgentInfo(provider: .claude).loginCommand == ["claude", "/login"])
        #expect(AgentInfo(provider: .opencode).loginCommand == nil)
    }

    @Test func onboardingListsOnlyWhatSlice1Shows() async throws {
        let onboarding = OnboardingModel(settings: SettingsModel(flags: SliceFlags(), probe: Self.stub()))
        #expect(onboarding.items.map(\.provider) == [.claude, .codex, .opencode])
        #expect(onboarding.isOptional(.opencode) && !onboarding.isOptional(.claude))
    }
}
