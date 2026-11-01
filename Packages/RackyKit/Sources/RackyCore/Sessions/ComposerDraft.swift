import RackyProtocol
import Foundation

/// "Where" do composer (03 §6.1 campo 2): com projeto `newWorktree` · `existingWorktree` · `mainCheckout`; sem projeto
/// `newFolder` · `chooseFolder`.
public enum ComposerWhere: String, Sendable, CaseIterable, Codable {
    case newWorktree, existingWorktree, mainCheckout, newFolder, chooseFolder
}

/// Campo do composer que carrega um erro de validação (`overlay.composer.<campo>.error`, 03 §6.3).
public enum ComposerField: String, Sendable, Equatable {
    case project, createFrom, worktree, folder, name, branch, prompt
}

public struct ComposerIssue: Sendable, Equatable {
    public enum Recovery: Sendable, Equatable { case reuseBranch }
    public var field: ComposerField
    public var message: String
    public var recovery: Recovery?

    public init(_ field: ComposerField, _ message: String, recovery: Recovery? = nil) {
        self.field = field; self.message = message; self.recovery = recovery
    }
}

/// Fatos do mundo que o rascunho precisa para derivar nomes, caminhos e validar. Montado pela UI a partir do Store,
/// das Settings e de consultas Git assíncronas; aqui é só dado.
public struct ComposerContext: Sendable {
    public var project: Project?
    /// Branch padrão do repositório (`main`); `nil` enquanto não se sabe.
    public var defaultBranch: String?
    /// Prefixo normalizado (`octocat`) ou `nil` (modo `none`).
    public var branchPrefix: String?
    /// Raiz das worktrees já com `~` expandido (`/Users/x/Racky/worktrees`).
    public var worktreeRoot: String
    /// Raiz das sessões limpas (`/Users/x/Racky/sessions`).
    public var cleanSessionRoot: String
    /// Resultado da consulta do texto de "Create from" no repositório; `nil` = ainda consultando ou sem texto.
    public var createFromLookup: GitBranchLookup?
    /// Idem para o nome digitado em Advanced › Branch name (branch que já existe vira erro com `Reuse it`).
    public var branchNameLookup: GitBranchLookup?
    /// Worktrees do projeto (inclui o checkout principal).
    public var worktrees: [Worktree]
    /// Título da sessão que já usa cada worktree (`Used by <session>`).
    public var worktreeUsers: [UUID: String]
    public var catalog: ProfileCatalog
    public var home: String

    public init(
        project: Project? = nil, defaultBranch: String? = nil, branchPrefix: String? = nil, worktreeRoot: String,
        cleanSessionRoot: String, createFromLookup: GitBranchLookup? = nil, branchNameLookup: GitBranchLookup? = nil, worktrees: [Worktree] = [],
        worktreeUsers: [UUID: String] = [:], catalog: ProfileCatalog = ProfileCatalog(),
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.project = project; self.defaultBranch = defaultBranch; self.branchPrefix = branchPrefix
        self.worktreeRoot = worktreeRoot; self.cleanSessionRoot = cleanSessionRoot; self.createFromLookup = createFromLookup
        self.branchNameLookup = branchNameLookup
        self.worktrees = worktrees; self.worktreeUsers = worktreeUsers; self.catalog = catalog; self.home = home
    }

    /// Nome do repositório (pasta da raiz do projeto).
    public var repoName: String? { project.map { URL(fileURLWithPath: $0.rootPath).lastPathComponent } }
}

/// O que o usuário preencheu no composer (03 §6). Valor puro: o modelo da UI guarda um e as regras de nome, caminho,
/// validação e resumo ficam aqui, testáveis sem UI.
public struct ComposerDraft: Sendable, Equatable {
    public var projectID: UUID?
    public var whereChoice: ComposerWhere
    public var createFrom = ""
    /// "Reuse existing branch" (M-111): vale quando o texto de "Create from" é um branch que existe.
    public var reuseBranch = true
    /// Base escolhida no seletor `origin/main ⌄`; `nil` = `origin/<padrão>`.
    public var baseRef: String?
    public var worktreeID: UUID?
    public var folderPath: String?
    public var provider: TerminalProvider = .claude
    public var profileID: UUID?
    public var prompt = ""
    public var sessionName = ""
    public var branchName = ""
    /// Raiz de worktrees escolhida em `[Change…]`; `nil` = a das Settings.
    public var locationRoot: String?
    /// Nome automático (`quiet-harbor`), fixo enquanto o composer está aberto.
    public var automaticName: String
    public var createMore = false
    /// "Subagent computers" da sessão nova (F12): começa no padrão de Settings › Computers.
    public var subagentComputers = SubagentComputersMode.off
    /// "Subagents run as" (spec subagent-harness): quem roda os subagentes da sessão nova.
    public var subagentHarness = SubagentHarness.claude
    /// "Save data to" (spec data-hub): `racky` (dataset da sessão) ou a chave de um lugar de uma conexão (`table:<conexão>:<schema>:<nome>`).
    public var dataDestination = "racky"

