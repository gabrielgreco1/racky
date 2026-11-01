import RackyProtocol
import RackyStore
import Foundation

/// Custo de uma atualização da sidebar (T2-11, AR-706: "sidebar rola a 120 Hz sem hitch" = projeção bem dentro de um quadro de 8,3 ms).
/// Uma atualização é o que cada evento de terminal causa: o Store entrega um snapshot novo, o modelo o aplica e a view lê a projeção.
/// Usado pelo `racky-bench` (Release) e pelos testes; só dados sintéticos, nada de Store nem de disco.
public enum SidebarCostProbe {
    public struct Result: Sendable {
        public let sessions: Int
        public let terminals: Int
        public let updates: Int
        public let milliseconds: [Double]
    }

    /// `sessions` sessões de worktree (3 projetos), cada uma com um agente e um shell; cada atualização troca o estado de um terminal.
    public static func measure(sessions count: Int, updates: Int) -> Result {
        let now = Date()
        let projects = (0 ..< 3).map { Project(name: "project-\($0)", rootPath: "/tmp/p\($0)", gitRemoteURL: "git@example.com:x/p\($0).git", defaultBranch: "main", sortIndex: $0, createdAt: now) }
        var sessions: [Session] = [], tabs: [Tab] = [], terminals: [Terminal] = []
        for i in 0 ..< count {
            let project = projects[i % projects.count]
            let session = Session(
                kind: .clean, projectID: project.id, folderPath: "/tmp/p\(i % 3)/s\(i)", managedFolder: false, title: "session-\(i)", unread: i % 4 == 0,
                lifecycle: .active, createdAt: now.addingTimeInterval(-Double(i) * 60), lastActiveAt: now.addingTimeInterval(-Double(i) * 30))
            sessions.append(session)
            for (j, provider) in [TerminalProvider.claude, .shell].enumerated() {
                var tab = Tab(sessionID: session.id, title: "t\(j)", sortIndex: j, layout: .leaf(Pane(content: .terminal(.v7()))), createdAt: now)
                let terminal = Terminal(
                    tabID: tab.id, provider: provider, title: "t\(j)", cwd: session.folderPath, launchSpec: LaunchSpec(provider: provider), state: .running,
                    createdAt: now, startedAt: now)
                tab.layout = .leaf(Pane(content: .terminal(terminal.id)))
                tab.focusedTerminalID = terminal.id
                tabs.append(tab)
                terminals.append(terminal)
            }
        }
        var snapshot = StoreSnapshot(projects: projects, sessions: sessions, tabs: tabs, terminals: terminals)
        let model = SidebarModel()
        model.apply(snapshot)
        _ = model.projection  // aquecimento
        var samples: [Double] = []
        for n in 0 ..< updates {
            let index = (n * 7) % snapshot.terminals.count
            snapshot.terminals[index].title = "t\(n)"
            snapshot.sessions[(index / 2) % snapshot.sessions.count].lastActiveAt = Date()
            let start = ContinuousClock.now
            model.apply(snapshot)
            let projection = model.projection
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            if projection.sessionOrder.isEmpty { samples.append(.infinity) }
        }
        return Result(sessions: count, terminals: terminals.count, updates: updates, milliseconds: samples)
    }
}
