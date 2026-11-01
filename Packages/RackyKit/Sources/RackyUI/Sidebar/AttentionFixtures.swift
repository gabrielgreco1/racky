import RackyProtocol
import RackyStore
import Foundation

/// Sessões de exemplo para a evidência de atenção (`RACKY_SCREEN=attention-demo`, banco isolado por `RACKY_HOME`).
/// Cada terminal de agente tem ID de terminal e de execução fixos: quem dirige a evidência dispara eventos reais com
/// `racky hook` (`RACKY_RUN_ID` + `RACKY_PANE_ID`) e o estado de cada card nasce deles. Nada é lançado no daemon.
public enum AttentionFixtures {
    public static let screenID = "attention-demo"

    public nonisolated struct Agent: Sendable {
        public var key: String
        public var sessionTitle: String
        public var project: String?
        public var terminalID: UUID
        public var runID: UUID
        public var provider: TerminalProvider
    }

    private static func id(_ n: Int, _ tag: String) -> UUID {
        let suffix = tag + String(repeating: "0", count: 12 - tag.count)
        return UUID(uuidString: String(format: "%08X-0000-4000-8000-", n) + suffix)!
    }

    /// Terminais com o estado que a evidência produz:
    /// `permission` needs input (permissão), `question` needs input (pergunta), `working`, `done`, `waiting` (2 subagentes),
    /// `failed` e `idle` (só `SessionStart`).
    public static let agents: [Agent] = [
        Agent(key: "permission", sessionTitle: "Fix pagination", project: "otter", terminalID: id(1, "A1"), runID: id(1, "B1"), provider: .claude),
        Agent(key: "question", sessionTitle: "Pick the listings table", project: "otter", terminalID: id(2, "A2"), runID: id(2, "B2"), provider: .claude),
        Agent(key: "working", sessionTitle: "shop-pr-checkout", project: "acme-motion", terminalID: id(3, "A3"), runID: id(3, "B3"), provider: .claude),
        Agent(key: "done", sessionTitle: "Arizona context recap", project: "acme-motion", terminalID: id(4, "A4"), runID: id(4, "B4"), provider: .claude),
        Agent(key: "waiting", sessionTitle: "sandperch", project: "acme-motion", terminalID: id(5, "A5"), runID: id(5, "B5"), provider: .claude),
        Agent(key: "failed", sessionTitle: "reboot-survivor", project: "acme-motion", terminalID: id(6, "A6"), runID: id(6, "B6"), provider: .claude),
        Agent(key: "idle", sessionTitle: "quiet-harbor", project: nil, terminalID: id(7, "A7"), runID: id(7, "B7"), provider: .claude),
    ]

    public static func cast(now: Date = Date(), home: String = NSHomeDirectory()) -> SidebarFixtures.Cast {
        var cast = SidebarFixtures.Cast()
        var projects: [String: Project] = [:]
        for (index, name) in ["acme-motion", "otter"].enumerated() {
            let p = Project(
                name: name, rootPath: "\(home)/Racky/worktrees/\(name)", gitRemoteURL: "git@github.com:acme/x.git", defaultBranch: "main",
                sortIndex: index, createdAt: now.addingTimeInterval(-30 * 86400))
            projects[name] = p
            cast.projects.append(p)
        }
        for (offset, agent) in agents.enumerated() {
            let active = now.addingTimeInterval(-Double(offset + 1) * 90)
            let project = agent.project.flatMap { projects[$0] }
            var worktreeID: UUID?
            var path = "\(home)/Racky/sessions/\(agent.sessionTitle)"
            if let project {
                let branch = agent.sessionTitle.lowercased().replacingOccurrences(of: " ", with: "-")
                let wt = Worktree(projectID: project.id, path: "\(project.rootPath)/\(branch)", branch: branch, createdAt: active)
                cast.worktrees.append(wt)
                worktreeID = wt.id
                path = wt.path
            }
            let session = Session(
                kind: project == nil ? .clean : .worktree, projectID: project?.id, worktreeID: worktreeID, folderPath: path,
                managedFolder: project == nil, title: agent.sessionTitle, lifecycle: .active, createdAt: active.addingTimeInterval(-3600),
                lastActiveAt: active)
            cast.sessions.append(session)
            let tabID = UUID.v7()
            var terminal = Terminal(
                id: agent.terminalID, tabID: tabID, provider: agent.provider, title: "Claude Code", cwd: path,
                launchSpec: LaunchSpec(provider: agent.provider), currentRunID: agent.runID, state: .running, createdAt: active, startedAt: active)
            terminal.coldLog = false
            let tab = Tab(
                id: tabID, sessionID: session.id, title: "Claude Code", sortIndex: 0, layout: .leaf(Pane(content: .terminal(terminal.id))),
                focusedTerminalID: terminal.id, createdAt: active)
            cast.tabs.append(tab)
            cast.terminals.append(terminal)
        }
        return cast
    }

    /// Grava o cenário no Store (idempotente).
    public static func seed(into store: RackyStore, home: String) async throws {
        try await SidebarFixtures.seed(cast(home: home), into: store)
    }
}