    public init(projectID: UUID? = nil, whereChoice: ComposerWhere? = nil, automaticName: String = SessionNaming.automaticName()) {
        self.projectID = projectID
        self.whereChoice = whereChoice ?? ComposerDraft.defaultWhere(hasProject: projectID != nil, kind: .git)
        self.automaticName = automaticName
    }

    public static func defaultWhere(hasProject: Bool, kind: ProjectKind) -> ComposerWhere {
        guard hasProject else { return .newFolder }
        return kind == .git ? .newWorktree : .mainCheckout
    }

    /// Opções do segmented para o contexto atual (03 §6.1 campo 2).
    public static func availableWheres(hasProject: Bool, kind: ProjectKind) -> [ComposerWhere] {
        guard hasProject else { return [.newFolder, .chooseFolder] }
        return kind == .git ? [.newWorktree, .existingWorktree, .mainCheckout] : [.mainCheckout]
    }

    // MARK: Derivados

    /// O prompt que vai no argv: `Blank Terminal` não tem prompt (o campo some).
    public var effectivePrompt: String {
        provider == .shell ? "" : prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasData: Bool {
        !prompt.isEmpty || !createFrom.isEmpty || !sessionName.isEmpty || !branchName.isEmpty
    }

    /// Nome da sessão: o digitado; senão as primeiras palavras do prompt; senão adjetivo + substantivo.
    public var sessionTitle: String {
        let typed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return SessionNaming.title(fromPrompt: effectivePrompt) ?? automaticName
    }

    /// Base do slug da pasta e do branch: o nome digitado ou o derivado do prompt (kebab-case).
    public var slug: String { GitNaming.slug(from: sessionTitle) }

    /// Texto de "Create from" sem espaços nas pontas.
    public var createFromText: String { createFrom.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `#123` ou URL do GitHub: reconhecidos, mas a Fatia 1 só aceita nome de branch (09 T1-20).
    public var createFromIsReference: Bool {
        let text = createFromText
        if text.hasPrefix("#"), Int(text.dropFirst()) != nil { return true }
        return text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("github.com/")
    }

    /// Branch padrão da nova worktree: `<prefixo>/<slug>`.
    public func defaultBranchName(_ context: ComposerContext) -> String {
        context.branchPrefix.map { "\($0)/\(slug)" } ?? slug
    }

    /// Branch exibido no campo Advanced (o digitado ou o padrão).
    public func shownBranchName(_ context: ComposerContext) -> String {
        branchName.isEmpty ? defaultBranchName(context) : branchName
    }

    /// Raiz das worktrees efetiva (`[Change…]` ou Settings).
    public func effectiveWorktreeRoot(_ context: ComposerContext) -> String { locationRoot ?? context.worktreeRoot }

    /// `<raiz>/<repo>/<slug>` (03 §6.2); a colisão `-2` só se resolve na criação.
    public func worktreeLocation(_ context: ComposerContext) -> String? {
        guard let repo = context.repoName else { return nil }
        return "\(effectiveWorktreeRoot(context))/\(repo)/\(slug)"
    }

    /// Caminho que vai aparecer no resumo.
    public func targetPath(_ context: ComposerContext) -> String? {
        switch whereChoice {
        case .newWorktree: return worktreeLocation(context)
        case .existingWorktree, .mainCheckout:
            if whereChoice == .mainCheckout, context.project?.kind == .folder { return context.project?.rootPath }
            let wt = whereChoice == .mainCheckout ? context.worktrees.first(where: \.isMain) : context.worktrees.first { $0.id == worktreeID }
            return wt?.path ?? (whereChoice == .mainCheckout ? context.project?.rootPath : nil)
        case .newFolder: return "\(context.cleanSessionRoot)/\(cleanFolderBase)"
        case .chooseFolder: return folderPath
        }
    }

    /// Nome-base da pasta nova gerenciada: o slug do que o usuário (ou o prompt) deu; sem nada, o automático.
    public var cleanFolderBase: String {
        let typed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, SessionNaming.title(fromPrompt: effectivePrompt) == nil { return automaticName }
        return slug
    }

    public func spec() -> LaunchSpec {
        LaunchSpec(provider: provider, profileID: profileID, initialPrompt: effectivePrompt.isEmpty ? nil : effectivePrompt)
    }

    // MARK: Validação

    /// Erros que impedem criar (03 §6.3: o botão só fica desabilitado se faltar projeto ou pasta; o resto vira caixa de erro).
    public func issues(_ context: ComposerContext) -> [ComposerIssue] {
        var out: [ComposerIssue] = []
        switch whereChoice {
        case .newWorktree:
            if context.project == nil { out.append(ComposerIssue(.project, "Choose a project.")) }
            let text = createFromText
            if !text.isEmpty {
                if createFromIsReference {
                    out.append(ComposerIssue(.createFrom, "Links and #numbers need GitHub support. Type a branch name for now."))
                } else if context.createFromLookup == GitBranchLookup.none {
                    out.append(ComposerIssue(.createFrom, "No branch named \"\(text)\" in this repository."))
                }
            }
            if branchName.contains(where: \.isWhitespace) || branchName.hasPrefix("-") {
                out.append(ComposerIssue(.branch, "A branch name can't contain spaces or start with a dash."))
            } else if !branchName.isEmpty, context.branchNameLookup == .local || context.branchNameLookup == .remote {
                out.append(ComposerIssue(.branch, "Branch \"\(branchName)\" already exists.", recovery: .reuseBranch))
            }
        case .existingWorktree:
            if context.project == nil { out.append(ComposerIssue(.project, "Choose a project.")) }
            else if worktreeID == nil || !context.worktrees.contains(where: { $0.id == worktreeID }) {
                out.append(ComposerIssue(.worktree, "Choose a worktree."))
            }
        case .mainCheckout:
            if context.project == nil { out.append(ComposerIssue(.project, "Choose a project.")) }
        case .newFolder:
            break
        case .chooseFolder:
            if folderPath == nil || folderPath?.isEmpty == true { out.append(ComposerIssue(.folder, "Choose a folder.")) }
        }
        return out
    }

    /// Aviso de uma linha que não bloqueia (03 §6.1 campo 3b).
    public func warning(_ context: ComposerContext) -> String? {
        guard whereChoice == .existingWorktree, let id = worktreeID, context.worktreeUsers[id] != nil else { return nil }
        return "Another session already uses this worktree."
    }

    /// Só o que impede o botão: faltar projeto ou pasta (03 §6.3).
    public func canSubmit(_ context: ComposerContext) -> Bool {
        issues(context).isEmpty
    }

    // MARK: Resumo e pedido

    /// `claude --dangerously-skip-permissions "Fix the search pagination…" in ~/Racky/worktrees/acme-platform/fix-search-pagination`.
    public func summary(_ context: ComposerContext) -> String {
        let command = LaunchPreview.command(spec: spec(), catalog: context.catalog, projectID: projectID)
        guard let path = targetPath(context) else { return command }
        return "\(command) in \(Self.abbreviate(path, home: context.home))"
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Pedido de criação para o `SessionCreationService`. `nil` quando o rascunho é inválido.
    public func request(
        _ context: ComposerContext, fetch: GitFetchPolicy = .fetchFirst, forceExistingBranch: String? = nil,
        ids: (session: UUID, tab: UUID, terminal: UUID) = (.v7(), .v7(), .v7())
    ) -> SessionCreationRequest? {
        guard canSubmit(context) else { return nil }
        let target: SessionPlacement
        switch whereChoice {
        case .newWorktree:
            guard let project = context.project else { return nil }
            let root = URL(fileURLWithPath: effectiveWorktreeRoot(context), isDirectory: true)
            let text = createFromText
            let source: GitWorktreeSource
            if let forced = forceExistingBranch {
                source = .existingBranch(forced)
            } else if !text.isEmpty, context.createFromLookup != nil, context.createFromLookup != GitBranchLookup.none, reuseBranch {
                source = .existingBranch(text)
            } else {
                let base: String? = !text.isEmpty ? text : baseRef
                if branchName.isEmpty {
                    source = .newBranch(slug: slug, prefix: context.branchPrefix.map(GitBranchPrefix.custom) ?? .none, baseRef: base)
                } else {
                    source = .newBranchExact(name: branchName, baseRef: base)
                }
            }
            target = .newWorktree(NewWorktreeSpec(projectID: project.id, source: source, worktreeRoot: root, fetch: fetch))
        case .existingWorktree:
            guard let id = worktreeID else { return nil }
            target = .existingCheckout(worktreeID: id)
        case .mainCheckout:
            guard let project = context.project else { return nil }
            if project.kind == .folder {
                target = .projectFolder(projectID: project.id)
            } else if let main = context.worktrees.first(where: \.isMain) {
                target = .existingCheckout(worktreeID: main.id)
            } else {
                return nil
            }
        case .newFolder:
            let base = cleanFolderBase
            let root = URL(fileURLWithPath: context.cleanSessionRoot, isDirectory: true)
            target = .cleanFolder(path: root.appendingPathComponent(base, isDirectory: true).path, managed: true)
        case .chooseFolder:
            guard let folder = folderPath else { return nil }
            target = .cleanFolder(path: folder, managed: false)
        }
        return SessionCreationRequest(
            sessionID: ids.session, tabID: ids.tab, terminalID: ids.terminal, title: sessionTitle, target: target, spec: spec(),
            subagentComputers: provider.supportsSubagentComputers ? subagentComputers : .off,
            subagentHarness: provider.supportsSubagentComputers ? subagentHarness : .claude)
    }

    /// `Reuse it` (03 §6.3): o branch digitado em Advanced passa a ser o de "Create from", reaproveitado.
    public mutating func reuseTypedBranch() {
        guard !branchName.isEmpty else { return }
        createFrom = branchName
        branchName = ""
        reuseBranch = true
    }

    /// Limpa o que é "desta sessão" depois de um Create More; projeto, onde, agente e perfil ficam.
    public mutating func resetForNext(automaticName next: String = SessionNaming.automaticName()) {
        prompt = ""
        createFrom = ""
        sessionName = ""
        branchName = ""
        reuseBranch = true
        automaticName = next
    }
}
