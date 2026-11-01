import RackyProtocol
import RackyStore
import Foundation

/// Dados de exemplo da sidebar para evidência visual e snapshot tests (nomes `F-LONG`, vazio, 3 projetos).
/// Só são gravados com `RACKY_SCREEN=sidebar-demo` (banco isolado por `RACKY_HOME`) ou nos testes; nunca em uso normal.
public enum SidebarFixtures {
    public static let screenID = "sidebar-demo"

    /// Os três projetos do cenário padrão.
    public struct Cast: Sendable {
        public var projects: [Project] = []
        public var worktrees: [Worktree] = []
        public var sessions: [Session] = []
        public var tabs: [Tab] = []
        public var terminals: [Terminal] = []
        public var snapshot: StoreSnapshot {
            StoreSnapshot(projects: projects, worktrees: worktrees, sessions: sessions, tabs: tabs, terminals: terminals)
        }
        /// Sessão que a evidência deixa selecionada ("ativo").
        public var selectedSessionID: UUID?
        /// Projeto sem sessões, para o estado "No sessions".
        public var emptyProjectID: UUID?
        /// Projeto que recebe a linha pendente.
        public var pendingProjectID: UUID?
    }

    private static func ago(_ now: Date, minutes: Double = 0, hours: Double = 0, days: Double = 0) -> Date {
        now.addingTimeInterval(-(minutes * 60 + hours * 3600 + days * 86400))
    }

