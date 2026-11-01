import RackyCore
import RackyProtocol
import AppKit
import Foundation

/// Sonda um CLI (somente leitura: `--version`, `--help` e o comando de status; nunca `login`). `force` ignora o cache.
public typealias AgentProbe = @Sendable (TerminalProvider, Bool) async -> CLIProbeResult

/// Estado de um agente para a UI (Settings › Agents e onboarding).
public nonisolated struct AgentInfo: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
        case checking
        case notInstalled
        case installed(path: String, version: String?, login: CLILoginState)
    }

    public enum Tone: Sendable { case success, warning, neutral }

    public var provider: TerminalProvider
    public var phase: Phase
    public var id: TerminalProvider { provider }

    public init(provider: TerminalProvider, phase: Phase = .checking) {
        self.provider = provider
        self.phase = phase
    }

    public init(provider: TerminalProvider, result: CLIProbeResult) {
        self.provider = provider
        if let path = result.executable {
            phase = .installed(path: path, version: result.version?.description ?? result.versionText, login: result.login)
        } else {
            phase = .notInstalled
        }
    }

    /// Nomes da UI (03 §15): "Claude Code", "Codex", "OpenCode".
    public static func displayName(_ provider: TerminalProvider) -> String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .shell: "Blank Terminal"
        case .custom: "Custom Command"
        }
    }

    public var displayName: String { Self.displayName(provider) }
    public var isInstalled: Bool { if case .installed = phase { true } else { false } }
    public var isLoggedOut: Bool { if case .installed(_, _, .loggedOut) = phase { true } else { false } }
    public var version: String? { if case .installed(_, let v, _) = phase { v } else { nil } }
    public var path: String? { if case .installed(let p, _, _) = phase { p } else { nil } }

    /// `Logged in` / `Not logged in` / `Login can't be verified` / `Not installed` / `Checking…` (03 §14.2).
    public var statusText: String {
        switch phase {
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .installed(_, _, let login):
            switch login {
            case .loggedIn: "Logged in"
            case .loggedOut: "Not logged in"
            case .unknown: "Login can't be verified"
            }
        }
    }

    /// Linha de detalhe do onboarding: `2.1.302 · Logged in`.
    public var detailText: String {
        if case .installed(_, let version, _) = phase, let version { return "\(version) · \(statusText)" }
        return statusText
    }

    public var tone: Tone {
        switch phase {
        case .checking, .notInstalled: .neutral
        case .installed(_, _, let login):
            switch login {
            case .loggedIn: .success
            case .loggedOut: .warning
            case .unknown: .neutral
            }
        }
    }

    public var installURL: URL? {
        switch provider {
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
        case .codex: URL(string: "https://github.com/openai/codex")
        case .opencode: URL(string: "https://opencode.ai")
        case .shell, .custom: nil
        }
    }

    /// Comando oficial de login que o terminal inline roda (03 §15). OpenCode não tem como verificar login, então não oferece.
    public var loginCommand: [String]? {
        switch provider {
        case .claude: ["claude", "/login"]
        case .codex: ["codex", "login"]
        case .opencode, .shell, .custom: nil
        }
    }
}

/// Efeitos de sistema do Settings e do onboarding, trocáveis nos testes.
public nonisolated struct SettingsSystemActions: Sendable {
    public var pickFolder: @MainActor @Sendable (_ current: String) async -> String?
    public var openURL: @MainActor @Sendable (URL) -> Void
    /// Abre System Settings na página do app (`notifications`).
    public var openSystemSettings: @MainActor @Sendable (_ pane: String) -> Void

    public init(
        pickFolder: @escaping @MainActor @Sendable (String) async -> String? = SettingsSystemActions.openPanel,
        openURL: @escaping @MainActor @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
        openSystemSettings: @escaping @MainActor @Sendable (String) -> Void = { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        }
    ) {
        self.pickFolder = pickFolder
        self.openURL = openURL
        self.openSystemSettings = openSystemSettings
    }

    @MainActor
    public static func openPanel(current: String) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
