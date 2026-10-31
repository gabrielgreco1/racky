import RackyDocker
import RackyProtocol
import Foundation

/// Itens da checklist de diagnóstico além dos CLIs de agente (03 §15, R1.1): `gh`, runtime dos computadores (nativo) ou Docker e
/// imagem (só quando o Docker é o runtime), e conflitos.
/// Os CLIs de agente seguem no `SettingsModel` (mesma sonda, mesmo cache).
public nonisolated enum DiagnosticKey: String, CaseIterable, Sendable {
    case gh, runtime, docker, image, conflicts

    public var title: String {
        switch self {
        case .gh: "GitHub CLI"
        case .runtime: "Computer runtime"
        case .docker: "Docker"
        case .image: "Computer image"
        case .conflicts: "Conflicts"
        }
    }
}

/// Qual runtime serve os computadores neste Mac. Decide o que a checklist mostra: com o nativo, nada de Docker.
public nonisolated enum ComputerRuntimeMode: Sendable, Equatable {
    /// Runtime nativo (VMs do próprio app): nada a instalar; `assetsInstalled` = kernel e imagem já baixados.
    case native(assetsInstalled: Bool)
    /// O usuário forçou o Docker (Settings › Computers).
    case dockerForced
    /// Este Mac não roda o runtime nativo (macOS < 26, Intel, build sem entitlement): só o Docker serve.
    case dockerOnly(reason: String)
}

public nonisolated enum DiagnosticState: Sendable, Equatable {
    case checking, ok, warning, problem, neutral
}

/// Ação de correção de um item. A UI mapeia cada uma para uma ação do registro; nenhuma altera config global dos CLIs
/// (PP-6), exceto `disableSkill`, que só move a pasta para o backup do app depois de confirmação.
public nonisolated enum DiagnosticFix: Sendable, Equatable {
    case openURL(title: String, URL)
    case copyCommand(String)
    /// Terminal inline com o comando de login; sem painel disponível a UI cai para `copyCommand`.
    case logIn([String])
    case retry
    case openSettings(section: String)
    case startDocker
    case blockSkill, disableSkill, keepSkill, restoreSkill
}

/// Algo nas configs globais dos CLIs que convive ou compete com o que o Racky injeta por lançamento (R1.5–R1.8).
public nonisolated struct ConflictFinding: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case globalSkill, hooks, notify, mcpServer }

    public var kind: Kind
    public var provider: TerminalProvider
    /// Caminho para exibição (`~/.claude/settings.json`).
    public var path: String
    public var message: String
    public var id: String { "\(kind.rawValue):\(provider.rawValue):\(path)" }

    public init(kind: Kind, provider: TerminalProvider, path: String, message: String) {
        self.kind = kind
        self.provider = provider
        self.path = path
        self.message = message
    }

    /// Só a skill global do Claude tem remédio (deny por lançamento ou backup); o resto é informação (AC-114).
    public var isActionable: Bool { kind == .globalSkill && provider == .claude }
}

/// Escolha do usuário para a skill global `racky` (AC-113). Persistida pelo chamador.
public nonisolated enum ConflictChoice: String, Codable, Sendable { case block, keep }

public nonisolated struct ConflictScan: Sendable, Equatable {
    public var findings: [ConflictFinding]
    public var choice: ConflictChoice?
    /// Há uma skill movida para o backup do app (`Restore Skill`).
    public var hasBackup: Bool

    public init(findings: [ConflictFinding] = [], choice: ConflictChoice? = nil, hasBackup: Bool = false) {
        self.findings = findings
        self.choice = choice
        self.hasBackup = hasBackup
    }
}

public nonisolated struct GitHubProbeResult: Sendable, Equatable {
    public var installed: Bool
    public var version: String?
    public var auth: GitHubAuthStatus?

    public init(installed: Bool, version: String? = nil, auth: GitHubAuthStatus? = nil) {
        self.installed = installed
        self.version = version
        self.auth = auth
    }
}

public nonisolated enum DockerProbeResult: Sendable, Equatable {
    case notInstalled
    case installedNotRunning(kind: DockerRuntimeKind)
    case running(DockerRunning)
}

public nonisolated struct DockerRunning: Sendable, Equatable {
    public var runtime: DockerRuntime
    public var version: String
    public var memoryGB: Int
    public var headlessCapacity: Int
    public var isVerifiedArchitecture: Bool

    public init(runtime: DockerRuntime, version: String, memoryGB: Int, headlessCapacity: Int, isVerifiedArchitecture: Bool = true) {
        self.runtime = runtime
        self.version = version
        self.memoryGB = memoryGB
        self.headlessCapacity = headlessCapacity
        self.isVerifiedArchitecture = isVerifiedArchitecture
    }
}

public nonisolated enum ImageProbeResult: Sendable, Equatable {
    case ready, missing
}

public nonisolated struct DiagnosticItem: Sendable, Equatable, Identifiable {
    public var key: DiagnosticKey
    public var state: DiagnosticState
    /// Motivo em uma linha (AC-103).
    public var detail: String
    /// Ação primária (no máximo uma) e as secundárias (só os conflitos têm mais de uma, 03 §15).
    public var fix: DiagnosticFix?
    public var secondaryFixes: [DiagnosticFix]
    /// Linhas de informação extras (conflitos).
    public var notes: [String]
    public var id: DiagnosticKey { key }
    public var title: String { key.title }

    public init(key: DiagnosticKey, state: DiagnosticState, detail: String, fix: DiagnosticFix? = nil,
                secondaryFixes: [DiagnosticFix] = [], notes: [String] = []) {
        self.key = key
        self.state = state
        self.detail = detail
        self.fix = fix
        self.secondaryFixes = secondaryFixes
        self.notes = notes
    }

    public static func checking(_ key: DiagnosticKey) -> DiagnosticItem {
        DiagnosticItem(key: key, state: .checking, detail: "Checking…")
    }
}
