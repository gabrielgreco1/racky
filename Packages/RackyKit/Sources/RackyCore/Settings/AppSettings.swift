import RackyProtocol
import Foundation

/// Configuração do app (03 §14), gravada em `setting` sob `AppSettings.storeKey`. Só as chaves da Fatia 1 existem;
/// chaves novas entram com o `decodeIfPresent` e o padrão da spec, então um banco antigo nunca falha ao abrir.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let storeKey = "app.settings"

    public var general = General()
    public var agents = Agents()
    public var terminal = Terminal()
    public var notifications = Notifications()
    public var computers = Computers()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = try c.decodeIfPresent(General.self, forKey: .general) ?? General()
        agents = try c.decodeIfPresent(Agents.self, forKey: .agents) ?? Agents()
        terminal = try c.decodeIfPresent(Terminal.self, forKey: .terminal) ?? Terminal()
        notifications = try c.decodeIfPresent(Notifications.self, forKey: .notifications) ?? Notifications()
        computers = try c.decodeIfPresent(Computers.self, forKey: .computers) ?? Computers()
    }

    /// Settings › Computers (F12): padrão de "Subagent computers" das novas sessões. Sessões existentes não mudam.
    public struct Computers: Codable, Equatable, Sendable {
        public var defaultSubagentMode = SubagentComputersMode.ask  // Off deixava o agente sem os computadores (e sem bloquear skills concorrentes)
        /// Quem roda os subagentes das novas sessões (spec subagent-harness).
        public var defaultSubagentHarness = SubagentHarness.claude
        /// Onde os computadores sobem (BK-12, P27): no Mac (Docker) ou na conta de nuvem do próprio usuário.
        public var runOn = ComputerRunTarget.local
        public var cloud = Cloud()
        /// "Use Docker instead": no macOS 26+ o app usa o runtime nativo (VMs, sem Docker); com isto ligado, usa o Docker.
        public var forceDocker = false
        /// Git e PR de dentro dos computadores (o repositório do projeto da sessão, push só em `feat/*`), pelo gateway do egress com o
        /// token do `gh` do dono, que nunca entra no computador. Desligado por padrão.
        public var githubAccess = false

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultSubagentMode = try c.decodeIfPresent(SubagentComputersMode.self, forKey: .defaultSubagentMode) ?? .ask
            defaultSubagentHarness = try c.decodeIfPresent(SubagentHarness.self, forKey: .defaultSubagentHarness) ?? .claude
            runOn = try c.decodeIfPresent(ComputerRunTarget.self, forKey: .runOn) ?? .local
            cloud = try c.decodeIfPresent(Cloud.self, forKey: .cloud) ?? Cloud()
            forceDocker = try c.decodeIfPresent(Bool.self, forKey: .forceDocker) ?? false
            githubAccess = try c.decodeIfPresent(Bool.self, forKey: .githubAccess) ?? false
        }
    }

    /// Nuvem própria (P27): provedor, região e tetos são do usuário; o app só aplica.
    public struct Cloud: Codable, Equatable, Sendable {
        public static let dailyCapRange = 1...500
        public static let monthlyCapRange = 5...5000
        public static let maxComputersRange = 1...50

        public var provider = CloudProviderCatalog.aws.id
        public var region = "us-east-1"
        public var dailyCapUSD = 5
        public var monthlyCapUSD = 50
        public var maxComputers = 3
        /// Perfil do `aws` CLI que o `aws login` grava (credenciais de curta duração; o app nunca vê chave).
        public var awsProfile = "racky"
        /// Versão do uso aceitável do provedor que o usuário aceitou ao conectar (`nil` = nunca conectou).
        public var acceptedAUP: String?
        /// O usuário salvou conta, região e limites ("Save and turn on"): só então os computers vão para a nuvem.
        public var confirmed = false

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Cloud()
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
            region = try c.decodeIfPresent(String.self, forKey: .region) ?? d.region
            dailyCapUSD = (try c.decodeIfPresent(Int.self, forKey: .dailyCapUSD) ?? d.dailyCapUSD).clamped(to: Self.dailyCapRange)
            monthlyCapUSD = (try c.decodeIfPresent(Int.self, forKey: .monthlyCapUSD) ?? d.monthlyCapUSD).clamped(to: Self.monthlyCapRange)
            maxComputers = (try c.decodeIfPresent(Int.self, forKey: .maxComputers) ?? d.maxComputers).clamped(to: Self.maxComputersRange)
            awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile) ?? d.awsProfile
            acceptedAUP = try c.decodeIfPresent(String.self, forKey: .acceptedAUP)
            confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        }
    }

    public enum BranchPrefixMode: String, Codable, Sendable, CaseIterable { case gitUser, custom, none }

    public enum ComputerRunTarget: String, Codable, Sendable, CaseIterable { case local, cloud }

    public enum KeepOrDelete: String, Codable, Sendable, CaseIterable { case keep, delete }

    public struct General: Codable, Equatable, Sendable {
        public var keepAgentsRunning = true
        public var askBeforeQuit = true
        /// P25: relança sozinho, com `--resume`, os agentes que morreram com o app fechado ou no reinício do Mac.
        public var resumeAgentsOnOpen = true
        public var confirmCloseTerminal = true
        public var confirmDeleteSession = true
        /// Padrão de transição (P15, R3.2).
        public var worktreeFolder = "~/Racky/worktrees"
        public var cleanSessionFolder = "~/Racky/sessions"
        /// Onde `Clone from GitHub…` cria `<pasta>/<repo>` (F24).
        public var projectsFolder = "~/Racky/projects"
        public var branchPrefix = BranchPrefixMode.gitUser
        public var branchPrefixCustom = ""
        /// Storage: quando o `work/` de um computador terminado sai do disco (padrão do card de aprovação; antes, tudo ficava para sempre).
        public var computerLeftovers = LeftoversPolicy.days7
        /// Storage: o card de aprovação mostra a escolha; desligado, todo computador recebe o padrão sem perguntar.
        public var leftoversOnCard = true
        /// Storage: arquivar uma sessão de worktree apaga o checkout (só sem mudanças e com tudo publicado; a branch fica).
        public var archivedWorktrees = KeepOrDelete.keep
        /// Storage: imagens Docker de versões anteriores do computador saem quando a nova fica pronta.
        public var oldComputerImages = KeepOrDelete.delete

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keepAgentsRunning = try c.decodeIfPresent(Bool.self, forKey: .keepAgentsRunning) ?? true
            askBeforeQuit = try c.decodeIfPresent(Bool.self, forKey: .askBeforeQuit) ?? true
            resumeAgentsOnOpen = try c.decodeIfPresent(Bool.self, forKey: .resumeAgentsOnOpen) ?? true
            confirmCloseTerminal = try c.decodeIfPresent(Bool.self, forKey: .confirmCloseTerminal) ?? true
            confirmDeleteSession = try c.decodeIfPresent(Bool.self, forKey: .confirmDeleteSession) ?? true
            worktreeFolder = try c.decodeIfPresent(String.self, forKey: .worktreeFolder) ?? "~/Racky/worktrees"
            cleanSessionFolder = try c.decodeIfPresent(String.self, forKey: .cleanSessionFolder) ?? "~/Racky/sessions"
            projectsFolder = try c.decodeIfPresent(String.self, forKey: .projectsFolder) ?? "~/Racky/projects"
            branchPrefix = try c.decodeIfPresent(BranchPrefixMode.self, forKey: .branchPrefix) ?? .gitUser
            branchPrefixCustom = try c.decodeIfPresent(String.self, forKey: .branchPrefixCustom) ?? ""
            computerLeftovers = try c.decodeIfPresent(LeftoversPolicy.self, forKey: .computerLeftovers) ?? .days7
            leftoversOnCard = try c.decodeIfPresent(Bool.self, forKey: .leftoversOnCard) ?? true
            archivedWorktrees = try c.decodeIfPresent(KeepOrDelete.self, forKey: .archivedWorktrees) ?? .keep
            oldComputerImages = try c.decodeIfPresent(KeepOrDelete.self, forKey: .oldComputerImages) ?? .delete
        }
    }

    public struct Agents: Codable, Equatable, Sendable {
        public var defaultAgent = TerminalProvider.claude

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultAgent = try c.decodeIfPresent(TerminalProvider.self, forKey: .defaultAgent) ?? .claude
        }
    }

    public enum NotificationSound: String, Codable, Sendable, CaseIterable { case system, none }

    /// Settings › Notifications (03 §14.2, 06 §3.5). A permissão do sistema não vive aqui: só o usuário a pede, pelo botão da seção.
    public struct Notifications: Codable, Equatable, Sendable {
        public var needsInput = true
        public var finished = true
        public var failed = true
        public var terminalBell = false
        public var suppressWhenVisible = true
        public var sound = NotificationSound.system
        public var dockBadge = true

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            needsInput = try c.decodeIfPresent(Bool.self, forKey: .needsInput) ?? true
            finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
            failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? true
            terminalBell = try c.decodeIfPresent(Bool.self, forKey: .terminalBell) ?? false
            suppressWhenVisible = try c.decodeIfPresent(Bool.self, forKey: .suppressWhenVisible) ?? true
            sound = try c.decodeIfPresent(NotificationSound.self, forKey: .sound) ?? .system
            dockBadge = try c.decodeIfPresent(Bool.self, forKey: .dockBadge) ?? true
        }
    }

    public enum CursorStyle: String, Codable, Sendable, CaseIterable { case block, bar, underline }

    public struct Terminal: Codable, Equatable, Sendable {
        public static let fontSizeRange = 8...32
        public static let defaultFont = "SF Mono"
        public static let defaultTheme = "ghostty-default-dark"
        /// Famílias monoespaçadas que existem em todo macOS.
        public static let fontFamilies = ["SF Mono", "Menlo", "Monaco", "Courier New"]

        public var fontFamily = Terminal.defaultFont
        public var fontSize = 14
        /// A v1 traz só a paleta do dono (02 §3); a chave existe para a Fatia 2 em diante.
        public var theme = Terminal.defaultTheme
        public var cursor = CursorStyle.block
        public var cursorBlink = true

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? Terminal.defaultFont
            let size = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 14
            fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? Terminal.defaultTheme
            cursor = try c.decodeIfPresent(CursorStyle.self, forKey: .cursor) ?? .block
            cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? true
        }
    }
}

/// Validação dos campos de texto (03 §14.1 regra 3): valor inválido não grava e o anterior continua valendo.
public enum SettingsValidation {
    public static func folder(_ text: String) -> Result<String, SettingsValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.init("Enter a folder path.")) }
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else {
            return .failure(.init("Use an absolute path, starting with / or ~."))
        }
        return .success(trimmed.count > 1 && trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    public static func fontSize(_ text: String) -> Result<Int, SettingsValidationError> {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return .failure(.init("Enter a number from 8 to 32.")) }
        let range = AppSettings.Terminal.fontSizeRange
        guard range.contains(value) else { return .failure(.init("Size must be between \(range.lowerBound) and \(range.upperBound).")) }
        return .success(value)
    }

    public static func branchPrefix(_ text: String) -> Result<String, SettingsValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(" ") || trimmed.contains("..") || trimmed.hasPrefix("/") || trimmed.contains("~") {
            return .failure(.init("A branch prefix can't contain spaces, \"..\" or \"~\"."))
        }
        return .success(trimmed)
    }
}

public struct SettingsValidationError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

extension Int {
    /// Valor dentro do intervalo (settings vindos de arquivo antigo ou editado à mão).
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
