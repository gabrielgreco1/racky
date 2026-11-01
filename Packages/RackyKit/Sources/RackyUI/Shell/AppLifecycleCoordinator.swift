import RackyCore
import RackyPlatform
import RackyProtocol
import AppKit
import Foundation

/// ⌘Q com agentes vivos, modo accessory e item da barra de menus (T1-24, 06 §1.9, 03 §16.10 e §17).
///
/// O AppKit pergunta `applicationShouldTerminate`; aqui a pergunta vira uma `QuitDecision` pura (`QuitPolicy`) e o efeito:
/// sair, ficar em segundo plano ou mostrar o overlay dentro da janela (nunca `NSAlert`). O daemon é independente do app:
/// com o LaunchAgent ele é do launchd; no fallback é filho reparentado. Nos dois, sair do app não mata nenhum PTY.
@MainActor
public final class AppLifecycleCoordinator {
    /// Tudo o que o coordenador precisa do resto do app; injetável nos testes.
    public struct Dependencies {
        public var countLive: () async -> LiveProcessCounts
        public var preferences: () -> QuitPreferences
        public var disableAsking: () -> Void
        /// `true` se o overlay de primeira vez já apareceu (P15: o "Don't ask again" vem marcado só na primeira).
        public var promptShownBefore: () async -> Bool
        public var markPromptShown: () -> Void
        public var stopAll: () async -> Void
        public var markCleanExit: () async -> Void
        public var showWindow: () -> Void
        public var hideWindow: () -> Void
        public var terminate: () -> Void
        /// Último recurso de um encerramento por sinal: o processo sai mesmo se o `terminate` do AppKit emperrar.
        public var forceExit: () -> Void

        public init(
            countLive: @escaping () async -> LiveProcessCounts = { LiveProcessCounts() },
            preferences: @escaping () -> QuitPreferences = { QuitPreferences() },
            disableAsking: @escaping () -> Void = {},
            promptShownBefore: @escaping () async -> Bool = { false },
            markPromptShown: @escaping () -> Void = {},
            stopAll: @escaping () async -> Void = {},
            markCleanExit: @escaping () async -> Void = {},
            showWindow: @escaping () -> Void = {},
            hideWindow: @escaping () -> Void = {},
            terminate: @escaping () -> Void = { AppLifecycleCoordinator.requestTermination() },
            forceExit: @escaping () -> Void = { exit(0) }
        ) {
            self.countLive = countLive
            self.preferences = preferences
            self.disableAsking = disableAsking
            self.promptShownBefore = promptShownBefore
            self.markPromptShown = markPromptShown
            self.stopAll = stopAll
            self.markCleanExit = markCleanExit
            self.showWindow = showWindow
            self.hideWindow = hideWindow
            self.terminate = terminate
            self.forceExit = forceExit
        }
    }

    public var dependencies = Dependencies()
    public let menuBar: MenuBarController
    private let overlays: OverlayRouter
    private let log = LogFacade(.app, category: "lifecycle")

    /// Contagem em cache (atualizada a cada snapshot do banco) para decisões síncronas (fechar a janela).
    public private(set) var cachedCounts = LiveProcessCounts()
    public private(set) var isBackgroundOnly = false
    public private(set) var menuVisibility = MenuBarVisibility.whenAgentsRunning
    private var quittingCompletely = false
    private var pendingReason: QuitRequestReason?
    private var pending: Pending?
    /// Quanto esperar a gravação da saída limpa (banco, métricas) antes de sair assim mesmo. O `busy_timeout` do banco é de 5 s por
    /// consulta: sem este teto, várias consultas seguidas somavam ~30 s e o `kill` da instalação virava SIGKILL (sem marca de saída).
    var cleanExitTimeout: Duration = .milliseconds(1500)
    /// Depois deste prazo sem o processo sair, um encerramento por sinal força `exit`.
    var forcedExitDelay: Duration = .seconds(3)
    private var cleanExitMarked = false
    /// Aplica a política de activation do AppKit; trocado nos testes (não mexer na política do processo de teste).
    var applyActivationPolicy: (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }

    private struct Pending {
        var prompt: QuitPrompt
        var model: ConfirmationModel
        var reply: (Bool) -> Void
    }

    public init(registry: ActionRegistry, overlays: OverlayRouter, statusBar: any StatusBarProviding = SystemStatusBar()) {
        menuBar = MenuBarController(registry: registry, statusBar: statusBar)
        self.overlays = overlays
    }

