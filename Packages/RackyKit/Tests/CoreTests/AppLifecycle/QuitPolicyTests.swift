import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Política do ⌘Q (T1-24, 06 §1.9, 03 §16.10).
struct QuitPolicyTests {
    private let busy = LiveProcessCounts(agents: 3, shells: 2)

    @Test func nothingAliveQuitsImmediately() {
        #expect(QuitPolicy.decide(reason: .user, counts: LiveProcessCounts(), preferences: QuitPreferences()) == .quitNow)
    }

    @Test func idleShellsAloneDoNotAsk() {
        let decision = QuitPolicy.decide(reason: .user, counts: LiveProcessCounts(agents: 0, shells: 2), preferences: QuitPreferences())
        #expect(decision == .quitNow)
    }

    @Test func firstQuitWithAgentsAsksAndPreChecksDontAsk() {
        let decision = QuitPolicy.decide(reason: .user, counts: busy, preferences: QuitPreferences(), askedBefore: false)
        #expect(decision == .askUser(QuitPrompt(counts: busy, keepAgentsRunning: true, dontAskPreChecked: true)))
    }

    @Test func laterPromptsDoNotPreCheck() {
        let decision = QuitPolicy.decide(reason: .user, counts: busy, preferences: QuitPreferences(), askedBefore: true)
        #expect(decision == .askUser(QuitPrompt(counts: busy, keepAgentsRunning: true, dontAskPreChecked: false)))
    }

    @Test func askingOffMeansKeepRunningDirectly() {
        let preferences = QuitPreferences(keepAgentsRunning: true, askBeforeQuit: false)
        #expect(QuitPolicy.decide(reason: .user, counts: busy, preferences: preferences) == .keepRunning)
    }

    @Test func keepRunningSettingOffAsksWithStopVariantAndNoPreCheck() {
        let preferences = QuitPreferences(keepAgentsRunning: false, askBeforeQuit: true)
        let decision = QuitPolicy.decide(reason: .user, counts: busy, preferences: preferences)
        #expect(decision == .askUser(QuitPrompt(counts: busy, keepAgentsRunning: false, dontAskPreChecked: false)))
    }

    @Test func keepRunningSettingOffAndNotAskingStopsEverything() {
        let preferences = QuitPreferences(keepAgentsRunning: false, askBeforeQuit: false)
        #expect(QuitPolicy.decide(reason: .user, counts: busy, preferences: preferences) == .stopAllAndQuit)
        #expect(QuitPolicy.decide(reason: .user, counts: LiveProcessCounts(agents: 0, shells: 1), preferences: preferences) == .stopAllAndQuit)
        #expect(QuitPolicy.decide(reason: .user, counts: LiveProcessCounts(), preferences: preferences) == .quitNow)
    }

    @Test func systemShutdownAndQuitCompletelyNeverBlock() {
        for reason in [QuitRequestReason.system, .completely] {
            #expect(QuitPolicy.decide(reason: reason, counts: busy, preferences: QuitPreferences()) == .quitNow)
        }
    }

    @Test func choicesMapToEffects() {
        let prompt = QuitPrompt(counts: busy, keepAgentsRunning: true, dontAskPreChecked: true)
        #expect(QuitPolicy.apply(.cancel, prompt: prompt) == .init(decision: nil, disableAsking: false))
        #expect(QuitPolicy.apply(.stopAll, prompt: prompt) == .init(decision: .stopAllAndQuit, disableAsking: false))
        #expect(QuitPolicy.apply(.keepRunning(dontAskAgain: true), prompt: prompt) == .init(decision: .keepRunning, disableAsking: true))
        #expect(QuitPolicy.apply(.keepRunning(dontAskAgain: false), prompt: prompt) == .init(decision: .keepRunning, disableAsking: false))
    }

    @Test func keepRunningDoesNotExistInTheStopVariant() {
        let prompt = QuitPrompt(counts: busy, keepAgentsRunning: false, dontAskPreChecked: false)
        #expect(QuitPolicy.apply(.keepRunning(dontAskAgain: true), prompt: prompt).decision == nil)
    }

    @Test func countsComeFromRunningAndLaunchingTerminals() {
        func terminal(_ provider: TerminalProvider, _ state: TerminalProcessState) -> Terminal {
            var t = Terminal(tabID: UUID(), provider: provider, title: "t", cwd: "/tmp", launchSpec: LaunchSpec(provider: provider))
            t.state = state
            return t
        }
        let counts = LiveProcessCounts(counting: [
            terminal(.claude, .running), terminal(.codex, .launching), terminal(.shell, .running), terminal(.claude, .exited),
            terminal(.opencode, .interrupted), terminal(.custom, .running),
        ])
        #expect(counts == LiveProcessCounts(agents: 2, shells: 2))
    }
}

struct DaemonUpgradePolicyTests {
    @Test func olderDaemonDrainsWhenIdle() {
        #expect(DaemonUpgradePolicy.decide(appBuild: "200", daemonBuild: "150") == .drainWhenIdle)
    }

    @Test func sameOrNewerDaemonIsLeftAlone() {
        #expect(DaemonUpgradePolicy.decide(appBuild: "200", daemonBuild: "200") == .none)
        #expect(DaemonUpgradePolicy.decide(appBuild: "200", daemonBuild: "201") == .none)
    }

    @Test func developmentBuildsNeverTriggerAnUpgrade() {
        #expect(DaemonUpgradePolicy.decide(appBuild: "200", daemonBuild: "1.0 (dev)") == .none)
        #expect(DaemonUpgradePolicy.decide(appBuild: "1.0 (dev)", daemonBuild: "5") == .none)
    }

    @Test func diagnosticsTextCountsTerminals() {
        #expect(DaemonUpgradePolicy.pendingText(liveTerminals: 7) == "Daemon update pending (7 terminals running)")
        #expect(DaemonUpgradePolicy.pendingText(liveTerminals: 1) == "Daemon update pending (1 terminal running)")
    }
}

struct MenuBarStateTests {
    @Test func visibilityFollowsAgentsAndBackgroundMode() {
        var state = MenuBarState(counts: LiveProcessCounts(), visibility: .whenAgentsRunning)
        #expect(!state.isVisible)
        state.counts = LiveProcessCounts(agents: 2)
        #expect(state.isVisible)
        #expect(state.badgeTitle == "2")
        state.counts = LiveProcessCounts()
        state.isBackgroundOnly = true
        #expect(state.isVisible, "em accessory o ícone é a única porta de volta (P4)")
        state.visibility = .always
        state.isBackgroundOnly = false
        #expect(state.isVisible)
    }

    @Test func quitCompletelyHidesTheIcon() {
        let state = MenuBarState(
            counts: LiveProcessCounts(agents: 3), visibility: .always, isBackgroundOnly: true, quittingCompletely: true)
        #expect(!state.isVisible)
    }

    @Test func headerAndEnablement() {
        var state = MenuBarState(counts: LiveProcessCounts(agents: 1))
        #expect(state.headerText == "1 agent running")
        #expect(state.isEnabled(.stopAll))
        state.counts = LiveProcessCounts(agents: 4)
        #expect(state.headerText == "4 agents running")
        state.counts = LiveProcessCounts()
        #expect(state.headerText == "No agents running")
        #expect(!state.isEnabled(.stopAll))
        #expect(state.isEnabled(.open) && state.isEnabled(.quitCompletely))
        #expect(state.badgeTitle.isEmpty)
    }
}
