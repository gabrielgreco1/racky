import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

// BK-13 (OpenCode): plugin `tool.execute.before` na ferramenta `task` que chama `racky hook-guard`. Payload real em
// Tests/SpikeFixtures/BK-13/opencode-task-before.json.

private let helper = "/Applications/Racky.app/Contents/MacOS/racky"

private func parentBundle(_ mode: SubagentComputersMode?) throws -> OrchestrationBundle {
    var options = OrchestrationInjectionBuilder.Options()
    options.workerSlots = 1
    var bundle = try OrchestrationInjectionBuilder.make(
        parentID: "parent-aaaaaaaa", helperPath: helper, options: options, parentCapability: "cap-parent", workerCapability: { "cap-w\($0)" }, provider: .opencode)
    bundle.spawnGuardMode = mode
    return bundle
}

private func config(_ rendered: (environment: [String: String], files: [LaunchFile])) throws -> [String: Any] {
    let raw = try #require(rendered.environment[OpenCodeOrchestration.environmentName])
    return try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
}

/// Sobe a partir deste arquivo até achar `Tests/SpikeFixtures`.
private func evidenceURL(_ relative: String, file: String = #filePath) -> URL? {
    var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
    for _ in 0..<10 {
        let candidate = dir.appendingPathComponent("Tests/SpikeFixtures/\(relative)")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir.deleteLastPathComponent()
    }
    return nil
}

@Suite("BK-13 gatilho de spawn no OpenCode", .tags(.integration), .serialized) struct OpenCodeSpawnGuardTests {
    @Test(arguments: [SubagentComputersMode.ask, .full]) func pluginIsInjectedOnlyWhenTheModeIsOn(mode: SubagentComputersMode) throws {
        let injection = try parentBundle(mode).applied(to: nil)
        let guardConfig = try #require(injection.openCodeOrchestration?.spawnGuard)
        #expect(guardConfig == SpawnGuardConfig(child: "parent-aaaaaaaa", capability: "cap-parent", mode: mode))
        let rendered = try #require(injection.openCodeOrchestration).render(launchDirectory: LaunchSamples.launchDirectory)
        let cfg = try config(rendered)
        #expect(cfg["plugin"] as? [String] == ["file://\(LaunchSamples.launchDirectory.path)/spawn-guard.js"])
        let plugin = try #require(rendered.files.first { $0.name == "spawn-guard.js" })
        let source = String(decoding: plugin.contents, as: UTF8.self)
        #expect(plugin.posixMode == 0o600 && source.contains("\"hook-guard\",\"--child\",\"parent-aaaaaaaa\",\"--capability\",\"cap-parent\",\"--mode\",\"\(mode.rawValue)\""))
        #expect(source.contains("\"tool.execute.before\"") && source.contains("input.tool !== \"task\"") && !source.contains("fetch(") && !source.contains("http"))
        // O plano de lançamento leva o plugin como arquivo do diretório do lançamento; argv continua vazio.
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .opencode), capabilities: LaunchSamples.helpCapabilities(.opencode), slice: .slice2, injection: injection)
        #expect(plan.files.map(\.name) == ["orchestration.md", "spawn-guard.js"] && plan.argv.injected.isEmpty)
    }

    @Test func noPluginWithoutAMode() throws {
        for mode in [nil, SubagentComputersMode.off] {
            let injection = try parentBundle(mode).applied(to: nil)
            #expect(injection.openCodeOrchestration?.spawnGuard == nil)
            let rendered = try #require(injection.openCodeOrchestration).render(launchDirectory: LaunchSamples.launchDirectory)
            #expect(try config(rendered)["plugin"] == nil && rendered.files.map(\.name) == ["orchestration.md"])
        }
    }

    @Test func fixtureIsTheRealPayloadTheGuardUnderstands() throws {
        let url = try #require(evidenceURL("BK-13/opencode-task-before.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((object["input"] as? [String: Any])?["tool"] as? String == OpenCodeSpawnGuardPlugin.toolName)
        let args = try #require((object["output"] as? [String: Any])?["args"] as? [String: Any])
        // Os campos do `output.args` são os que o guard lê (`subagent_type`, `prompt`, `description`).
        let input = SubagentSpawnGuard.Input(toolInput: args)
        #expect(input.subagentType == "general" && SubagentSpawnGuard.decide(mode: .full, input) == .block(reason: SubagentSpawnGuard.blockReason))
        #expect(SubagentSpawnGuard.toolNames.contains("Task"))
    }

    /// Roda o plugin gerado no Node contra um helper falso: o `deny` do helper vira `throw` e o payload chega no formato do Claude.
    @Test func generatedPluginBlocksOnDenyAndFailsOpenOtherwise() throws {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.local/bin/node"].first(where: FileManager.default.isExecutableFile) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let received = dir.appendingPathComponent("stdin.json").path
        let fake = dir.appendingPathComponent("fake-helper.sh")
        try "#!/bin/sh\ncat > '\(received)'\necho \"$@\" > '\(received).args'\ncat '\(dir.path)/reply.json'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let source = OpenCodeSpawnGuardPlugin.source(helperPath: fake.path, config: SpawnGuardConfig(child: "p", capability: "c", mode: .full))
        try source.write(to: dir.appendingPathComponent("plugin.mjs"), atomically: true, encoding: .utf8)
        let driver = """
            import plugin from "./plugin.mjs"
            const hooks = await plugin({})
            const run = async (tool, args) => { try { await hooks["tool.execute.before"]({ tool }, { args }); return "ok" } catch (e) { return "blocked:" + e.message } }
            const web = { subagent_type: "general", description: "Study site", prompt: "Study http://example.com/" }
            console.log(JSON.stringify([await run("task", web), await run("bash", web)]))
            """
        try driver.write(to: dir.appendingPathComponent("driver.mjs"), atomically: true, encoding: .utf8)
        func run() throws -> [String] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: node); process.arguments = [dir.appendingPathComponent("driver.mjs").path]; process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String])
        }
        try Data(SubagentSpawnGuard.denyOutput(reason: "reserve a computer").utf8).write(to: dir.appendingPathComponent("reply.json"))
        #expect(try run() == ["blocked:reserve a computer", "ok"], "only the task tool is guarded; deny becomes a throw with the reason")
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: received))) as? [String: Any])
        #expect(sent["tool_name"] as? String == "Task" && (sent["tool_input"] as? [String: String])?["subagent_type"] == "general")
        #expect(try String(contentsOfFile: received + ".args", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "hook-guard --child p --capability c --mode full")
        try Data("{}".utf8).write(to: dir.appendingPathComponent("reply.json"))
        #expect(try run() == ["ok", "ok"])
        try Data("not json".utf8).write(to: dir.appendingPathComponent("reply.json"))
        #expect(try run() == ["ok", "ok"], "unreadable helper output fails open")
    }
}