    // MARK: Contagem e ícone

    /// Chamado a cada snapshot do banco com os terminais de todas as sessões.
    public func update(terminals: [Terminal]) {
        cachedCounts = LiveProcessCounts(counting: terminals)
        refreshMenuBar()
    }

    public func refreshMenuBar() {
        menuBar.update(
            MenuBarState(
                counts: cachedCounts, visibility: menuVisibility, isBackgroundOnly: isBackgroundOnly,
                quittingCompletely: quittingCompletely))
    }

    // MARK: Modo accessory

    /// Há agente vivo? Fechar a última janela então não sai do app (06 §1.6).
    public var shouldStayAfterLastWindowClosed: Bool { cachedCounts.agents > 0 }

    /// Keep Running ou janela fechada com agentes vivos: sem Dock, sem janela; o ícone da barra de menus é a porta de volta.
    public func enterBackground() {
        dependencies.hideWindow()
        isBackgroundOnly = true
        applyActivationPolicy(.accessory)
        refreshMenuBar()
        log.publicInfo("entered background (accessory)")
    }

    /// Reabrir pelo item, pelo Dock ou pelo Spotlight.
    public func leaveBackground() {
        isBackgroundOnly = false
        applyActivationPolicy(.regular)
        dependencies.showWindow()
        refreshMenuBar()
    }

    // MARK: Encerrar

    /// `Quit Racky Completely`: encerra o processo e tira o ícone; os agentes seguem no daemon.
    public func quitCompletely() {
        pendingReason = .completely
        quittingCompletely = true
        refreshMenuBar()
        dependencies.terminate()
    }

    /// SIGTERM/SIGINT/SIGHUP ou logout por fora (F30): sai sem perguntar e sem parar nada; daemon e agentes continuam.
    /// Rápido e sem depender de nada que possa travar: marca a saída limpa com teto de tempo, desfaz um overlay de confirmação que
    /// esteja aberto (um segundo `terminate` com o primeiro em `terminateLater` fazia o AppKit sair sem gravar a marca) e, se o
    /// AppKit não encerrar em `forcedExitDelay`, força a saída.
    public func externalTerminationRequested() {
        pendingReason = .system
        quittingCompletely = true
        refreshMenuBar()
        // Fila global, não o main actor: o ponto é sair mesmo com a fila principal presa.
        // SAFETY: o closure só é chamado uma vez, na fila global, e o padrão (`exit(0)`) não toca em estado do app.
        nonisolated(unsafe) let forceExit = dependencies.forceExit
        let parts = forcedExitDelay.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { forceExit() }
        Task { @MainActor in
            await markCleanExitBounded()
            if let waiting = pending {
                pending = nil
                overlays.dismiss(.action)
                waiting.reply(false)  // encerra o `terminateLater` em curso; o `terminate` abaixo começa um ciclo novo
                pendingReason = .system
            }
            dependencies.terminate()
        }
    }

