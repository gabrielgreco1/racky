import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

private func rpc(_ method: String, id: JSON? = 1, params: JSON? = nil) -> Data {
    var object: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
    if let id { object["id"] = id }
    if let params { object["params"] = params }
    return JSON.object(object).data()
}

@Suite struct MCPServerTests {
    func server(_ rig: Rig) -> ComputerMCPServer { rig.server }

    func reply(_ rig: Rig, _ data: Data, child: String = "child-1") async throws -> JSON {
        try JSON.parse(try #require(await rig.server.handle(data, child: child)))
    }

    @Test func initializeNegotiatesTheVersionAndCarriesTheInstructions() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let out = try await reply(rig, rpc("initialize", params: ["protocolVersion": "2025-06-18"]))
        #expect(out["jsonrpc"] == "2.0" && out["id"] == 1)
        #expect(out["result"]?["protocolVersion"] == "2025-06-18")
        #expect(out["result"]?["serverInfo"]?["name"] == "racky")
        #expect(out["result"]?["capabilities"]?["tools"] != nil)
        let instructions = try #require(out["result"]?["instructions"]?.string)
        #expect(instructions.count <= 1500 && instructions.contains("untrusted"))
        let unknown = try await reply(rig, rpc("initialize", params: ["protocolVersion": "1999-01-01"]))
        #expect(unknown["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func toolsListAnnouncesEveryToolWithItsExactSchema() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let out = try await reply(rig, rpc("tools/list", id: "abc"))
        #expect(out["id"] == "abc")
        let tools = try #require(out["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == ToolCatalog.all.map(\.name))
        let open = try #require(tools.first { $0["name"] == "browser_open" })
        #expect(open["inputSchema"]?["required"] == ["url"])
        #expect(open["inputSchema"]?["properties"]?["wait_until"]?["enum"] == ["load", "domcontentloaded", "networkidle"])
        #expect(open["inputSchema"]?["additionalProperties"] == false)
        // o modelo nunca vê a identidade nem o token de roteamento
        let everything = tools.map { $0.text }.joined()
        for secret in ["capability", "route_token", "agent_id", "child"] { #expect(!everything.contains(secret), "schema leaks \(secret)") }
        #expect(!tools.contains { $0["name"]?.string == "desktop_action" })
    }

    @Test func notificationsGetNoReplyAndPingIsEmpty() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        #expect(await rig.server.handle(rpc("notifications/initialized", id: nil), child: "child-1") == nil)
        #expect(try await reply(rig, rpc("ping"))["result"] == [:])
    }

    @Test func toolCallsReturnContentBlocksAndErrorsAreToolErrorsNotProtocolErrors() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let claim = try await reply(rig, rpc("tools/call", params: ["name": "box_claim", "arguments": ["name": "box-a", "wait_s": 0]]))
        #expect(claim["result"]?["isError"] == false)
        let text = try #require(claim["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(try JSON.parse(text)["box"] == "box-a")
        let bad = try await reply(rig, rpc("tools/call", params: ["name": "browser_open", "arguments": ["url": 3]]))
        #expect(bad["error"] == nil && bad["result"]?["isError"] == true)
        #expect(try JSON.parse(try #require(bad["result"]?["content"]?.array?.first?["text"]?.string))["error"] == "invalid_argument")
        // tool desconhecida também é erro de ferramenta
        let unknown = try await reply(rig, rpc("tools/call", params: ["name": "nope"]))
        #expect(unknown["result"]?["isError"] == true)
    }

    @Test func malformedAndUnknownMessagesGetJSONRPCErrors() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        #expect(try await reply(rig, Data("not json".utf8))["error"]?["code"] == -32600)
        #expect(try await reply(rig, JSON.object(["jsonrpc": "1.0", "method": "ping", "id": 1]).data())["error"]?["code"] == -32600)
        #expect(try await reply(rig, rpc("ping", id: [1]))["error"]?["code"] == -32600)  // id inválido
        #expect(try await reply(rig, rpc("resources/list"))["error"]?["code"] == -32601)
        #expect(try await reply(rig, rpc("tools/call", params: ["arguments": [:]]))["error"]?["code"] == -32602)
        #expect(try await reply(rig, rpc("tools/call", params: ["name": "journal", "arguments": "x"]))["error"]?["code"] == -32602)
    }
}

