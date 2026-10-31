import RackyCore
import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Fluxo de ⌘Q com agentes vivos (T1-24): overlay "Keep Running" na janela, accessory, "Stop All and Quit…" e a barra de menus.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct AppLifecycleTests {
    /// Registro de tudo o que o coordenador pediu ao resto do app.
    final class Probe {
        var counts = LiveProcessCounts(agents: 3, shells: 2)
        var preferences = QuitPreferences()
        var shownBefore = false
        var disabledAsking = 0
        var promptMarked = 0
        var stopAllCalls = 0
        var cleanExits = 0
        var shown = 0
        var hidden = 0
        var terminated = 0
        var forcedExits = 0
        var countLiveCalls = 0
        var policies: [NSApplication.ActivationPolicy] = []
        var replies: [Bool] = []
    }

    private func make() -> (AppEnvironment, AppLifecycleCoordinator, Probe) {
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1"])
        let probe = Probe()
        let lifecycle = env.lifecycle!
        lifecycle.dependencies = AppLifecycleCoordinator.Dependencies(
            countLive: { probe.countLiveCalls += 1; return probe.counts }, preferences: { probe.preferences }, disableAsking: { probe.disabledAsking += 1 },
            promptShownBefore: { probe.shownBefore }, markPromptShown: { probe.promptMarked += 1 },
            stopAll: { probe.stopAllCalls += 1 }, markCleanExit: { probe.cleanExits += 1 },
            showWindow: { probe.shown += 1 }, hideWindow: { probe.hidden += 1 }, terminate: { probe.terminated += 1 },
            forceExit: { probe.forcedExits += 1 })
        lifecycle.forcedExitDelay = .seconds(600)  // nunca dispara no teste (o padrão chamaria `exit`)
        lifecycle.applyActivationPolicy = { probe.policies.append($0) }
        return (env, lifecycle, probe)
    }

    private func press(_ env: AppEnvironment, _ id: ActionID, _ argument: ActionArgument = .press) async throws {
        _ = try await env.registry.perform(id, argument)
    }

    private func decide(_ lifecycle: AppLifecycleCoordinator, probe: Probe) async {
        let reply: (Bool) -> Void = { probe.replies.append($0) }
        let decision = QuitPolicy.decide(
            reason: .user, counts: probe.counts, preferences: probe.preferences, askedBefore: probe.shownBefore)
        await lifecycle.carryOut(decision, reply: reply)
    }

    // MARK: F30: sinais externos = Keep Running

    @Test func externalTerminationQuitsWithoutStoppingAgentsOrAsking() async throws {
        let (_, lifecycle, probe) = make()
        // O mock do `terminate` do AppKit chama `shouldTerminate`, como o `NSApp.terminate` real.
        lifecycle.dependencies.terminate = { probe.terminated += 1 }
        lifecycle.externalTerminationRequested()
        for _ in 0..<500 where probe.terminated == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.terminated == 1)
        #expect(probe.cleanExits == 1, "a marca de saída limpa sai antes do terminate")
        let reply: (Bool) -> Void = { probe.replies.append($0) }
        lifecycle.shouldTerminate(reply: reply)
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.replies == [true], "sai sem overlay")
        #expect(probe.stopAllCalls == 0, "SIGTERM no app nunca para os agentes")
        #expect(probe.cleanExits == 1, "uma só gravação por encerramento")
        #expect(probe.countLiveCalls == 0, "sinal não consulta o banco: cada consulta pode esperar o busy timeout")
        #expect(!lifecycle.hasPendingPrompt)
    }

    @Test func externalTerminationDoesNotWaitForASlowCleanExitMark() async throws {
        let (_, lifecycle, probe) = make()
        lifecycle.cleanExitTimeout = .milliseconds(100)
        var markFinished = false
        lifecycle.dependencies.markCleanExit = { probe.cleanExits += 1; try? await Task.sleep(for: .seconds(30)); markFinished = true }
        lifecycle.externalTerminationRequested()
        for _ in 0..<500 where probe.terminated == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.terminated == 1, "o banco ocupado não segura o SIGTERM: sai pelo teto de tempo")
        #expect(!markFinished)
    }

    @Test func externalTerminationWithOpenQuitOverlayCancelsItAndStillMarksCleanExit() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)  // ⌘Q com agentes: overlay aberto, AppKit em terminateLater
        #expect(lifecycle.hasPendingPrompt)
        lifecycle.externalTerminationRequested()
        for _ in 0..<500 where probe.terminated == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.replies == [false], "o ciclo do ⌘Q pendente é encerrado antes de pedir outro terminate")
        #expect(!lifecycle.hasPendingPrompt)
        #expect(env.overlays.top == nil)
        #expect(probe.cleanExits == 1)
        #expect(probe.terminated == 1)
        lifecycle.shouldTerminate { probe.replies.append($0) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.replies == [false, true], "o segundo ciclo sai sem perguntar")
    }

    @Test func externalTerminationForcesExitWhenAppKitNeverFinishes() async throws {
        let (_, lifecycle, probe) = make()
        lifecycle.forcedExitDelay = .milliseconds(100)
        lifecycle.externalTerminationRequested()
        for _ in 0..<500 where probe.forcedExits == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.forcedExits == 1)
    }

    @Test func userQuitStillCountsAndAsks() async throws {
        let (_, lifecycle, probe) = make()
        lifecycle.shouldTerminate { probe.replies.append($0) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.countLiveCalls == 1, "⌘Q (usuário) continua contando e perguntando")
        #expect(lifecycle.hasPendingPrompt)
        #expect(probe.replies.isEmpty)
    }

    @Test func sigtermSigintAndSighupReachTheHandlerAndDoNotKillTheProcess() async throws {
        var received: [Int32] = []
        let signals = ExternalTerminationSignals { received.append($0) }
        signals.install()
        defer { signals.uninstall() }
        for number in ExternalTerminationSignals.signals { kill(getpid(), number) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(Set(received) == Set(ExternalTerminationSignals.signals), "o processo sobreviveu e o app tratou como Keep Running")
    }

    // MARK: Overlay

    @Test func firstQuitShowsTheOverlayWithDontAskPreCheckedAndNeverAnAlert() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)
        let top = try #require(env.overlays.top)
        #expect(top.spec.name == "confirmQuit")
        #expect(top.spec.id == .overlayConfirmQuit)
        #expect(lifecycle.dontAskChecked, "P15: o primeiro ⌘Q já vem com Don't ask again marcado")
        #expect(probe.shown == 1, "o overlay vive dentro da janela")
        #expect(probe.promptMarked == 1)
        #expect(probe.replies.isEmpty, "o AppKit espera a resposta do usuário")
    }

    @Test func keepRunningWithDontAskSwitchesToAccessoryAndTurnsAskingOff() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)
        try await press(env, .dialogQuitKeepRunning)
        #expect(probe.replies == [false], "o app não sai")
        #expect(probe.disabledAsking == 1)
        #expect(probe.hidden == 1)
        #expect(probe.policies == [.accessory])
        #expect(lifecycle.isBackgroundOnly)
        #expect(lifecycle.menuBar.state.isVisible, "em accessory o ícone é a única porta de volta")
        #expect(probe.stopAllCalls == 0)
        #expect(!lifecycle.hasPendingPrompt)
    }

    @Test func keepRunningWithDontAskUncheckedKeepsAsking() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)
        try await press(env, .dialogQuitDontAsk, .set("off"))
        try await press(env, .dialogQuitKeepRunning)
        #expect(probe.disabledAsking == 0)
        #expect(probe.replies == [false])
        #expect(probe.policies == [.accessory])
    }

    @Test func cancelKeepsEverythingAsIs() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)
        try await press(env, .dialogQuitCancel)
        #expect(probe.replies == [false])
        #expect(probe.hidden == 0 && probe.policies.isEmpty && probe.stopAllCalls == 0 && probe.disabledAsking == 0)
        #expect(!lifecycle.isBackgroundOnly)
    }

    @Test func stopAllAndQuitNeedsASecondConfirmation() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)
        try await press(env, .dialogQuitStopAll)
        #expect(probe.stopAllCalls == 0, "Stop All and Quit… só abre a segunda confirmação")
        #expect(probe.replies.isEmpty)
        #expect(env.overlays.top?.spec.name == "confirmQuitStop")
        try await press(env, .dialogQuitStopAllConfirm)
        try await eventually { probe.replies == [true] }
        #expect(probe.stopAllCalls == 1)
        #expect(probe.cleanExits == 1)
        #expect(probe.policies.isEmpty, "saiu de verdade, não foi para accessory")
    }

    @Test func cancelOnTheSecondConfirmationDoesNotQuit() async throws {
        let (env, lifecycle, probe) = make()
        await decide(lifecycle, probe: probe)
        try await press(env, .dialogQuitStopAll)
        try await press(env, .dialogQuitCancel)
        #expect(probe.replies == [false])
        #expect(probe.stopAllCalls == 0)
    }

    @Test func keepAgentsRunningOffShowsTheStopVariantWithCancelAsDefault() async throws {
        let (env, lifecycle, probe) = make()
        probe.preferences = QuitPreferences(keepAgentsRunning: false, askBeforeQuit: true)
        await decide(lifecycle, probe: probe)
        let top = try #require(env.overlays.top)
        #expect(top.spec.name == "confirmQuit")
        #expect(!lifecycle.dontAskChecked)
        try await press(env, .dialogQuitStopAllConfirm)
        try await eventually { probe.replies == [true] }
        #expect(probe.stopAllCalls == 1)
    }

    // MARK: Decisão direta (sem overlay)

    @Test func askingDisabledKeepsRunningStraightAway() async throws {
        let (env, lifecycle, probe) = make()
        defer { withExtendedLifetime(env) {} }
        probe.preferences = QuitPreferences(keepAgentsRunning: true, askBeforeQuit: false)
        await decide(lifecycle, probe: probe)
        #expect(probe.replies == [false])
        #expect(probe.policies == [.accessory])
        #expect(probe.shown == 0)
    }

    @Test func nothingAliveQuitsAndMarksTheCleanExit() async throws {
        let (env, lifecycle, probe) = make()
        defer { withExtendedLifetime(env) {} }
        probe.counts = LiveProcessCounts()
        await decide(lifecycle, probe: probe)
        #expect(probe.replies == [true])
        #expect(probe.cleanExits == 1)
    }

    @Test func shouldTerminateReadsLiveCountsFromTheSource() async throws {
        let (env, lifecycle, probe) = make()
        defer { withExtendedLifetime(env) {} }
        probe.preferences = QuitPreferences(keepAgentsRunning: true, askBeforeQuit: false)
        lifecycle.shouldTerminate { probe.replies.append($0) }
        try await eventually { !probe.replies.isEmpty }
        #expect(probe.replies == [false])
    }

    @Test func quitCompletelyTerminatesTheProcessEvenWithAgentsAndHidesTheIcon() async throws {
        let (env, lifecycle, probe) = make()
        defer { withExtendedLifetime(env) {} }
        lifecycle.enterBackground()
        #expect(lifecycle.menuBar.state.isVisible)
        lifecycle.quitCompletely()
        #expect(probe.terminated == 1)
        #expect(!lifecycle.menuBar.state.isVisible, "o ícone some até reabrir")
        lifecycle.shouldTerminate { probe.replies.append($0) }
        try await eventually { !probe.replies.isEmpty }
        #expect(probe.replies == [true], "sem overlay: os agentes seguem no daemon")
        #expect(probe.stopAllCalls == 0, "Quit Completely nunca mata PTY")
    }

    @Test func menuBarStopAllNeedsLiveAgentsAndOpensTheSecondConfirmation() async throws {
        let (env, lifecycle, probe) = make()
        probe.counts = LiveProcessCounts()
        #expect(await lifecycle.requestStopAll() == false)
        probe.counts = LiveProcessCounts(agents: 2)
        lifecycle.enterBackground()
        #expect(await lifecycle.requestStopAll())
        #expect(!lifecycle.isBackgroundOnly, "a janela volta para mostrar a confirmação")
        #expect(env.overlays.top?.spec.name == "confirmQuitStop")
        try await press(env, .dialogQuitStopAllConfirm)
        try await eventually { probe.terminated == 1 }
        #expect(probe.stopAllCalls == 1)
    }

    // MARK: Accessory e reabertura

    @Test func closingTheLastWindowStaysOnlyWhileAgentsAreAlive() throws {
        let (env, lifecycle, _) = make()
        defer { withExtendedLifetime(env) {} }
        #expect(!lifecycle.shouldStayAfterLastWindowClosed)
        lifecycle.update(terminals: [terminal(.claude, .running), terminal(.shell, .running)])
        #expect(lifecycle.shouldStayAfterLastWindowClosed)
        lifecycle.update(terminals: [terminal(.shell, .running), terminal(.claude, .exited)])
        #expect(!lifecycle.shouldStayAfterLastWindowClosed, "shell ocioso não segura o app")
    }

    @Test func reopeningLeavesAccessoryAndShowsTheWindow() throws {
        let (env, lifecycle, probe) = make()
        defer { withExtendedLifetime(env) {} }
        lifecycle.enterBackground()
        lifecycle.leaveBackground()
        #expect(probe.policies == [.accessory, .regular])
        #expect(probe.shown == 1)
        #expect(!lifecycle.isBackgroundOnly)
    }

    // MARK: Barra de menus

    @Test func menuBarShowsTheLiveAgentCountAndTheThreeEntries() throws {
        let (env, lifecycle, _) = make()
        defer { withExtendedLifetime(env) {} }
        lifecycle.update(terminals: [terminal(.claude, .running), terminal(.codex, .running), terminal(.shell, .running)])
        let controller = lifecycle.menuBar
        #expect(controller.isInstalled)
        #expect(controller.buttonTitle == "2")
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "2 agents running")
        #expect(menu.items.first?.isEnabled == false)
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        #expect(titles == ["2 agents running", "Open Racky", "Stop All Agents…", "Quit Racky Completely"])
        let ids = menu.items.compactMap { $0.accessibilityIdentifier() }.filter { !$0.isEmpty }
        #expect(ids == ["menuBar.open", "menuBar.stopAll", "menuBar.quitCompletely"])
        #expect(menu.items.filter { $0.title == "Stop All Agents…" }.first?.isEnabled == true)
        lifecycle.update(terminals: [terminal(.shell, .running)])
        #expect(!controller.isInstalled, "sem agentes e com a janela aberta o ícone sai (When agents are running)")
    }

    private func terminal(_ provider: TerminalProvider, _ state: TerminalProcessState) -> Terminal {
        var t = Terminal(tabID: UUID(), provider: provider, title: "t", cwd: "/tmp", launchSpec: LaunchSpec(provider: provider))
        t.state = state
        return t
    }

    private func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timeout"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
