import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation

/// Pedido de uma tab nova na sessão atual (Quick Launch, 03 §7). É o argumento JSON de `tab.newWithPrompt`.
struct QuickLaunchRequest: Codable, Equatable {
    var provider: TerminalProvider
    var profileID: UUID?
    var prompt: String?
    /// ⇧↵: abre num split à direita do pane focado em vez de uma tab.
    var split: Bool = false

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// JSON ou texto livre (texto livre vira o prompt do agente padrão).
    static func decode(_ raw: String, defaultAgent: TerminalProvider) -> QuickLaunchRequest? {
        if let data = raw.data(using: .utf8), let request = try? JSONDecoder().decode(QuickLaunchRequest.self, from: data) { return request }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : QuickLaunchRequest(provider: defaultAgent, prompt: text)
    }
}

/// O que um item do Quick Launch faz quando ativado.
enum QuickLaunchResolution: Equatable {
    case launch(QuickLaunchRequest)
    case terminal(split: Bool)
    case settings(TerminalProvider)
    case dataset(String, beside: Bool)
}

/// Conteúdo e regras do Quick Launch (03 §7), sem SwiftUI: itens, atalhos, filtro, linha de "Start <agente> with …" e o que
/// cada ativação (↵, ⌘↵, ⇧↵) significa. Testado sem janela.
struct QuickLaunchModel {
    enum Target: Equatable {
        case agent(TerminalProvider)
        case terminal
        case profile(UUID, TerminalProvider)
        case settings(TerminalProvider)
        case dataset(String)
        case fallback
    }

    /// Largura do popover (03 §7).
    static let width: CGFloat = 380
    static let fallbackID = "fallback"
    static let placeholder = "Start an agent or type a prompt…"
    static let footer = "↵ Open · ⌘↵ Start with prompt · ⇧↵ Split · Esc Close"

    let defaultAgent: TerminalProvider
    let entries: [DSMenuEntry]
    private(set) var targets: [String: Target] = [:]

    static let agentOrder: [TerminalProvider] = [.claude, .codex, .opencode]

    static func itemID(_ provider: TerminalProvider) -> String { "item.\(provider == .shell ? "terminal" : provider.rawValue)" }
    static func profileItemID(_ id: UUID) -> String { "profile.\(id.uuidString.lowercased())" }
    static func datasetItemID(_ id: String) -> String { "dataset.\(id)" }

