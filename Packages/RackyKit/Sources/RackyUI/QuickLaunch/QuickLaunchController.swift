import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SwiftUI

/// Painel do Quick Launch (03 §7): `DSMenuPanel` de 300 pt ancorado ao "+" da tab row, com campo, agentes, perfis e rodapé de
/// teclas. Abre uma tab nova na sessão atual, sem passar pelo composer.
private struct QuickLaunchPanelView: View {
    let model: QuickLaunchModel
    let registry: ActionRegistry?
    let dismiss: @MainActor () -> Void
    @State private var navigator: DSMenuNavigator

    init(model: QuickLaunchModel, registry: ActionRegistry?, dismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.registry = registry
        self.dismiss = dismiss
        let navigator = DSMenuNavigator(entries: DSMenuPanel.resolve(model.entries, registry: registry), searchable: true)
        navigator.emptyFallback = { [model] text in model.fallback(for: text) }
        _navigator = State(initialValue: navigator)
    }

    var body: some View {
        DSMenuPanelView(
            navigator: navigator, width: QuickLaunchModel.width, searchPlaceholder: String(localized: "Start an agent or type a prompt…", bundle: .module),
            footer: String(localized: "↵ Open · ⌘↵ Start with prompt · ⇧↵ Split · Esc Close", bundle: .module),
            decorateRow: { item, view in
                guard let id = Self.a11yID(for: item.id) else { return view }
                return AnyView(view.a11y(id, kind: "menuitem", label: item.title, action: item.action))
            },
            decorateSearch: { view in AnyView(view.a11y(.overlayQuickLaunchInput, kind: "textfield", value: navigator.query)) },
            onOutcome: { outcome in
                switch outcome {
                case .none: break
                case .dismiss: dismiss()
                case .activate(let item):
                    let resolution = model.resolve(itemID: item.id, text: navigator.query, activation: navigator.activation)
                    dismiss()
                    if let resolution, let registry { Task { await Self.perform(resolution, registry: registry) } }
                }
            }
        )
    }

    static func a11yID(for itemID: String) -> A11yID? {
        if itemID.hasPrefix("item.") { return .overlayQuickLaunchItem(String(itemID.dropFirst(5))) }
        if itemID.hasPrefix("profile.") { return .overlayQuickLaunchProfile(String(itemID.dropFirst(8))) }
        if itemID == "settings" { return .overlayQuickLaunchAgentSettings }
        if itemID.hasPrefix("dataset.") { return .overlayQuickLaunchDataset(String(itemID.dropFirst(8))) }
        if itemID == QuickLaunchModel.fallbackID { return .overlayQuickLaunchItem("prompt") }
        return nil
    }

    @MainActor
    static func perform(_ resolution: QuickLaunchResolution, registry: ActionRegistry) async {
        switch resolution {
        case .launch(let request):
            if !request.split, request.profileID == nil, request.prompt == nil {
                _ = try? await registry.perform(.tabNewWithAgent, .select(request.provider.rawValue))
            } else {
                _ = try? await registry.perform(.tabNewWithPrompt, .set(request.encoded()))
            }
        case .terminal(let split):
            if split {
                _ = try? await registry.perform(.tabNewWithPrompt, .set(QuickLaunchRequest(provider: .shell, split: true).encoded()))
            } else {
                _ = try? await registry.perform(.tabNewTerminal, .press)
            }
        case .settings(let provider):
            _ = try? await registry.perform(.agentOpenSettings, .select(provider.rawValue))
        case .dataset(let id, let beside):
            _ = try? await registry.perform(.datasetOpen, .select(beside ? "\(id)|beside" : id))
        }
    }
}

/// Registra `tab.quickLaunch` (⌥⌘N e "+" da tab row) e `tab.newWithPrompt` (`Start <agente> with "<texto>"`, perfis, ⌘↵, ⇧↵).
/// ⌘T e ⌥⌘T são de `WorkspaceActions` (`tab.newTerminal`, `tab.newAgent`).
@MainActor
final class QuickLaunchController {
    private let workspace: WorkspaceModel
    private let overlays: OverlayRouter
    private let elements: UIElementStore
    private let settings: SettingsModel
    /// Datasets da sessão atual (id, nome mostrado); ligado pelo `AppEnvironment`.
    var sessionDatasets: () -> [(id: String, name: String)] = { [] }

    init(workspace: WorkspaceModel, overlays: OverlayRouter, elements: UIElementStore, settings: SettingsModel) {
        self.workspace = workspace
        self.overlays = overlays
        self.elements = elements
        self.settings = settings
    }

    /// Modelo atual: agente padrão, instalação detectada e perfis (os prontos e os do usuário).
    func model() -> QuickLaunchModel {
        QuickLaunchModel(
            defaultAgent: settings.settings.agents.defaultAgent, installed: { [settings] in settings.agent($0)?.installedState },
            profiles: settings.catalog.profiles, datasets: sessionDatasets())
    }

    func register(in registry: ActionRegistry) throws {
        let noSession = String(localized: "Select a session first.", bundle: .module)
        let ready: ActionRegistry.Enablement = { [workspace] in workspace.isLoaded ? .enabled : .disabled(reason: noSession) }
        try registry.register(.tabQuickLaunch, enablement: ready) { [unowned self, unowned registry] _ in
            // O "+" é a âncora também quando o painel abre por atalho (03 §7).
            // Sem o "+" na tela (página do centro aberta), o menu desce do topo, no meio da janela, nunca do canto.
            let anchor = elements.frame(of: .tabsNew) ?? elements.windowInfo().map {
                CGRect(x: ($0.width - QuickLaunchModel.width) / 2, y: TabMetrics.chromeHeight - 1, width: QuickLaunchModel.width, height: 1)
            } ?? .zero
            let model = model()
            let spec = PopoverSpec(
                name: "quickLaunch", id: .overlayQuickLaunch, anchor: anchor, width: QuickLaunchModel.width, alignment: .leading
            ) { dismiss in AnyView(QuickLaunchPanelView(model: model, registry: registry, dismiss: dismiss)) }
            return overlays.presentPopover(spec) ? "opened" : nil
        }
        try registry.register(.tabNewWithPrompt, enablement: ready) { [unowned self] arg in
            guard arg.kind == .set, let raw = arg.value,
                  let request = QuickLaunchRequest.decode(raw, defaultAgent: settings.settings.agents.defaultAgent)
            else { throw ActionError.failed(.tabNewWithPrompt, message: "expected set(<json or prompt text>)") }
            return workspace.open(request)?.uuidString
        }
    }
}

extension AgentInfo {
    /// `nil` = ainda não sondado.
    var installedState: Bool? {
        switch phase {
        case .checking: nil
        case .notInstalled: false
        case .installed: true
        }
    }
}