    /// Cenário completo: 3 projetos (um com 7 sessões -> `Show 2 more`, um vazio), sessões limpas, nome longo, não lida,
    /// agentes em vários estados de processo.
    public static func full(now: Date = Date(), home: String = NSHomeDirectory()) -> Cast {
        var c = Cast()

        func project(_ name: String, kind: ProjectKind = .git, remote: String? = "git@github.com:acme/x.git", index: Int) -> Project {
            let p = Project(
                name: name, kind: kind, rootPath: "\(home)/Racky/worktrees/\(name)", gitRemoteURL: kind == .git ? remote : nil,
                defaultBranch: kind == .git ? "main" : nil, sortIndex: index, createdAt: ago(now, days: 30))
            c.projects.append(p)
            return p
        }

        func session(
            _ p: Project?, title: String, branch: String? = nil, kind: SessionKind = .worktree, main: Bool = false,
            active: Date, unread: Bool = false, note: String? = nil, folder: String? = nil, terminals: [(TerminalProvider, TerminalProcessState, String, Int?)]
        ) -> Session {
            var worktreeID: UUID?
            var path = folder ?? "\(home)/Racky/sessions/\(title)"
            if let p, let branch {
                let wt = Worktree(projectID: p.id, path: "\(p.rootPath)/\(branch.replacingOccurrences(of: "/", with: "-"))", branch: branch, isMain: main, createdAt: active)
                c.worktrees.append(wt)
                worktreeID = wt.id
                path = wt.path
            }
            let s = Session(
                kind: kind, projectID: p?.id, worktreeID: worktreeID, folderPath: path, managedFolder: kind == .clean, title: title,
                statusNote: note.map { StatusNote(text: $0, author: "user", at: active) }, unread: unread, lifecycle: .active,
                createdAt: active.addingTimeInterval(-3600), lastActiveAt: active)
            c.sessions.append(s)
            for (i, spec) in terminals.enumerated() {
                let tab = Tab(sessionID: s.id, title: spec.2, sortIndex: i, layout: .leaf(Pane(content: .terminal(.v7()))), createdAt: active)
                var t = Terminal(
                    tabID: tab.id, provider: spec.0, title: spec.2, titleSource: spec.0 == .shell && spec.2 != "zsh" ? .osc : .auto, cwd: path,
                    launchSpec: LaunchSpec(provider: spec.0), state: spec.1, exitCode: spec.3, createdAt: active, startedAt: spec.1 == .notStarted ? nil : active)
                if spec.1 == .exited || spec.1 == .killed { t.endedAt = active }
                var fixedTab = tab
                fixedTab.layout = .leaf(Pane(content: .terminal(t.id)))
                fixedTab.focusedTerminalID = t.id
                c.tabs.append(fixedTab)
                c.terminals.append(t)
            }
            return s
        }

        let motion = project("acme-motion", index: 0)
        let main = session(
            motion, title: "main", branch: "main", kind: .checkout, main: true, active: ago(now, minutes: 2),
            terminals: [(.claude, .running, "main", nil)])
        c.selectedSessionID = main.id
        _ = session(
            motion, title: "Arizona context recap", branch: "arizona-context-recap", active: ago(now, days: 5),
            terminals: [(.claude, .running, "Artefato UI para cliente Arizona - proposta v2", nil)])
        _ = session(
            motion, title: "sandperch", branch: "sandperch", active: ago(now, hours: 3),
            terminals: [
                (.claude, .running, "Review motion tokens", nil), (.codex, .running, "Port motion shadows", nil),
                (.claude, .launching, "Write snapshot tests", nil), (.opencode, .interrupted, "Check A11y IDs", nil),
                (.claude, .exited, "Lint pass", 0),
            ])
        _ = session(
            motion, title: "Shaq ia dias slack", branch: "shaq-ia-dias-slack", active: ago(now, days: 2), unread: true,
            terminals: [(.claude, .running, "Artefato da call IA Dias - No updates", nil)])
        _ = session(
            motion, title: "shop-pr-checkout-with-an-extremely-long-session-name-that-must-truncate-at-the-end",
            branch: "me/shop-pr-checkout-with-an-extremely-long-branch-name-for-the-f-long-fixture",
            active: ago(now, minutes: 40),
            terminals: [(.claude, .exited, "Fix the failing bronze job", 1), (.shell, .running, "zsh", nil), (.shell, .running, "pnpm dev", nil)])
        _ = session(
            motion, title: "imported-chore", branch: "chore/imported", active: ago(now, days: 3),
            terminals: [(.claude, .notStarted, "Claude Code", nil)])
        _ = session(
            motion, title: "reboot-survivor", branch: "fix/reboot-survivor", active: ago(now, days: 4),
            terminals: [(.claude, .interrupted, "Resume the migration", nil)])

        let otter = project("otter", index: 1)
        c.pendingProjectID = otter.id
        _ = session(otter, title: "Fix pagination", branch: "fix/pagination", active: ago(now, minutes: 1), terminals: [(.codex, .launching, "Codex", nil)])
        _ = session(otter, title: "Detached HEAD check", branch: "HEAD", active: ago(now, hours: 7), terminals: [(.claude, .running, "Inspect detached HEAD", nil)])

        let empty = project("racky", kind: .folder, index: 2)
        c.emptyProjectID = empty.id

        _ = session(
            nil, title: "quiet-harbor", kind: .clean, active: ago(now, minutes: 12),
            terminals: [(.claude, .running, "Explore the search API", nil)])
        _ = session(
            nil, title: "swift-otter", kind: .clean, active: ago(now, hours: 26),
            terminals: [(.shell, .exited, "zsh", 0)])
        return c
    }

    /// Só o essencial para os testes de um projeto.
    public static func minimal(now: Date = Date(), home: String = NSHomeDirectory()) -> Cast {
        var c = Cast()
        let p = Project(name: "otter", rootPath: "\(home)/otter", createdAt: now)
        c.projects = [p]
        let wt = Worktree(projectID: p.id, path: "\(home)/otter-wt", branch: "feat/x", createdAt: now)
        c.worktrees = [wt]
        let s = Session(kind: .worktree, projectID: p.id, worktreeID: wt.id, folderPath: wt.path, title: "Fix pagination", createdAt: now, lastActiveAt: now)
        c.sessions = [s]
        c.selectedSessionID = s.id
        return c
    }

    /// Grava o cenário no Store (uma transação por sessão). Idempotente: não faz nada se já há projetos.
    public static func seed(_ cast: Cast, into store: RackyStore) async throws {
        guard try await store.projects(includeArchived: true).isEmpty else { return }
        for p in cast.projects { try await store.save(p) }
        for w in cast.worktrees { try await store.save(w) }
        for s in cast.sessions {
            let tabs = cast.tabs.filter { $0.sessionID == s.id }
            let terms = cast.terminals.filter { t in tabs.contains { $0.id == t.tabID } }
            try await store.saveBundle(session: s, tabs: tabs, terminals: terms)
        }
    }
}