/// `app.sock` real (UDS) com o serviço `mcp`: o mesmo caminho do helper `racky mcp`.
@Suite struct McpSocketTests {
    struct Home {
        let root: URL
        var socket: String { root.appendingPathComponent("app.sock").path }
        init() throws {
            root = URL(fileURLWithPath: "/tmp/abm-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Uma requisição como o helper faz: hello, identidade e a mensagem; devolve a resposta (ou `nil`).
    static func exchange(socket: String, identity: McpIdentity, message: Data) async throws -> Data? {
        let connection = try AppSockClient.connect(path: socket)
        defer { Task { await connection.close() } }
        let encoder = CtlCodec.encoder()
        try await connection.send(try encoder.encode(AppSockHello(service: .mcp)))
        try await connection.send(try encoder.encode(identity))
        try await connection.send(message)
        let hello = try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await connection.receive())
        #expect(hello.ok)
        do { return try await connection.receive() } catch AppSockError.closed { return nil }
    }

    @Test func mcpServiceRoutesByTheChildIdentityOverTheRealSocket() async throws {
        let rig = try await Rig.make(children: ["child-1", "child-2"])
        defer { rig.cleanup() }
        let home = try Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hub = AppSockHub(socketPath: home.socket, providers: [McpServiceProvider(server: rig.server, hub: rig.hub)])
        try await hub.start()
        defer { Task { await hub.stop() } }

        let one = McpIdentity(child: "child-1", capability: "cap-child-1")
        let two = McpIdentity(child: "child-2", capability: "cap-child-2")
        let claim = try #require(try await Self.exchange(socket: home.socket, identity: one, message: rpc("tools/call", params: ["name": "box_claim", "arguments": ["name": "box-a", "wait_s": 0]])))
        #expect(try JSON.parse(claim)["result"]?["isError"] == false)
        // o irmão (outra conexão, outra identidade) não opera o computador do primeiro
        let stolen = try #require(try await Self.exchange(socket: home.socket, identity: two, message: rpc("tools/call", params: ["name": "exec", "arguments": ["argv": ["id"]]])))
        let stolenText = try #require(try JSON.parse(stolen)["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(try JSON.parse(stolenText)["error"] == "not_claimed")
        // tools/list passa pelo socket
        let list = try #require(try await Self.exchange(socket: home.socket, identity: one, message: rpc("tools/list")))
        #expect(try JSON.parse(list)["result"]?["tools"]?.array?.count == ToolCatalog.all.count)
        // notificação: sem resposta (a conexão fecha)
        #expect(try await Self.exchange(socket: home.socket, identity: one, message: rpc("notifications/initialized", id: nil)) == nil)
    }

    @Test func wrongCapabilityOrUnknownChildIsRefusedBeforeAnyTool() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let home = try Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hub = AppSockHub(socketPath: home.socket, providers: [McpServiceProvider(server: rig.server, hub: rig.hub)])
        try await hub.start()
        defer { Task { await hub.stop() } }
        for identity in [McpIdentity(child: "child-1", capability: "wrong"), McpIdentity(child: "ghost", capability: "cap-child-1")] {
            let reply = try #require(try await Self.exchange(socket: home.socket, identity: identity, message: rpc("tools/call", params: ["name": "box_claim", "arguments": ["name": "box-a"]])))
            #expect(try JSON.parse(reply)["error"]?["code"] == -32001)
        }
        #expect(await rig.computer.owner == nil)  // nada foi executado
    }

    @Test func aLongHelpWaitDoesNotBlockOtherCallsOfTheSameChild() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let home = try Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hub = AppSockHub(socketPath: home.socket, providers: [McpServiceProvider(server: rig.server, hub: rig.hub)])
        try await hub.start()
        defer { Task { await hub.stop() } }
        let identity = McpIdentity(child: "child-1", capability: "cap-child-1")
        let request = try #require(await rig.call("help_request", ["kind": "captcha", "reason": "x"]).json["request_id"]?.string)

        let waiting = Task { try await Self.exchange(socket: home.socket, identity: identity, message: rpc("tools/call", params: ["name": "help_wait", "arguments": ["request_id": .string(request), "wait_s": 3]])) }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        let status = try #require(try await Self.exchange(socket: home.socket, identity: identity, message: rpc("tools/call", params: ["name": "box_status", "arguments": [:]])))
        #expect(started.duration(to: .now) < .seconds(1), "box_status waited behind help_wait")
        #expect(try JSON.parse(status)["result"]?["isError"] == false)
        try await rig.computer.resolveHelp(request, note: "done")
        let done = try #require(try await waiting.value)
        let text = try #require(try JSON.parse(done)["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(try JSON.parse(text)["status"] == "resolved")
    }
}

