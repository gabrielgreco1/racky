import RackyCore
import RackyDesignSystem
import RackyDocker
import RackyProtocol
import RackyStore
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Imagens de referência (e evidência) do F12, renderizadas fora da tela, sem janela: o card da sessão com o ícone "Subagent computers",
/// a linha do agente com o chevron e uma linha por subagente, o card de aprovação do modo Ask, o hover card com a pré-visualização do
/// computador e o Settings › Computers. Gravar com `RACKY_RECORD_SNAPSHOTS=1`.
actor FrameBackend: ComputerBackend {
    let jpeg: Data
    init(jpeg: Data) { self.jpeg = jpeg }
    func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON {
        if operation == "frame" { return ["jpeg_b64": .string(jpeg.base64EncodedString()), "url": "https://aca-prod.example.test/listings/search"] }
        return ["ok": true, "url": "https://aca-prod.example.test/listings/search", "title": "Listing Search", "cookies": [], "tabs": []]
    }
    func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func execStart(_ request: BackendExec) async throws -> String { "job" }
    func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func execCancel(jobID: String) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func ingest(_ payload: JSON) async throws -> String { "id" }
    func switchProxy(to proxy: String, country: String?) async throws -> Int { 0 }
    func proxyInfo() async throws -> JSON { [:] }
    func usage() async throws -> JSON { [:] }
    func render(_ payload: JSON) async throws -> JSON { [:] }
    func vncEndpoint() async throws -> URL { URL(string: "ws://127.0.0.1:1/vnc?ticket=t")! }
}

@MainActor
@Suite("F12 - snapshots dos subagentes", .serialized) struct SubagentSnapshotTests {
    static let now = Date()

