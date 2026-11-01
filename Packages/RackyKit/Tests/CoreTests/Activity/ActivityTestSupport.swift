import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation

/// Payloads reais gravados nos spikes S-05 e S-08 (`Tests/SpikeFixtures/`), lidos direto do repositório.
enum RealHooks {
    struct Raw {
        var name: String
        var object: [String: Any]
        var payload: ReducedHookPayload { HookPayloadReducer.reduce(object) }
    }

    static let evidenceRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/SpikeFixtures")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        fatalError("Tests/SpikeFixtures not found above \(#filePath)")
    }()

    static func data(_ relative: String) throws -> Data { try Data(contentsOf: evidenceRoot.appendingPathComponent(relative)) }

    /// Eventos do fixture `{events:[{tag,payload}]}`, sem os hooks de projeto (`project-*`), na ordem de chegada.
    static func events(_ relative: String) throws -> [Raw] {
        let root = try JSONSerialization.jsonObject(with: data(relative)) as! [String: Any]
        let list = root["events"] as! [[String: Any]]
        return list.compactMap { entry in
            let tag = entry["tag"] as! String
            guard !tag.hasPrefix("project-") else { return nil }
            let payload = entry["payload"] as! [String: Any]
            return Raw(name: payload["hook_event_name"] as! String, object: payload)
        }
    }

    static let claudeBasic = "S-05/claude-settings-hooks-payloads.json"
    static let claudePermission = "S-05/claude-permission-request.json"
    static let claudeSubagents = "S-08/subagent-hook-payloads.json"
    static let codex = "S-05/codex-hook-payloads.json"

    /// Converte para eventos do redutor com tempos crescentes de 1 ms.
    static func activityEvents(_ raws: [Raw], baseNs: Int64 = 1_800_000_000_000_000_000) -> [ActivityEvent] {
        raws.enumerated().map { ActivityEvent(name: $0.element.name, payload: $0.element.payload, atNs: baseNs + Int64($0.offset) * 1_000_000) }
    }

    static func envelopes(
        _ raws: [Raw], runID: UUID, paneID: UUID?, provider: HookProvider = .claude, baseNs: Int64 = 1_800_000_000_000_000_000
    ) -> [HookEnvelope] {
        raws.enumerated().map {
            HookEnvelope(
                id: "evt-\(runID.uuidString.prefix(8))-\($0.offset)", provider: provider, event: $0.element.name, runID: runID.uuidString,
                paneID: paneID?.uuidString, atNs: baseNs + Int64($0.offset) * 1_000_000, payload: $0.element.payload)
        }
    }
}

/// `RACKY_HOME` temporário e curto (o caminho do socket tem limite de 103 bytes).
struct ActivityHome {
    let root: URL
    let paths: StorePaths

    init() throws {
        root = URL(fileURLWithPath: "/tmp/abh-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        paths = StorePaths(root: root)
    }

    var socketPath: String { root.appendingPathComponent("run/app.sock").path }
    var spoolDirectory: URL { HookSpool.directory(forSocketPath: socketPath) }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func openStore() async throws -> RackyStore { try await RackyStore.open(paths: paths) }

    /// Terminal de teste persistido (sessão limpa + tab + terminal), para o `last_message` ter onde cair.
    func seedTerminal(_ store: RackyStore, provider: TerminalProvider = .claude, currentRunID: UUID? = nil) async throws -> Terminal {
        let session = Session(kind: .clean, folderPath: "/tmp/x", title: "quiet-harbor")
        let tabID = UUID.v7()
        let terminal = Terminal(
            tabID: tabID, provider: provider, title: "Claude", cwd: "/tmp/x", launchSpec: LaunchSpec(provider: provider),
            currentRunID: currentRunID, state: .running)
        let tab = Tab(id: tabID, sessionID: session.id, title: "Agent", layout: .leaf(Pane(content: .terminal(terminal.id))))
        try await store.saveBundle(session: session, tabs: [tab], terminals: [terminal])
        return terminal
    }
}