/// O helper REAL `racky mcp` como processo filho: é o que o Claude Code sobe por subagente.
@Suite(.tags(.integration)) struct McpHelperProcessTests {
    static func binary() -> URL {
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("racky")
        }
        return URL(fileURLWithPath: ".build/debug/racky")
    }

    /// Roda o helper, escreve `lines` no stdin, fecha o stdin e devolve as linhas do stdout.
    static func run(socket: String, child: String = "child-1", capability: String = "cap-child-1", lines: [String], timeout: Double = 30) async -> (status: Int32, lines: [String]) {
        await offPool {
            let process = Process()
            process.executableURL = binary()
            process.arguments = ["mcp", "--child", child, "--capability", capability]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "RACKY_APP_SOCK": socket, "RACKY_MCP_NO_LAUNCH": "1"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (-1, []) }
            for line in lines { try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        }
    }

    @Test func stdioInitializeListAndCallThroughTheRealHelper() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let home = try McpSocketTests.Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hub = AppSockHub(socketPath: home.socket, providers: [McpServiceProvider(server: rig.server, hub: rig.hub)])
        try await hub.start()
        defer { Task { await hub.stop() } }

        func line(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        // O helper atende cada linha numa tarefa própria (chamadas longas não bloqueiam as outras): chamadas DEPENDENTES vão em
        // execuções separadas, como um cliente MCP que espera a resposta antes da próxima.
        let first = await Self.run(socket: home.socket, lines: [
            line(rpc("initialize", id: 1, params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])),
            line(rpc("notifications/initialized", id: nil)),
            line(rpc("tools/list", id: 2)),
            line(rpc("tools/call", id: 3, params: ["name": "box_claim", "arguments": ["name": "box-a", "wait_s": 0]])),
        ])
        #expect(first.status == 0)
        let replies = try first.lines.map { try JSON.parse($0) }
        #expect(replies.count == 3, "the notification must not get a reply: \(first.lines.count) lines")  // initialize, list, claim
        let byID = Dictionary(uniqueKeysWithValues: replies.compactMap { r in r["id"]?.int.map { ($0, r) } })
        #expect(byID[1]?["result"]?["serverInfo"]?["name"] == "racky")
        #expect(byID[2]?["result"]?["tools"]?.array?.count == ToolCatalog.all.count)
        #expect(byID[3]?["result"]?["isError"] == false)
        let second = await Self.run(socket: home.socket, lines: [line(rpc("tools/call", id: 4, params: ["name": "journal", "arguments": ["kind": "DOING", "text": "from the helper"]]))])
        #expect(try JSON.parse(try #require(second.lines.first))["result"]?["isError"] == false)
        // a identidade veio da configuração do processo, e a ferramenta caiu no computador reivindicado por ele
        #expect(await rig.computer.owner == "child-1")
        #expect(ChainedLog.read(rig.computer.journal.file).first?["text"] == "from the helper")
    }

    @Test func wrongCapabilityComesBackAsAReadableJSONRPCError() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let home = try McpSocketTests.Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hub = AppSockHub(socketPath: home.socket, providers: [McpServiceProvider(server: rig.server, hub: rig.hub)])
        try await hub.start()
        defer { Task { await hub.stop() } }
        let result = await Self.run(socket: home.socket, capability: "forged", lines: [String(decoding: rpc("tools/list"), as: UTF8.self)])
        #expect(result.status == 0)
        let reply = try JSON.parse(try #require(result.lines.first))
        #expect(reply["error"]?["message"]?.string?.contains("unauthorized") == true)
    }

    /// O app aceita a chamada e morre antes de responder (reinício no meio de um `browser_wait`).
    struct DyingProvider: AppSockServiceProvider {
        let service = AppSockService.mcp
        func admit() -> CtlError? { nil }
        func makeHandler() -> AppSockServer.Handler {
            let frames = Counter()
            return { _ in await frames.next() >= 2 ? AppSockReply(close: true) : AppSockReply() }
        }
        actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
    }

    @Test func aCallCutByAnAppRestartAnswersWithARetryableErrorInsteadOfHangingForever() async throws {
        let home = try McpSocketTests.Home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hub = AppSockHub(socketPath: home.socket, providers: [DyingProvider()])
        try await hub.start()
        defer { Task { await hub.stop() } }
        let started = ContinuousClock.now
        let result = await Self.run(socket: home.socket, lines: [
            String(decoding: rpc("tools/call", id: 9, params: ["name": "browser_wait", "arguments": ["ms": 15000]]), as: UTF8.self)])
        #expect(started.duration(to: .now) < .seconds(10))
        let reply = try JSON.parse(try #require(result.lines.first, "sem resposta o Claude Code espera o id para sempre"))
        #expect(reply["id"] == 9 && reply["result"]?["isError"] == true)
        let text = try #require(reply["result"]?["content"]?.array?.first?["text"]?.string)
        let body = try JSON.parse(text)
        #expect(text.contains("restarted during this call") && body["retry_after_s"]?.int == 5)
    }

    @Test func withoutTheAppToolCallsGetAReadableAppUnavailableNotACrash() async throws {
        let socket = "/tmp/abm-none-\(UInt32.random(in: 0 ... 0xFFFFFF)).sock"
        let started = ContinuousClock.now
        let result = await Self.run(socket: socket, lines: [
            String(decoding: rpc("tools/call", id: 7, params: ["name": "box_status", "arguments": [:]]), as: UTF8.self),
            String(decoding: rpc("tools/list", id: 8), as: UTF8.self),
        ])
        #expect(result.status == 0)  // nunca sai com código de erro (AR-110)
        #expect(started.duration(to: .now) < .seconds(15))
        let replies = try result.lines.map { try JSON.parse($0) }
        let call = try #require(replies.first { $0["id"] == 7 })
        #expect(call["result"]?["isError"] == true)
        let text = try #require(call["result"]?["content"]?.array?.first?["text"]?.string)
        let error = try JSON.parse(text)
        #expect(error["error"] == "app_unavailable" && error["retry_after_s"] == 5 && error["message"]?.string?.contains("not running") == true)
        let list = try #require(replies.first { $0["id"] == 8 })
        #expect(list["error"]?["message"]?.string?.contains("not running") == true)
    }
}
