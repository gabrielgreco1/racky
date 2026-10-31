import RackyDocker
import Foundation
import Testing

@testable import RackyCore

/// Backend falso: grava o que as ferramentas pedem e devolve respostas programadas. O comportamento do Docker real é do teste vivo.
actor FakeBackend: ComputerBackend {
    var runtimeCalls: [(op: String, args: JSON)] = []
    var runtimeResponses: [String: JSON] = [:]
    var runtimeErrors: [String: ToolError] = [:]
    var execs: [BackendExec] = []
    var execHandler: (@Sendable (BackendExec) -> BackendExecOutcome)?
    var ingested: [JSON] = []
    var proxySwitches: [String] = []
    var renderResult: Result<JSON, ToolError> = .failure(ToolError(.notSupported, "the selected proxy has no render capability"))
    var proxyInfoJSON: JSON = ["render_supported": false]
    var jobOutcomes: [String: BackendExecOutcome] = [:]
    var cancelled: [String] = []
    private var counter = 0

    func setRuntime(_ op: String, _ json: JSON) { runtimeResponses[op] = json }
    func setRuntimeError(_ op: String, _ error: ToolError) { runtimeErrors[op] = error }
    func setExec(_ handler: @escaping @Sendable (BackendExec) -> BackendExecOutcome) { execHandler = handler }
    func setRender(_ result: Result<JSON, ToolError>) { renderResult = result }
    func setJob(_ id: String, _ outcome: BackendExecOutcome) { jobOutcomes[id] = outcome }

    func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON {
        runtimeCalls.append((operation, args))
        if let error = runtimeErrors[operation] { throw error }
        return runtimeResponses[operation] ?? ["ok": true, "url": "http://fake/", "title": "Fake", "ready": true]
    }

    func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome {
        execs.append(request)
        return execHandler?(request) ?? BackendExecOutcome(exitCode: 0, stdout: Data("ok\n".utf8), durationMs: 5)
    }

    func execStart(_ request: BackendExec) async throws -> String {
        execs.append(request)
        counter += 1
        let id = "job-\(counter)"
        jobOutcomes[id] = BackendExecOutcome(running: true)
        return id
    }

    func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome {
        guard let outcome = jobOutcomes[jobID] else { throw ToolError(.notFound, "no job") }
        return outcome
    }

    func execCancel(jobID: String) async throws -> BackendExecOutcome {
        cancelled.append(jobID)
        let outcome = BackendExecOutcome(running: false, exitCode: 143, stdout: Data("partial".utf8))
        jobOutcomes[jobID] = outcome
        return outcome
    }

    func ingest(_ payload: JSON) async throws -> String {
        ingested.append(payload)
        return payload["record"]?["id"]?.string ?? ULID.generate()
    }

    func switchProxy(to proxy: String, country: String?) async throws -> Int {
        proxySwitches.append(proxy + (country.map { ":\($0)" } ?? ""))
        return 3
    }

    func proxyInfo() async throws -> JSON { proxyInfoJSON }
    func usage() async throws -> JSON { ["requests": 4, "tunnels": 2, "bytes": 1000, "renders": 1] }
    func render(_ payload: JSON) async throws -> JSON { try renderResult.get() }
    var vncURL: URL?
    func setVNCURL(_ url: URL?) { vncURL = url }
    func vncEndpoint() async throws -> URL {
        guard let vncURL else { throw ToolError(.notSupported, "this computer has no screen") }
        return vncURL
    }
}

/// Uma pasta de run temporária por teste.
struct TempRun {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-mcp-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    var folder: RunFolder { RunFolder(root: root) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct Rig {
    let temp: TempRun
    let hub: ComputerHub
    let service: ComputerToolService
    let server: ComputerMCPServer
    let backend: FakeBackend
    let computer: ManagedComputer

    static func make(name: String = "box-a", display: ComputerDisplay = .headless, proxiesAllowed: [String] = [], children: [String] = ["child-1"],
                     state: BoxState = .ready) async throws -> Rig {
        let temp = try TempRun()
        let backend = FakeBackend()
        let computer = try ManagedComputer(name: name, display: display, run: temp.folder, backend: backend, state: state, proxiesAllowed: proxiesAllowed)
        let hub = ComputerHub()
        await hub.register(computer)
        for child in children { await hub.registerChild(id: child, capability: "cap-\(child)") }
        let service = ComputerToolService(hub: hub)
        return Rig(temp: temp, hub: hub, service: service, server: ComputerMCPServer(tools: service), backend: backend, computer: computer)
    }

    /// Chamada de ferramenta como o MCP faz: devolve `(isError, JSON do texto)`.
    @discardableResult
    func call(_ tool: String, _ args: JSON = [:], child: String = "child-1") async -> (isError: Bool, json: JSON, outcome: ToolOutcome) {
        let outcome = await service.call(tool, arguments: args, child: child)
        let text = outcome.content.first?["text"]?.string ?? "null"
        return (outcome.isError, (try? JSON.parse(text)) ?? .null, outcome)
    }

    func claim(child: String = "child-1", name: String? = nil) async {
        let result = await call("box_claim", ["name": .string(name ?? computer.name), "wait_s": 0], child: child)
        #expect(!result.isError, "claim failed: \(result.json.text)")
    }

    func cleanup() { temp.remove() }

    /// Escreve registros no `requests.jsonl` (o egress faz isso de verdade; aqui só o formato importa).
    func seedRequests(_ records: [[String: JSON]]) throws {
        let file = temp.folder.requestsFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = records.map { JSON.object($0).data() + Data([0x0A]) }.reduce(Data(), +)
        let existing = (try? Data(contentsOf: file)) ?? Data()
        try (existing + lines).write(to: file)
    }

    func seedBody(id: String, kind: String, text: String) throws {
        let dir = temp.folder.logs.appendingPathComponent("bodies")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("\(id).\(kind).txt"))
    }
}

func errorCode(_ result: (isError: Bool, json: JSON, outcome: ToolOutcome)) -> String? {
    result.isError ? result.json["error"]?.string : nil
}

/// O egress grava o bloqueio DURANTE a chamada; nos testes o backend falso faz o mesmo (síncrono, dentro do handler).
func appendRequestRecord(_ file: URL, _ record: [String: JSON]) {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = JSON.object(record).data() + Data([0x0A])
    if let handle = try? FileHandle(forWritingTo: file) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        try? handle.close()
    } else {
        try? line.write(to: file)
    }
}