    /// "Captura" de tela de mentira: um portal de listings desenhado em JPEG.
    static func fakeScreen() -> Data {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.13, green: 0.32, blue: 0.62, alpha: 1).setFill()
        NSRect(x: 0, y: 340, width: 640, height: 60).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white]
        "City of Houston · Listings".draw(at: NSPoint(x: 24, y: 354), withAttributes: title)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray]
        "Search listings by address or number".draw(at: NSPoint(x: 24, y: 290), withAttributes: body)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 230, width: 420, height: 40), xRadius: 6, yRadius: 6).fill()
        NSColor.lightGray.setStroke()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 230, width: 420, height: 40), xRadius: 6, yRadius: 6).stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
        return rep?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
    }

    func render(_ view: some View, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "subagents", line: line)
        }
    }

    /// Ambiente com uma sessão Claude em modo Ask, três subagentes (dois com computador) e um computador reservado na fila.
    func world() async throws -> (env: AppEnvironment, computers: ComputersModel, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abx-snap-\(UUID().uuidString.lowercased())", isDirectory: true)
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1"])
        env.sidebar.clock = { Self.now }
        var session = Session(kind: .clean, folderPath: "/tmp/houston-listings", managedFolder: true, title: "houston-listings", createdAt: Self.now.addingTimeInterval(-7200), lastActiveAt: Self.now)
        session.subagentComputers = .ask
        let tab = Tab(sessionID: session.id, title: "Claude", layout: .leaf(Pane(content: .terminal(UUID()))))
        let terminal = Terminal(
            tabID: tab.id, provider: .claude, title: "Claude Code", cwd: "/tmp", launchSpec: LaunchSpec(provider: .claude), state: .running,
            lastMessage: "Study the Houston listings portal", createdAt: Self.now.addingTimeInterval(-7200), startedAt: Self.now.addingTimeInterval(-7200))
        env.sidebar.apply(StoreSnapshot(sessions: [session], tabs: [tab], terminals: [terminal]))
        _ = env.sidebar.select(session.id)
        env.subagentComputers.noteLaunched(terminal: terminal.id, mode: .ask)
        let attention = try #require(env.attention)
        attention.contexts = { [sidebar = env.sidebar] in sidebar.attentionContexts() }
        let children = [
            SubagentInfo(agentID: "a1", agentType: "racky-worker-1", title: "Study the Houston listings portal", phase: .running, startedAt: Self.now.addingTimeInterval(-38 * 60)),
            SubagentInfo(agentID: "a2", agentType: "racky-worker-2", title: "Find the hidden search API of Austin", phase: .running, startedAt: Self.now.addingTimeInterval(-62 * 60)),
            SubagentInfo(agentID: "a3", agentType: "general-purpose", title: "Summarize the fee schedule PDF", phase: .done, startedAt: Self.now.addingTimeInterval(-3 * 3600), endedAt: Self.now.addingTimeInterval(-2 * 3600)),
        ]
        attention.handle(ActivityService.Update(runID: UUID(), terminalID: terminal.id, activity: .waitingOnSubagents, liveChildren: 2, children: children))
        // Computadores: dois em uso (um por subagente com computador) e um reservado, esperando memória.
        let jpeg = Self.fakeScreen()
                let model = env.computers.model
        for name in ["houston-listings", "austin-search"] {
            let computer = try ManagedComputer(name: name, display: .headless, run: RunFolder(root: folder.appendingPathComponent(name)), backend: FrameBackend(jpeg: jpeg))
            await computer.setState(.ready)
            await model.attach(computer)
            model.sessionIDs[name] = session.id
        }
        let queued = try ManagedComputer(name: "dallas-tx", display: .headless, run: RunFolder(root: folder.appendingPathComponent("dallas-tx")), backend: LazyComputerBackend(), state: .queued)
        await queued.setState(.queued, position: 1)
        await model.attach(queued)
        model.sessionIDs["dallas-tx"] = session.id
        model.agentComputers = ["a1": "houston-listings", "a2": "austin-search"]
        await model.refresh(withThumbnails: true)
        await model.refresh(withThumbnails: false)
        return (env, model, folder)
    }

    @Test func sessionCardWithAgentRowChevronAndSubagentRows() async throws {
        let (env, _, folder) = try await world()
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = SidebarView(model: env.sidebar)
            .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements)
        render(view, size: CGSize(width: 300, height: 520), name: "sessionCard")
    }

    @Test func approvalCardsAtTheTopOfThePane() async throws {
        let (env, model, folder) = try await world()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try #require(env.sidebar.snapshot.sessions.first)
        model.setApprovals([
            { var r = ComputerApprovalRequest(
                parentID: "p", sessionID: session.id, sessionTitle: "houston-listings", names: ["houston-listings"], display: .headless, proxy: "direct")
              r.leftovers = .days7
              return r }(),
        ])
        let view = ComputerApprovalStack(model: model, session: session.id)
            .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements)
        render(view, size: CGSize(width: 760, height: 110), name: "approvalCard")
        model.setApprovals([
            ComputerApprovalRequest(
                kind: .spawn, subject: "Study the Houston listings portal", parentID: "p", sessionID: session.id, sessionTitle: "houston-listings",
                names: ["Study the Houston listings portal"], display: .headless, proxy: "direct"),
        ])
        render(view, size: CGSize(width: 640, height: 110), name: "spawnApprovalCard")
    }

    @Test func hoverCardShowsTheLivePreviewNameUrlAndDiaryLine() async throws {
        let (env, model, folder) = try await world()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try #require(env.sidebar.snapshot.sessions.first)
        #expect(env.registry.isRendered(.computerOpenViewer), "viewer action is registered so the preview renders")
        let state = SubagentHoverCardState()
        state.computer = "houston-listings"
        state.session = session.id
        state.child = "a1"
        let controller = SubagentHoverCardController(computers: env.computers, registry: env.registry, elements: env.elements)
        let view = SubagentHoverCardView(model: model, state: state, controller: controller)
            .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements)
        render(view, size: CGSize(width: SubagentCardMetrics.width, height: SubagentCardMetrics.height), name: "hoverCard")
        #expect(model.rows.first { $0.id == "houston-listings" }?.thumbnail != nil, "the preview frame came from the computer")
    }

    @Test func settingsComputersSection() async throws {
        let (env, _, folder) = try await world()
        defer { try? FileManager.default.removeItem(at: folder) }
        env.settings.select("computers")
        env.settings.change("Subagent computers") { $0.computers.defaultSubagentMode = .ask }
        env.settings.open()
        render(SettingsView(model: env.settings).environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements), size: CGSize(width: 1000, height: 420), name: "settingsComputers")
    }
}
