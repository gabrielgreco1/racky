import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation
import Testing

@testable import RackyUI

/// Conteúdo e regras do Quick Launch (03 §7, AC-313): itens, atalhos, perfis, fallback com o texto e o que ↵, ⌘↵ e ⇧↵ fazem.
@MainActor
@Suite(.offscreenAppKit) struct QuickLaunchModelTests {
    private let allInstalled: (TerminalProvider) -> Bool? = { _ in true }

    private func model(default agent: TerminalProvider = .claude, installed: @escaping (TerminalProvider) -> Bool? = { _ in true }, profiles: [LaunchProfile]? = nil) -> QuickLaunchModel {
        QuickLaunchModel(defaultAgent: agent, installed: installed, profiles: profiles ?? ProfileCatalog().profiles)
    }

    private func items(_ model: QuickLaunchModel) -> [DSMenuItem] { model.entries.compactMap(\.item) }

    @Test func listsAgentsAndTerminalWithTheDocumentedShortcuts() {
        let m = model()
        let list = items(m)
        let agents = Array(list.prefix(4))
        #expect(agents.map(\.id) == ["item.claude", "item.codex", "item.opencode", "item.terminal"])
        #expect(agents.map(\.title) == ["New Claude Code Tab", "New Codex Tab", "New OpenCode Tab", "New Terminal"])
        #expect(agents[0].shortcut == "⌥⌘T", "o agente padrão leva ⌥⌘T")
        #expect(agents[1].shortcut == nil)
        #expect(agents[3].shortcut == "⌘T")
    }

    @Test func theDefaultAgentComesFirst() {
        let m = model(default: .codex)
        let ids = items(m).prefix(3).map(\.id)
        #expect(ids == ["item.codex", "item.claude", "item.opencode"])
        #expect(items(m)[0].shortcut == "⌥⌘T")
    }

    @Test func notInstalledAgentsAreDisabledWithTheReason() {
        let m = model(installed: { $0 == .opencode ? false : nil })
        let opencode = items(m).first { $0.id == "item.opencode" }
        #expect(opencode?.disabledReason == "Not installed")
        #expect(items(m).first { $0.id == "item.codex" }?.disabledReason == nil, "não sondado ainda: habilitado")
    }

    @Test func profilesAppearWithFlagsInMonoAndNeverRepeatTheDefaults() {
        let m = model()
        let profiles = items(m).filter { $0.id.hasPrefix("profile.") }
        #expect(!profiles.isEmpty)
        #expect(profiles.allSatisfy { $0.detailMono })
        let plan = profiles.first { $0.title == BuiltinProfiles.claudePlan.name }
        #expect(plan?.detail == "--permission-mode plan")
        #expect(!profiles.contains { $0.title == BuiltinProfiles.claudeDefault.name }, "o padrão já é o item New Claude Code Tab")
        // Perfis do agente padrão antes dos de outros agentes.
        let order = profiles.map(\.title)
        #expect(order.firstIndex(of: BuiltinProfiles.claudePlan.name)! < order.firstIndex(of: BuiltinProfiles.codexBypassApprovals.name)!)
    }

    @Test func flagSummaryUsesModelEffortPermissionAndExtraArgs() {
        let profile = LaunchProfile(name: "Fast", provider: .claude, model: "haiku", effort: "low", permissionMode: "plan", extraArgs: ["--verbose"])
        #expect(QuickLaunchModel.flags(of: profile) == "--model haiku --effort low --permission-mode plan --verbose")
    }

    @Test func enterOpensTheItemWithoutAPrompt() {
        let m = model()
        #expect(m.resolve(itemID: "item.codex", text: "", activation: .plain) == .launch(QuickLaunchRequest(provider: .codex)))
        #expect(m.resolve(itemID: "item.terminal", text: "", activation: .plain) == .terminal(split: false))
        #expect(m.resolve(itemID: "settings", text: "", activation: .plain) == .settings(.claude))
        // Texto digitado que casa com um item não vira prompt com ↵.
        #expect(m.resolve(itemID: "item.codex", text: "cod", activation: .plain) == .launch(QuickLaunchRequest(provider: .codex)))
    }

    @Test func commandEnterStartsTheSelectedItemWithTheTextAsPrompt() {
        let m = model()
        #expect(m.resolve(itemID: "item.codex", text: "  fix pagination ", activation: .command)
            == .launch(QuickLaunchRequest(provider: .codex, prompt: "fix pagination")))
        let plan = BuiltinProfiles.claudePlan
        #expect(m.resolve(itemID: QuickLaunchModel.profileItemID(plan.id), text: "plan it", activation: .command)
            == .launch(QuickLaunchRequest(provider: .claude, profileID: plan.id, prompt: "plan it")))
        #expect(m.resolve(itemID: "item.codex", text: "", activation: .command) == .launch(QuickLaunchRequest(provider: .codex)), "sem texto, sem prompt")
    }

    @Test func shiftEnterOpensInASplit() {
        let m = model()
        #expect(m.resolve(itemID: "item.claude", text: "", activation: .shift) == .launch(QuickLaunchRequest(provider: .claude, split: true)))
        #expect(m.resolve(itemID: "item.terminal", text: "", activation: .shift) == .terminal(split: true))
    }

    @Test func theFallbackRowStartsTheDefaultAgentWithTheText() {
        let m = model(default: .codex)
        let row = m.fallback(for: "scrape the listings portal")
        #expect(row.title == "Start Codex with \"scrape the listings portal\"")
        #expect(m.resolve(itemID: QuickLaunchModel.fallbackID, text: "scrape the listings portal", activation: .plain)
            == .launch(QuickLaunchRequest(provider: .codex, prompt: "scrape the listings portal")))
    }

    @Test func requestRoundTripsAndFreeTextBecomesAPrompt() {
        let request = QuickLaunchRequest(provider: .claude, profileID: BuiltinProfiles.claudePlan.id, prompt: "hi", split: true)
        #expect(QuickLaunchRequest.decode(request.encoded(), defaultAgent: .codex) == request)
        #expect(QuickLaunchRequest.decode("fix the bug", defaultAgent: .codex) == QuickLaunchRequest(provider: .codex, prompt: "fix the bug"))
        #expect(QuickLaunchRequest.decode("   ", defaultAgent: .codex) == nil)
    }
}