    /// `markCleanExit` com teto: a saída não espera um banco ocupado além de `cleanExitTimeout`. Só grava uma vez por encerramento.
    func markCleanExitBounded() async {
        guard !cleanExitMarked else { return }
        cleanExitMarked = true
        let race = CleanExitRace()
        let work = dependencies.markCleanExit
        let timeout = cleanExitTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            race.continuation = continuation
            Task { @MainActor in
                await work()
                race.finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !race.finished { log.error("clean-exit mark timed out after \(timeout): leaving anyway") }
                race.finish()
            }
        }
    }

    @MainActor private final class CleanExitRace {
        var continuation: CheckedContinuation<Void, Never>?
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// `Stop All Agents…` da barra de menus: abre a janela com a segunda confirmação.
    public func requestStopAll() async -> Bool {
        let counts = await dependencies.countLive()
        guard counts.agents > 0 else { return false }
        if isBackgroundOnly { leaveBackground() } else { dependencies.showWindow() }
        let model = ConfirmationModel.stopAllAndQuit(counts: counts)
        return overlays.present(.confirmation(model), from: nil)
    }

    /// `NSApp.terminate` abre um laço de eventos aninhado até o `reply` de `applicationShouldTerminate`. Chamado de dentro de uma
    /// tarefa do main actor ou de um bloco da fila principal (ação do registro, item de menu), esse laço não consegue rodar as
    /// tarefas que decidem a resposta (a fila principal é serial e está ocupada) e o app trava, com o `ctl` sem resposta (visto
    /// no e2e da T1-24). O pedido sai do contexto atual como bloco do run loop (fonte do run loop, fora da fila principal).
    public nonisolated static func requestTermination() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Motivo do encerramento em curso: logout, reinício e desligamento nunca bloqueiam nem perguntam.
    public nonisolated static func reason(fromAppleEvent event: NSAppleEventDescriptor?) -> QuitRequestReason {
        guard let reason = event?.attributeDescriptor(forKeyword: AEKeyword(0x7768_793F) /* keyReasonAttr 'why?' */)?.enumCodeValue else { return .user }
        switch reason {
        case OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog):
            return .system
        default:
            return .user
        }
    }

    /// `applicationShouldTerminate`: decide e responde por `reply(true)` (sai) ou `reply(false)` (fica).
    public func shouldTerminate(reply: @escaping (Bool) -> Void) {
        let reason = pendingReason ?? Self.reason(fromAppleEvent: NSAppleEventManager.shared().currentAppleEvent)
        pendingReason = nil
        Task { @MainActor in
            // Sinal, logout ou "Quit Completely" nunca perguntam: não consulta o banco (cada consulta pode esperar o busy timeout).
            if reason != .user {
                await carryOut(.quitNow, reply: reply)
                return
            }
            let counts = await dependencies.countLive()
            let askedBefore = await dependencies.promptShownBefore()
            let decision = QuitPolicy.decide(reason: reason, counts: counts, preferences: dependencies.preferences(), askedBefore: askedBefore)
            await carryOut(decision, reply: reply)
        }
    }

    func carryOut(_ decision: QuitDecision, reply: @escaping (Bool) -> Void) async {
        switch decision {
        case .quitNow:
            await markCleanExitBounded()
            reply(true)
        case .keepRunning:
            quittingCompletely = false
            enterBackground()
            reply(false)
        case .stopAllAndQuit:
            await dependencies.stopAll()
            await markCleanExitBounded()
            reply(true)
        case .askUser(let prompt):
            quittingCompletely = false
            present(prompt, reply: reply)
        }
    }

    // MARK: Overlay

    private func present(_ prompt: QuitPrompt, reply: @escaping (Bool) -> Void) {
        if isBackgroundOnly { leaveBackground() } else { dependencies.showWindow() }
        let model = ConfirmationModel.quitWithAgents(prompt: prompt)
        pending = Pending(prompt: prompt, model: model, reply: reply)
        guard overlays.present(.confirmation(model), from: nil) else {
            pending = nil
            reply(false)
            return
        }
        dependencies.markPromptShown()
    }

    /// Botão do overlay (também `ctl ui action dialog.quit.*`).
    public func choose(_ choice: QuitChoice) {
        guard let pending else {
            if choice == .cancel { overlays.dismiss(.action) }  // segunda confirmação aberta pela barra de menus
            return
        }
        let effect = QuitPolicy.apply(choice, prompt: pending.prompt)
        switch choice {
        case .cancel:
            overlays.dismiss(.action)
            self.pending = nil
            pending.reply(false)
        case .stopAll:
            // Na variante com "Keep agents running" ligado, `Stop All and Quit…` abre a segunda confirmação.
            if pending.prompt.keepAgentsRunning {
                overlays.dismiss(.action)
                let second = ConfirmationModel.stopAllAndQuit(counts: pending.prompt.counts)
                self.pending?.model = second
                _ = overlays.present(.confirmation(second), from: nil)
            } else {
                finishStopAll()
            }
        case .keepRunning:
            overlays.dismiss(.action)
            self.pending = nil
            if effect.disableAsking { dependencies.disableAsking() }
            if effect.decision == .keepRunning {
                enterBackground()
                pending.reply(false)
            } else {
                pending.reply(false)
            }
        }
    }

    /// Confirmação final de `Stop All and Quit`.
    public func confirmStopAll() { finishStopAll() }

    private func finishStopAll() {
        overlays.dismiss(.action)
        let reply = pending?.reply
        pending = nil
        Task { @MainActor in
            await dependencies.stopAll()
            await markCleanExitBounded()
            if let reply {
                reply(true)
            } else {
                pendingReason = .completely
                quittingCompletely = true
                dependencies.terminate()
            }
        }
    }

    public func setDontAsk(_ on: Bool) { pending?.model.state.dontAsk = on }
    public var dontAskChecked: Bool { pending?.model.state.dontAsk ?? false }
    public var hasPendingPrompt: Bool { pending != nil }
}