    static func kind(_ provider: TerminalProvider) -> DSAgentKind {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .shell, .custom: .shell
        }
    }

    /// `installed`: `nil` = ainda não sondado (o item fica habilitado); `false` = `Not installed`.
    /// `datasets`: os da sessão atual (id, nome), abertos como tab da sessão.
    init(defaultAgent: TerminalProvider, installed: (TerminalProvider) -> Bool?, profiles: [LaunchProfile], datasets: [(id: String, name: String)] = []) {
        self.defaultAgent = defaultAgent
        var entries: [DSMenuEntry] = []
        var targets: [String: Target] = [:]
        // Seções com nome: o que cada grupo abre fica escrito (agentes, perfis salvos com flags, dados da sessão).
        entries.append(.header(String(localized: "Start in a new tab", bundle: .module)))
        let agents = [defaultAgent] + Self.agentOrder.filter { $0 != defaultAgent }
        for provider in agents where provider.isAgent {
            let id = Self.itemID(provider)
            let name = AgentInfo.displayName(provider)
            entries.append(.item(DSMenuItem(
                id, String(localized: "New \(name) Tab", bundle: .module), icon: .agent(Self.kind(provider)),
                shortcut: provider == defaultAgent ? ActionID.tabNewAgent.spec.shortcut : nil,
                disabledReason: installed(provider) == false ? String(localized: "Not installed", bundle: .module) : nil,
                action: .tabNewWithAgent, argument: .select(provider.rawValue))))
            targets[id] = .agent(provider)
        }
        entries.append(.item(DSMenuItem(
            Self.itemID(.shell), String(localized: "New Terminal", bundle: .module), icon: .agent(.shell),
            shortcut: ActionID.tabNewTerminal.spec.shortcut, action: .tabNewTerminal)))
        targets[Self.itemID(.shell)] = .terminal

        // Perfis: os do agente padrão primeiro; o padrão de cada agente já é o item "New <Agent> Tab".
        let extras = profiles.filter { $0.provider.isAgent && !($0.isDefault && $0.scope == .global) }
        let ordered = extras.filter { $0.provider == defaultAgent } + extras.filter { $0.provider != defaultAgent }
        if !ordered.isEmpty {
            entries.append(.separator("profiles"))
            entries.append(.header(String(localized: "Saved profiles (agent with extra flags)", bundle: .module)))
        }
        for profile in ordered {
            let id = Self.profileItemID(profile.id)
            entries.append(.item(DSMenuItem(
                id, profile.name, icon: .agent(Self.kind(profile.provider)), detail: Self.flags(of: profile), detailMono: true,
                disabledReason: installed(profile.provider) == false ? String(localized: "Not installed", bundle: .module) : nil,
                action: .tabNewWithPrompt, argument: .set(QuickLaunchRequest(provider: profile.provider, profileID: profile.id).encoded()))))
            targets[id] = .profile(profile.id, profile.provider)
        }

        if !datasets.isEmpty {
            entries.append(.separator("data"))
            entries.append(.header(String(localized: "This session's data", bundle: .module)))
            for dataset in datasets {
                let id = Self.datasetItemID(dataset.id)
                entries.append(.item(DSMenuItem(
                    id, String(localized: "Open \(dataset.name)", bundle: .module), icon: .symbol("tablecells"),
                    detail: String(localized: "table", bundle: .module), action: .datasetOpen, argument: .select(dataset.id))))
                targets[id] = .dataset(dataset.id)
            }
        }

        entries.append(.separator("settings"))
        let settingsID = "settings"
        entries.append(.item(DSMenuItem(
            settingsID, String(localized: "Agent Settings…", bundle: .module), icon: .symbol("gearshape"), action: .agentOpenSettings,
            argument: .select(defaultAgent.rawValue))))
        targets[settingsID] = .settings(defaultAgent)
        targets[Self.fallbackID] = .fallback
        self.entries = entries
        self.targets = targets
    }

    /// Resumo das flags de um perfil, em `mono` (03 §7: "perfis ... com flags").
    static func flags(of profile: LaunchProfile) -> String {
        var parts: [String] = []
        if let model = profile.model, !model.isEmpty { parts.append("--model \(model)") }
        if let effort = profile.effort, !effort.isEmpty { parts.append("--effort \(effort)") }
        if let mode = profile.permissionMode, !mode.isEmpty {
            parts.append(profile.provider == .claude ? "--permission-mode \(mode)" : "--\(mode)")
        }
        parts.append(contentsOf: profile.extraArgs)
        return parts.joined(separator: " ")
    }

    /// Linha que aparece quando o texto não casa com nenhum item: `Start Claude Code with "<texto>"` (agente padrão).
    func fallback(for text: String) -> DSMenuItem {
        let name = AgentInfo.displayName(defaultAgent)
        return DSMenuItem(
            Self.fallbackID, String(localized: "Start \(name) with \"\(text)\"", bundle: .module), icon: .agent(Self.kind(defaultAgent)),
            action: .tabNewWithPrompt, argument: .set(QuickLaunchRequest(provider: defaultAgent, prompt: text).encoded()))
    }

    /// O que acontece ao ativar `itemID` com o texto digitado: ↵ abre o item; ⌘↵ abre com o texto como prompt; ⇧↵ em split.
    func resolve(itemID: String, text: String, activation: DSMenuActivation) -> QuickLaunchResolution? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = activation == .shift
        let usePrompt = !prompt.isEmpty
        switch targets[itemID] {
        case .agent(let provider):
            return .launch(QuickLaunchRequest(provider: provider, prompt: activation == .command && usePrompt ? prompt : nil, split: split))
        case .profile(let id, let provider):
            return .launch(QuickLaunchRequest(
                provider: provider, profileID: id, prompt: activation == .command && usePrompt ? prompt : nil, split: split))
        case .terminal: return .terminal(split: split)
        case .settings(let provider): return .settings(provider)
        case .dataset(let id): return .dataset(id, beside: split)
        case .fallback:
            return .launch(QuickLaunchRequest(provider: defaultAgent, prompt: usePrompt ? prompt : nil, split: split))
        case nil: return nil
        }
    }
}
