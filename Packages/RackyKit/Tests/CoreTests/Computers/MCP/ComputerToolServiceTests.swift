import RackyDocker
import Foundation
import Testing

@testable import RackyCore

@Suite struct RoutingTests {
    @Test func aChildOnlyOperatesTheComputerItClaimed() async throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let hub = ComputerHub()
        var computers: [ManagedComputer] = []
        for name in ["phoenix", "austin"] {
            let run = RunFolder(root: temp.root.appendingPathComponent(name))
            let computer = try ManagedComputer(name: name, display: .headless, run: run, backend: FakeBackend())
            await hub.register(computer)
            computers.append(computer)
        }
        for child in ["child-a", "child-b"] { await hub.registerChild(id: child, capability: "cap") }
        let service = ComputerToolService(hub: hub)
        func call(_ tool: String, _ args: JSON, _ child: String) async -> ToolOutcome { await service.call(tool, arguments: args, child: child) }

        // não reivindicou: not_claimed
        let early = await call("journal", ["kind": "NOTE", "text": "x"], "child-a")
        let earlyJSON = try JSON.parse(early.content[0]["text"]?.string ?? "")
        #expect(early.isError)
        #expect(earlyJSON["error"] == "not_claimed")

        #expect(!(await call("box_claim", ["name": "phoenix", "wait_s": 0], "child-a")).isError)
        #expect(!(await call("box_claim", ["name": "austin", "wait_s": 0], "child-b")).isError)

        // CA-205: 200 chamadas intercaladas, cada uma cai no computador certo
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { _ = await call("journal", ["kind": "NOTE", "text": .string("a\(i)")], "child-a") }
                group.addTask { _ = await call("journal", ["kind": "NOTE", "text": .string("b\(i)")], "child-b") }
            }
        }
        let phoenix = ChainedLog.read(computers[0].journal.file), austin = ChainedLog.read(computers[1].journal.file)
        #expect(phoenix.count == 100 && austin.count == 100)
        #expect(phoenix.allSatisfy { $0["text"]?.string?.hasPrefix("a") == true })
        #expect(austin.allSatisfy { $0["text"]?.string?.hasPrefix("b") == true })
    }

    @Test func takeOverOnOneComputerDoesNotPauseTheOther() async throws {
        // AC-411: Phoenix e Austin trabalhando; Take Over em Phoenix recusa as escritas dela com human_in_control e Austin segue
        let temp = try TempRun()
        defer { temp.remove() }
        let hub = ComputerHub()
        var computers: [String: ManagedComputer] = [:]
        for name in ["phoenix", "austin"] {
            let computer = try ManagedComputer(name: name, display: .headless, run: RunFolder(root: temp.root.appendingPathComponent(name)), backend: FakeBackend())
            await hub.register(computer)
            computers[name] = computer
        }
        for child in ["child-p", "child-a"] { await hub.registerChild(id: child, capability: "c") }
        let service = ComputerToolService(hub: hub)
        _ = await service.call("box_claim", arguments: ["name": "phoenix", "wait_s": 0], child: "child-p")
        _ = await service.call("box_claim", arguments: ["name": "austin", "wait_s": 0], child: "child-a")
        await computers["phoenix"]?.takeOver()
        for _ in 0..<5 {
            let p = await service.call("browser_click", arguments: ["selector": "#a"], child: "child-p")
            let a = await service.call("browser_click", arguments: ["selector": "#a"], child: "child-a")
            let pJSON = try JSON.parse(p.content[0]["text"]?.string ?? "")
            #expect(p.isError)
            #expect(pJSON["error"] == "human_in_control")
            #expect(!a.isError)
        }
        // leituras e ferramentas que não tocam o computador seguem em Phoenix
        #expect(!(await service.call("browser_read", arguments: ["what": "text"], child: "child-p")).isError)
        #expect(!(await service.call("journal", arguments: ["kind": "NOTE", "text": "x"], child: "child-p")).isError)
    }

    @Test func secondClaimGetsAlreadyClaimedWithTheOwner() async throws {
        let rig = try await Rig.make(children: ["child-1", "child-2"])
        defer { rig.cleanup() }
        await rig.claim(child: "child-1")
        let second = await rig.call("box_claim", ["name": "box-a", "wait_s": 0], child: "child-2")
        #expect(errorCode(second) == "already_claimed")
        #expect(second.json["details"]?["owner"] == "child-1")
        // o dono pode repetir (idempotente)
        #expect(await rig.call("box_claim", ["name": "box-a", "wait_s": 0], child: "child-1").isError == false)
        // o irmão não consegue operar o computador do outro
        #expect(errorCode(await rig.call("exec", ["argv": ["id"]], child: "child-2")) == "not_claimed")
    }

    @Test func claimReturnsTheWorkPathsAndAllowedProxies() async throws {
        let rig = try await Rig.make(proxiesAllowed: ["zyte-us"])
        defer { rig.cleanup() }
        let result = await rig.call("box_claim", ["name": "box-a", "wait_s": 0])
        #expect(result.json["state"] == "in_use" || result.json["state"] == "ready")
        #expect(result.json["work_path_box"] == "/work")
        #expect(result.json["work_path_host"]?.string == rig.computer.run.work.path)
        #expect(result.json["proxies_allowed"] == ["zyte-us"])
        #expect(result.json["proxy"] == "direct")
        #expect(result.json["display"] == "headless")
        #expect(result.json["took_ms"]?.int != nil)
        #expect(result.json["box"] == "box-a")
    }

    @Test func claimWaitsForReadyAndReportsQueuedWhenItIsNot() async throws {
        let rig = try await Rig.make(state: .queued)
        defer { rig.cleanup() }
        await rig.computer.setState(.queued, position: 2)
        let started = ContinuousClock.now
        let queued = await rig.call("box_claim", ["name": "box-a", "wait_s": 0.3])
        #expect(queued.json["state"] == "queued" && queued.json["position"] == 2)
        #expect(started.duration(to: .now) >= .milliseconds(250))
        // ferramentas de computador respondem `queued` enquanto não está pronto
        #expect(errorCode(await rig.call("exec", ["argv": ["id"]])) == "queued")
        Task { try? await Task.sleep(for: .milliseconds(200)); await rig.computer.setState(.ready) }
        let ready = await rig.call("box_claim", ["name": "box-a", "wait_s": 5])
        #expect(ready.json["state"] == "in_use")
    }

    @Test func releaseThenUseGivesBoxReleasedAndUnknownComputerIsNotFound() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        #expect(errorCode(await rig.call("box_claim", ["name": "ghost", "wait_s": 0])) == "not_found")
        await rig.claim()
        #expect(await rig.call("box_release").json["released"] == true)
        #expect(errorCode(await rig.call("journal", ["kind": "NOTE", "text": "late"])) == "box_released")
        await rig.claim()  // reivindicar de novo volta a funcionar
        #expect(!(await rig.call("journal", ["kind": "NOTE", "text": "again"])).isError)
    }

    @Test func unregisteredChildIsNotAuthorizedAndCapabilityMustMatch() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        #expect(await rig.hub.authorize(child: "child-1", capability: "cap-child-1"))
        #expect(!(await rig.hub.authorize(child: "child-1", capability: "cap-child-2")))
        #expect(!(await rig.hub.authorize(child: "stranger", capability: "cap-child-1")))
        await rig.hub.unregisterChild(id: "child-1")
        #expect(!(await rig.hub.authorize(child: "child-1", capability: "cap-child-1")))
    }
}

@Suite struct HelpTests {
    @Test func helpIsIdempotentWaitsRepeatAndResolveDeliversTheNote() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let events = EventBox()
        await rig.computer.setObserver { events.add($0) }

        let first = await rig.call("help_request", ["kind": "captcha", "reason": "Cloudflare challenge", "url": "http://x/login"])
        let id = try #require(first.json["request_id"]?.string)
        #expect(first.json["status"] == "open")
        // CA-202: repetir help_request com o mesmo kind + url devolve o mesmo id; help_wait 6 vezes não duplica nada
        for _ in 0..<3 { #expect(await rig.call("help_request", ["kind": "captcha", "reason": "again", "url": "http://x/login"]).json["request_id"]?.string == id) }
        for _ in 0..<6 { #expect(await rig.call("help_wait", ["request_id": .string(id), "wait_s": 0]).json["status"] == "open") }
        #expect(events.helpRequested == 1)
        #expect(ChainedLog.read(rig.computer.helpLog.file).filter { $0["event"]?.string == "requested" }.count == 1)
        // outro kind/url é outro pedido
        #expect(await rig.call("help_request", ["kind": "login", "reason": "x", "url": "http://x/login"]).json["request_id"]?.string != id)

        // enquanto aberto: escritas pausadas (waiting_help); leituras e ferramentas que não tocam o computador seguem
        #expect(errorCode(await rig.call("browser_click", ["selector": "#a"])) == "waiting_help")
        #expect(errorCode(await rig.call("browser_open", ["url": "http://x/"])) == "waiting_help")
        #expect(!(await rig.call("browser_read", ["what": "text"])).isError)
        #expect(!(await rig.call("journal", ["kind": "NOTE", "text": "waiting"])).isError)
        #expect(!(await rig.call("reqlog_query")).isError)
        #expect(!(await rig.call("exec", ["argv": ["id"]])).isError)
        #expect(await rig.call("box_status").json["help_open"]?.string != nil)

        // o humano resolve; o próximo help_wait devolve resolved com a nota e o estado reconciliado
        await rig.backend.setRuntime("status", ["ready": true, "url": "http://x/after", "title": "After"])
        try await rig.computer.resolveHelp(id, note: "solved the captcha", choice: nil)
        let done = await rig.call("help_wait", ["request_id": .string(id), "wait_s": 1])
        #expect(done.json["status"] == "resolved")
        #expect(done.json["human_note"] == "solved the captcha")
        #expect(done.json["state"]?["url"] == "http://x/after")
        #expect(done.json["state"]?["cookies_changed"]?.bool != nil)
        #expect(events.resolved == 1)
    }

    @Test func helpWaitLongPollsAndNeverExceedsTheCap() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let id = try #require(await rig.call("help_request", ["kind": "mfa", "reason": "code"]).json["request_id"]?.string)
        let started = ContinuousClock.now
        Task { try? await Task.sleep(for: .milliseconds(300)); try? await rig.computer.resolveHelp(id, note: "123456") }
        let result = await rig.call("help_wait", ["request_id": .string(id), "wait_s": 10])
        #expect(result.json["status"] == "resolved")
        #expect(started.duration(to: .now) < .seconds(5))  // acordou na resolução, não no fim da espera
        // o schema recusa > 50 s (nenhuma ferramenta bloqueia mais que isso)
        #expect(errorCode(await rig.call("help_wait", ["request_id": .string(id), "wait_s": 51])) == "invalid_argument")
        #expect(errorCode(await rig.call("help_wait", ["request_id": "nope", "wait_s": 0])) == "not_found")
    }

    @Test func takeOverPausesWritesUntilHandBack() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.computer.takeOver()
        #expect(errorCode(await rig.call("browser_click", ["x": 1, "y": 2])) == "human_in_control")
        #expect(await rig.call("box_status").json["lease"] == "human")
        await rig.computer.handBack()
        #expect(!(await rig.call("browser_click", ["x": 1, "y": 2])).isError)
    }

    @Test func cancelClosesTheRequestAndLiftsThePause() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let id = try #require(await rig.call("help_request", ["kind": "choice", "reason": "pick", "options": ["a", "b"]]).json["request_id"]?.string)
        #expect(await rig.call("help_cancel", ["request_id": .string(id)]).json["status"] == "cancelled")
        #expect(!(await rig.call("browser_click", ["selector": "#a"])).isError)
        #expect(await rig.call("help_wait", ["request_id": .string(id), "wait_s": 0]).json["status"] == "cancelled")
    }
}

final class EventBox: @unchecked Sendable {  // SAFETY: teste; NSLock protege o contador.
    private let lock = NSLock()
    private var requested = 0, resolvedCount = 0
    var helpRequested: Int { lock.lock(); defer { lock.unlock() }; return requested }
    var resolved: Int { lock.lock(); defer { lock.unlock() }; return resolvedCount }
    func add(_ event: ComputerEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .helpRequested = event { requested += 1 }
        if case .helpResolved = event { resolvedCount += 1 }
    }
}

@Suite struct ExecToolTests {
    @Test func execRunsInTheWorkContainerWithStdinAndLogsTheCommand() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setExec { request in
            BackendExecOutcome(exitCode: 3, stdout: request.stdin ?? Data(), stderr: Data("boom".utf8), durationMs: 12)
        }
        let result = await rig.call("exec", ["argv": ["cat"], "stdin": "hello", "cwd": "sub/dir", "env": ["FOO": "bar"], "secret_env": ["API_KEY"]])
        #expect(!result.isError, "\(result.json.text)")
        #expect(result.json["exit_code"] == 3 && result.json["stdout_tail"] == "hello" && result.json["stderr_tail"] == "boom")
        #expect(result.json["log_id"] == "0001")
        let sent = try #require(await rig.backend.execs.last)
        #expect(sent.cwd == "/work/sub/dir" && sent.stdin == Data("hello".utf8) && sent.env == ["FOO": "bar"] && sent.secretEnv == ["API_KEY"])

        // log de comandos escrito pelo app, fora do alcance do agente
        let entries = ChainedLog.read(rig.computer.commands.file)
        #expect(entries.count == 1 && entries[0]["exit"] == 3 && entries[0]["argv"] == ["cat"])
        #expect(entries[0]["secret_env"] == ["API_KEY"])  // só o NOME
        let fullLog = try String(contentsOf: rig.computer.run.commandsDirectory.appendingPathComponent("0001.log"), encoding: .utf8)
        #expect(fullLog.contains("hello") && fullLog.contains("boom"))
        #expect(try ReqlogIntegrity.verify(file: rig.computer.commands.file) == .ok(lines: 1))
        // a pasta de logs não é a pasta `work`
        #expect(!rig.computer.run.logs.path.hasPrefix(rig.computer.run.work.path))
    }

    @Test func execRejectsBadPathsNamesAndShape() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "cwd": "../../etc"])) == "path_rejected")
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "cwd": "/etc"])) == "path_rejected")
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "env": ["BAD NAME": "x"]])) == "invalid_argument")
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "secret_env": ["a;rm -rf /"]])) == "invalid_argument")
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "shell": "ls"])) == "invalid_argument")
        #expect(errorCode(await rig.call("exec", ["timeout_s": 5])) == "invalid_argument")
        #expect(errorCode(await rig.call("exec", ["shell": "ls", "timeout_s": 600])) == "invalid_argument")
        // cwd com symlink criado pelo agente em /work
        try FileManager.default.createSymbolicLink(at: rig.computer.run.work.appendingPathComponent("evil"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "cwd": "evil"])) == "path_rejected")
        #expect(await rig.backend.execs.isEmpty)
    }

    @Test func timeoutReturnsThePartialOutputAndALogId() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setExec { _ in BackendExecOutcome(exitCode: nil, stdout: Data("partial".utf8), timedOut: true, durationMs: 2000) }
        let result = await rig.call("exec", ["shell": "sleep 100", "timeout_s": 2])
        #expect(errorCode(result) == "timeout")
        #expect(result.json["details"]?["stdout_tail"] == "partial")
        #expect(result.json["details"]?["log_id"] == "0001")
        #expect(ChainedLog.read(rig.computer.commands.file)[0]["timed_out"] == true)
    }

    @Test func tailKeepsTheEndAndMarksTruncation() {
        let big = Data(String(repeating: "x", count: 40_000).utf8) + Data("END".utf8)
        let tail = ComputerToolService.tail(big)
        #expect(tail.truncated && tail.text.hasSuffix("END") && tail.text.utf8.count <= ComputerToolService.tailLimit)
        let utf8 = Data(String(repeating: "é", count: 20_000).utf8)  // 2 bytes por caractere: não corta no meio
        let cut = ComputerToolService.tail(utf8, limit: 1001)
        #expect(!cut.text.contains("\u{FFFD}"))
        #expect(!ComputerToolService.tail(Data("short".utf8)).truncated)
    }

    @Test func execStartPollCancelFlowAndCommandLogging() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let started = await rig.call("exec_start", ["shell": "sleep 600"])
        let job = try #require(started.json["job_id"]?.string)
        #expect(started.json["log_id"] == "0001")
        let running = await rig.call("exec_poll", ["job_id": .string(job), "wait_s": 0])
        #expect(running.json["running"] == true)
        #expect(ChainedLog.read(rig.computer.commands.file).isEmpty)  // ainda não terminou
        let cancelled = await rig.call("exec_cancel", ["job_id": .string(job)])
        #expect(cancelled.json["cancelled"] == true && cancelled.json["exit_code"] == 143)
        // CA-204: commands.jsonl registra o exit 143/137
        let entries = ChainedLog.read(rig.computer.commands.file)
        #expect(entries.count == 1 && entries[0]["exit"] == 143 && entries[0]["tool"] == "exec_start")
        #expect(errorCode(await rig.call("exec_poll", ["job_id": "job-999", "wait_s": 0])) == "not_found")
    }

    @Test func jobsFinishedAndNeverPolledAreLoggedOnRelease() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let job = try #require(await rig.call("exec_start", ["argv": ["true"]]).json["job_id"]?.string)
        await rig.backend.setJob(job, BackendExecOutcome(running: false, exitCode: 0, stdout: Data("done".utf8)))
        _ = await rig.call("box_release")
        let entries = ChainedLog.read(rig.computer.commands.file)
        #expect(entries.count == 1 && entries[0]["exit"] == 0)
    }

    @Test func secretCommandWrapperReadsFilesAndNeverPutsValuesInArgv() {
        let command = DockerComputerBackend.command(for: BackendExec(argv: ["curl", "-s", "x"], secretEnv: ["TOKEN_A", "TOKEN_B"]))
        #expect(command[0] == "/bin/sh" && command[1] == "-c")
        #expect(command[2].contains("/run/abx-secrets/") && command[2].contains("exec \"$@\""))
        #expect(command[4] == "TOKEN_A TOKEN_B" && Array(command.suffix(3)) == ["curl", "-s", "x"])
        #expect(DockerComputerBackend.command(for: BackendExec(shell: "echo hi")) == ["bash", "-lc", "echo hi"])
        #expect(DockerComputerBackend.command(for: BackendExec(argv: ["ls", "-l"])) == ["ls", "-l"])
    }
}

@Suite struct HTTPToolTests {
    static let okResult: JSON = [
        "status": 200, "headers": [["Content-Type", "application/json"], ["Set-Cookie", "a=1"], ["Set-Cookie", "b=2"]],
        "final_url": "http://site.test/api", "body_b64": .string(Data(#"{"ok":true}"#.utf8).base64EncodedString()), "truncated": false, "elapsed_ms": 9,
    ]

    func stdout(_ json: JSON) -> BackendExecOutcome { BackendExecOutcome(exitCode: 0, stdout: json.data(), durationMs: 9) }

    @Test func requestRunsAbxHttpAndIsRecordedAsObservedByTheApp() async throws {
        let rig = try await Rig.make(proxiesAllowed: ["zyte-us"])
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setExec { [okResult = Self.okResult] _ in BackendExecOutcome(exitCode: 0, stdout: okResult.data()) }
        let result = await rig.call("http_request", [
            "method": "post", "url": "http://site.test/api?x=1", "headers": ["X-Test": "1"], "json": ["a": 1], "impersonate": "chrome",
            "follow_redirects": false,
        ])
        #expect(!result.isError, "\(result.json.text)")
        #expect(result.json["status"] == 200 && result.json["final_url"] == "http://site.test/api")
        #expect(result.json["body_inline"] == #"{"ok":true}"#)
        #expect(result.json["headers"]?["Set-Cookie"] == "a=1, b=2")  // repetidos juntos
        #expect(result.json["via"] == "direct")

        // o `work` recebeu o spec pelo stdin, sem credencial nem token
        let sent = try #require(await rig.backend.execs.last)
        #expect(sent.argv == ["abx-http"])
        let spec = try JSON.parse(try #require(sent.stdin))
        #expect(spec["method"] == "POST" && spec["impersonate"] == "chrome" && spec["follow_redirects"] == false && spec["json"] == ["a": 1])
        #expect(spec["headers"]?["X-Test"] == "1")

        // o app grava o registro `observed` pelo egress: source work:python, com o corpo e o id devolvido
        let payload = try #require(await rig.backend.ingested.last)
        #expect(payload["record"]?["source"] == "work:python" && payload["record"]?["method"] == "POST" && payload["record"]?["status"] == 200)
        #expect(payload["record"]?["impersonate"] == "chrome")
        #expect(payload["request_body"] == #"{"a":1}"#)
        #expect(payload["response_body"] == #"{"ok":true}"#)
        #expect(payload["record"]?["id"] == result.json["request_id"])
    }

    @Test func bodyJsonFormAreMutuallyExclusiveAndUrlMustBeHttp() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        #expect(errorCode(await rig.call("http_request", ["method": "POST", "url": "http://x/", "body": "a", "json": 1])) == "invalid_argument")
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "file:///etc/passwd"])) == "invalid_argument")
        #expect(errorCode(await rig.call("http_request", ["method": "G E T", "url": "http://x/"])) == "invalid_argument")
        #expect(await rig.backend.execs.isEmpty)
    }

    @Test func inlineBodyIsCappedAndSaveBodyAsWritesInsideWorkOnly() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let big = String(repeating: "A", count: 500)
        let result: JSON = ["status": 200, "headers": [], "final_url": "http://s/", "body_b64": .string(Data(big.utf8).base64EncodedString()), "truncated": false]
        await rig.backend.setExec { _ in BackendExecOutcome(exitCode: 0, stdout: result.data()) }
        let ok = await rig.call("http_request", ["method": "GET", "url": "http://s/", "max_inline_chars": 100, "save_body_as": "dl/body.txt"])
        #expect(ok.json["body_inline"]?.string?.count == 100 && ok.json["truncated"] == true)
        #expect(ok.json["body_file"] == "/work/dl/body.txt")
        #expect(try Data(contentsOf: rig.computer.run.work.appendingPathComponent("dl/body.txt")).count == 500)
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://s/", "save_body_as": "../x"])) == "path_rejected")
        try FileManager.default.createSymbolicLink(at: rig.computer.run.work.appendingPathComponent("a"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://s/", "save_body_as": "a"])) == "path_rejected")
    }

    @Test func transportFailureBecomesBlockedByPolicyWhenTheEgressRefusedTheDestination() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let failure = JSON.object(["error": "request_failed", "message": "CONNECT tunnel failed, response 403"]).data()
        await rig.backend.setExec { _ in BackendExecOutcome(exitCode: 0, stdout: failure) }
        // sem registro de bloqueio no egress: é erro de proxy/transporte
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://169.254.169.254/latest"])) == "proxy_error")
        // o egress grava o bloqueio durante a chamada
        let file = rig.temp.folder.requestsFile
        await rig.backend.setExec { _ in
            appendRequestRecord(file, ["id": .string(ULID.generate()), "source": "egress", "kind": "http", "host": "169.254.169.254", "blocked": true, "blocked_reason": "link-local", "method": "GET"])
            return BackendExecOutcome(exitCode: 0, stdout: failure)
        }
        let blocked = await rig.call("http_request", ["method": "GET", "url": "http://169.254.169.254/latest"])
        #expect(errorCode(blocked) == "blocked_by_policy")
        #expect(blocked.json["details"]?["reason"] == "link-local")
        // um bloqueio ANTERIOR à chamada não conta para outra chamada
        await rig.backend.setExec { _ in BackendExecOutcome(exitCode: 0, stdout: failure) }
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://169.254.169.254/again"])) == "proxy_error")
        // timeout do curl
        let timeout = JSON.object(["error": "timeout", "message": "timed out"]).data()
        await rig.backend.setExec { _ in BackendExecOutcome(exitCode: 0, stdout: timeout) }
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://slow.test/"])) == "timeout")
    }

    @Test func plain403ThatTheEgressBlockedIsPolicyButASiteThatSays403IsNot() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let forbidden = JSON.object(["status": 403, "headers": [], "final_url": "http://site.test/", "body_b64": "", "truncated": false]).data()
        await rig.backend.setExec { _ in BackendExecOutcome(exitCode: 0, stdout: forbidden) }
        let site = await rig.call("http_request", ["method": "GET", "url": "http://site.test/"])
        #expect(!site.isError && site.json["status"] == 403)
        let file = rig.temp.folder.requestsFile
        await rig.backend.setExec { _ in
            appendRequestRecord(file, ["id": .string(ULID.generate()), "source": "egress", "host": "10.0.0.5", "blocked": true, "blocked_reason": "rfc1918"])
            return BackendExecOutcome(exitCode: 0, stdout: forbidden)
        }
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://10.0.0.5/"])) == "blocked_by_policy")
    }

    @Test func cookiesFromTheBrowserAreFilteredByHost() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("cookies", ["cookies": [
            ["name": "sid", "value": "1", "domain": "site.test"], ["name": "dot", "value": "2", "domain": ".site.test"],
            ["name": "other", "value": "3", "domain": "evil.test"], ["name": "sub", "value": "4", "domain": "x.site.test"],
        ]])
        await rig.backend.setExec { [okResult = Self.okResult] _ in BackendExecOutcome(exitCode: 0, stdout: okResult.data()) }
        _ = await rig.call("http_request", ["method": "GET", "url": "http://app.site.test/", "cookies_from_browser": true])
        let spec = try JSON.parse(try #require(await rig.backend.execs.last?.stdin))
        let names = (spec["cookies"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
        #expect(names == ["dot", "sid"])
    }
}

@Suite struct ReqlogToolTests {
    func seed(_ rig: Rig) throws -> (a: String, b: String, c: String, d: String) {
        let ids = (0..<4).map { ULID.generate(nowMs: UInt64(1_700_000_000_000 + $0)) }
        try rig.seedRequests([
            ["id": .string(ids[0]), "ts": 1.0, "source": "browser", "trust": "observed", "via": "direct", "method": "GET", "url": "http://a.test/page", "host": "a.test",
             "status": 200, "content_type": "text/html", "response_body_file": .string("bodies/\(ids[0]).response.txt")],
            ["id": .string(ids[1]), "ts": 2.0, "source": "browser", "trust": "observed", "via": "direct", "method": "GET", "url": "http://a.test/api/items", "host": "a.test",
             "status": 200, "content_type": "application/json", "response_body_file": .string("bodies/\(ids[1]).response.txt")],
            ["id": .string(ids[2]), "ts": 3.0, "source": "work:python", "trust": "observed", "via": "zyte-us", "method": "POST", "url": "http://b.test/search", "host": "b.test",
             "status": 500, "content_type": "application/json", "request_headers": [["Content-Type", "application/json"], ["Authorization", "[redacted]"], ["X-Test", "1"]],
             "request_body_file": .string("bodies/\(ids[2]).request.txt")],
            ["id": .string(ids[3]), "ts": 4.0, "source": "egress", "trust": "observed", "via": "direct", "kind": "http", "method": "GET", "url": "http://10.0.0.1/", "host": "10.0.0.1",
             "blocked": true, "blocked_reason": "rfc1918", "error": "blocked: rfc1918"],
        ])
        try rig.seedBody(id: ids[0], kind: "response", text: "<html>hello listings</html>")
        try rig.seedBody(id: ids[1], kind: "response", text: #"{"items":[1,2,3],"secret":"needle-123"}"#)
        try rig.seedBody(id: ids[2], kind: "request", text: #"{"q":"phoenix"}"#)
        return (ids[0], ids[1], ids[2], ids[3])
    }

    func ids(_ result: (isError: Bool, json: JSON, outcome: ToolOutcome)) -> [String] { (result.json["records"]?.array ?? []).compactMap { $0["id"]?.string } }

    @Test func queryFiltersLikeTheOldReqlog() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let s = try seed(rig)
        #expect(ids(await rig.call("reqlog_query")) == [s.a, s.b, s.c, s.d])
        #expect(ids(await rig.call("reqlog_query", ["xhr": true])) == [s.b, s.c])  // JSON/XML ou método ≠ GET
        #expect(ids(await rig.call("reqlog_query", ["errors": true])) == [s.c, s.d])  // 5xx e bloqueado
        #expect(ids(await rig.call("reqlog_query", ["source": "browser"])) == [s.a, s.b])
        #expect(ids(await rig.call("reqlog_query", ["source": "work"])) == [s.c])
        #expect(ids(await rig.call("reqlog_query", ["source": "egress"])) == [s.d])
        #expect(ids(await rig.call("reqlog_query", ["grep": "needle-123"])) == [s.b])  // casa o CORPO salvo
        #expect(ids(await rig.call("reqlog_query", ["grep": "PHOENIX"])) == [s.c])  // corpo da requisição, sem caixa
        #expect(ids(await rig.call("reqlog_query", ["host": "a.test"])) == [s.a, s.b])
        #expect(ids(await rig.call("reqlog_query", ["method": "post"])) == [s.c])
        #expect(ids(await rig.call("reqlog_query", ["status": "5xx"])) == [s.c])
        #expect(ids(await rig.call("reqlog_query", ["status": "200"])) == [s.a, s.b])
        #expect(ids(await rig.call("reqlog_query", ["since_id": .string(s.b)])) == [s.c, s.d])
        let last = await rig.call("reqlog_query", ["last": 2])
        #expect(ids(last) == [s.c, s.d] && last.json["total"] == 4)
        let row = try #require((await rig.call("reqlog_query", ["source": "work"])).json["records"]?.array?.first)
        #expect(row["req_body_snippet"] == #"{"q":"phoenix"}"# && row["via"] == "zyte-us" && row["trust"] == "observed")
        let blocked = try #require((await rig.call("reqlog_query", ["source": "egress"])).json["records"]?.array?.first)
        #expect(blocked["blocked"] == "rfc1918" && blocked["error"] != nil)
    }

    @Test func getReturnsRecordAndPagedBodyAndIsConfinedToThisComputer() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let s = try seed(rig)
        let whole = await rig.call("reqlog_get", ["id": .string(s.b)])
        #expect(whole.json["body"]?.string?.contains("needle-123") == true && whole.json["body_truncated"] == false)
        #expect(whole.json["record"]?["prev_sha256"] == nil)
        let page = await rig.call("reqlog_get", ["id": .string(s.b), "body_offset": 2, "body_max": 5])
        #expect(page.json["body"] == "items" && page.json["body_truncated"] == true && page.json["next_offset"] == 7)
        #expect(await rig.call("reqlog_get", ["id": .string(s.c)]).json["record"]?["request_body"] == #"{"q":"phoenix"}"#)
        #expect(await rig.call("reqlog_get", ["id": .string(s.a), "include_body": false]).json["body"] == nil)
        #expect(errorCode(await rig.call("reqlog_get", ["id": .string(ULID.generate())])) == "not_found")
        // um body_file malicioso no registro nunca sai de logs/bodies
        try rig.seedRequests([["id": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "response_body_file": "bodies/../journal.jsonl"]])
        #expect(await rig.call("reqlog_get", ["id": "01ARZ3NDEKTSV4RRFFQ69G5FAV"]).json["body"] == nil)
    }

    @Test func asCurlDropsRedactedHeadersAndEmitsBothSnippets() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let s = try seed(rig)
        let result = await rig.call("reqlog_as_curl", ["id": .string(s.c), "impersonate": true])
        let curl = try #require(result.json["curl"]?.string), python = try #require(result.json["python_curl_cffi"]?.string)
        #expect(curl.contains("curl -sS -X POST 'http://b.test/search'") && curl.contains("-H 'X-Test: 1'") && curl.contains(#"--data-raw '{"q":"phoenix"}'"#))
        #expect(!curl.contains("Authorization") && !curl.contains("[redacted]"))
        #expect(curl.contains("curl-impersonate"))
        #expect(python.contains("from curl_cffi import requests") && python.contains("impersonate=\"chrome\"") && python.contains("\"X-Test\": \"1\""))
        #expect(errorCode(await rig.call("reqlog_as_curl", ["id": .string(ULID.generate())])) == "not_found")
        try rig.seedRequests([["id": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "method": "CONNECT", "url": "a.test:443", "kind": "tunnel"]])
        #expect(errorCode(await rig.call("reqlog_as_curl", ["id": "01ARZ3NDEKTSV4RRFFQ69G5FAV"])) == "invalid_argument")
    }
}

@Suite struct ProxyRenderToolTests {
    @Test func proxySetOnlyAmongAllowedProxiesAndLogsClosedTunnels() async throws {
        let rig = try await Rig.make(proxiesAllowed: ["zyte-us"])
        defer { rig.cleanup() }
        await rig.claim()
        // CA-107: pedir um proxy não permitido -> blocked_by_policy
        let denied = await rig.call("proxy_set", ["proxy": "other"])
        #expect(errorCode(denied) == "blocked_by_policy" && denied.json["details"]?["allowed"] == ["direct", "zyte-us"])
        #expect(await rig.backend.proxySwitches.isEmpty)
        let ok = await rig.call("proxy_set", ["proxy": "zyte-us", "country": "us"])
        #expect(ok.json["applied"] == true && ok.json["closed_tunnels"] == 3 && ok.json["proxy"] == "zyte-us" && ok.json["country"] == "us")
        #expect(await rig.backend.proxySwitches == ["zyte-us:us"])
        let journal = ChainedLog.read(rig.computer.journal.file)
        #expect(journal.contains { $0["text"]?.string?.contains("closed 3 open tunnels") == true })
        let status = await rig.call("proxy_status")
        #expect(status.json["proxy"] == "zyte-us" && status.json["country"] == "us" && status.json["proxies_allowed"] == ["zyte-us"])
        #expect(status.json["usage"]?["box"]?["renders"] == 1 && status.json["usage"]?["today"] != nil)
        #expect(status.json["render_supported"] == false)
        #expect(await rig.call("proxy_set", ["proxy": "direct"]).json["applied"] == true)
    }

    @Test func renderMapsNotSupportedAndReturnsCapturesWhenSupported() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        #expect(errorCode(await rig.call("render", ["url": "http://x/"])) == "not_supported")
        await rig.backend.setRender(.success(["request_id": "R1", "status": 200, "content": "<html/>", "truncated": false, "body_file": "bodies/R1.response.txt",
                                              "captures": [["id": "C1", "url": "http://x/api/a", "status": 200, "snippet": "{}"]], "usage": ["renders": 1]]))
        let ok = await rig.call("render", ["url": "http://x/", "capture": ["/api/"], "output": "html"])
        #expect(!ok.isError && ok.json["captures"]?.array?.count == 1 && ok.json["usage"]?["renders"] == 1)
        await rig.backend.setRender(.failure(ToolError(.proxyError, "render provider answered 401", details: ["upstream_status": 401])))
        let failed = await rig.call("render", ["url": "http://x/"])
        #expect(errorCode(failed) == "proxy_error" && failed.json["details"]?["upstream_status"] == 401)
        await rig.backend.setRender(.failure(ToolError(.blockedByPolicy, "blocked: link-local")))
        #expect(errorCode(await rig.call("render", ["url": "http://169.254.169.254/"])) == "blocked_by_policy")
    }
}

@Suite struct BrowserToolTests {
    @Test func displayHttpHasNoBrowser() async throws {
        let rig = try await Rig.make(display: .http)
        defer { rig.cleanup() }
        await rig.claim()
        for (tool, args) in [("browser_open", ["url": "http://x/"]), ("browser_read", ["what": "text"]), ("browser_screenshot", [:]), ("browser_back", [:])] as [(String, JSON)] {
            #expect(errorCode(await rig.call(tool, args)) == "not_supported", "\(tool)")
        }
        #expect(await rig.backend.runtimeCalls.isEmpty)
        #expect(!(await rig.call("exec", ["argv": ["id"]])).isError)  // o `work` existe em todo display
        #expect(errorCode(await rig.call("computer_mode", ["display": "headless"])) == "not_supported")
    }

    @Test func browserToolsMapToRuntimeOperationsWithTheirArguments() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("open", ["url": "http://x/", "title": "T", "status": 200, "request_id": "R"])
        let open = await rig.call("browser_open", ["url": "http://x/", "wait_s": 0, "timeout_s": 10])
        #expect(open.json["status"] == 200 && open.json["request_id"] == "R")
        _ = await rig.call("browser_click", ["selector": "#go", "count": 2])
        _ = await rig.call("browser_type", ["selector": "#q", "text": "abc", "submit": true])
        _ = await rig.call("browser_press", ["keys": "Control+A"])
        _ = await rig.call("browser_select", ["selector": "#s", "values": ["a"]])
        _ = await rig.call("browser_scroll", ["dy": 400])
        _ = await rig.call("browser_wait", ["for": ["text": "ok"], "timeout_s": 3])
        _ = await rig.call("browser_eval", ["js": "1+1"])
        _ = await rig.call("browser_tabs", ["action": "list"])
        _ = await rig.call("browser_back")
        _ = await rig.call("browser_forward")
        _ = await rig.call("browser_reload")
        let calls = await rig.backend.runtimeCalls
        #expect(calls.map(\.op) == ["open", "click", "type", "press", "select", "scroll", "wait", "eval", "tabs", "back", "forward", "reload"])
        #expect(calls[1].args["selector"] == "#go" && calls[1].args["count"] == 2)
        #expect(calls[2].args["submit"] == true && calls[2].args["text"] == "abc")
        #expect(calls[0].args["wait_s"]?.double == 0 && calls[0].args["timeout_s"]?.double == 10)
    }

    @Test func openNeverOverrunsFiftySecondsInTotal() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        _ = await rig.call("browser_open", ["url": "http://x/", "wait_s": 30, "timeout_s": 45])
        let args = try #require(await rig.backend.runtimeCalls.last?.args)
        #expect((args["wait_s"]?.double ?? 99) + (args["timeout_s"]?.double ?? 99) <= 50)
    }

    @Test func screenshotReturnsAnImageAndSaveAsIsConfined() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        await rig.backend.setRuntime("screenshot", ["png_b64": .string(png.base64EncodedString()), "bytes": 11, "url": "http://x/"])
        let shot = await rig.call("browser_screenshot", ["save_as": "shots/a.png"])
        #expect(!shot.isError && shot.json["file"] == "/work/shots/a.png")
        #expect(shot.outcome.content.count == 2 && shot.outcome.content[1]["type"] == "image" && shot.outcome.content[1]["mimeType"] == "image/png")
        #expect(shot.outcome.content[1]["data"]?.string.flatMap { Data(base64Encoded: $0) } == png)
        #expect(try Data(contentsOf: rig.computer.run.work.appendingPathComponent("shots/a.png")) == png)
        #expect(errorCode(await rig.call("browser_screenshot", ["save_as": "../x.png"])) == "path_rejected")  // CA-207
        #expect(errorCode(await rig.call("browser_screenshot", ["save_as": "/etc/x.png"])) == "path_rejected")
        try FileManager.default.createSymbolicLink(at: rig.computer.run.work.appendingPathComponent("s.png"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(errorCode(await rig.call("browser_screenshot", ["save_as": "s.png"])) == "path_rejected")
    }

    @Test func uploadReadsOnlyRegularFilesInsideWork() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        try Data("doc".utf8).write(to: rig.computer.run.work.appendingPathComponent("up.txt"))
        #expect(await rig.call("browser_upload", ["selector": "#f", "file": "up.txt"]).json["uploaded"] == true)
        let sent = try #require(await rig.backend.runtimeCalls.last)
        #expect(sent.op == "upload" && sent.args["name"] == "up.txt" && sent.args["data_b64"] == .string(Data("doc".utf8).base64EncodedString()))
        try FileManager.default.createSymbolicLink(at: rig.computer.run.work.appendingPathComponent("a"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        try FileManager.default.createSymbolicLink(atPath: rig.computer.run.work.appendingPathComponent("b").path, withDestinationPath: "../../../../.ssh/id_rsa")
        for file in ["a", "b", "../up.txt", "/etc/passwd"] {
            #expect(errorCode(await rig.call("browser_upload", ["selector": "#f", "file": .string(file)])) == "path_rejected", "\(file)")
        }
        #expect(errorCode(await rig.call("browser_upload", ["selector": "#f", "file": "missing.txt"])) == "not_found")
    }

    @Test func downloadWritesUniqueFilesUnderWorkDownloads() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("download", ["name": "../../evil/report.csv", "bytes": 3, "data_b64": .string(Data("a,b".utf8).base64EncodedString())])
        let first = await rig.call("browser_download", ["url": "http://x/report.csv"])
        #expect(first.json["file"] == "/work/downloads/report.csv" && first.json["bytes"] == 3 && first.json["mime"] == "text/csv")
        let second = await rig.call("browser_download", ["url": "http://x/report.csv"])
        #expect(second.json["file"] == "/work/downloads/report-2.csv")  // não sobrescreve
        #expect(errorCode(await rig.call("browser_download", [:])) == "invalid_argument")
    }

    @Test func cookiesExportWritesAJarInWork() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("cookies", ["cookies": [["name": "sid", "value": "abc", "domain": ".site.test", "path": "/", "secure": true, "expires": 2_000_000_000]]])
        let json = await rig.call("browser_cookies", ["action": "export"])
        #expect(json.json["file"] == "/work/cookies.json" && json.json["count"] == 1)
        let saved = try JSON.parse(try Data(contentsOf: rig.computer.run.work.appendingPathComponent("cookies.json")))
        #expect(saved.array?.first?["name"] == "sid")
        let netscape = await rig.call("browser_cookies", ["action": "export", "file": "jar/cookies.txt"])
        let text = try String(contentsOf: rig.computer.run.work.appendingPathComponent("jar/cookies.txt"), encoding: .utf8)
        #expect(netscape.json["file"] == "/work/jar/cookies.txt" && text.contains(".site.test\tTRUE\t/\tTRUE\t2000000000\tsid\tabc"))
        #expect(errorCode(await rig.call("browser_cookies", ["action": "export", "file": "../x.json"])) == "path_rejected")
        #expect(errorCode(await rig.call("browser_cookies", ["action": "get", "file": "x.json"])) == "invalid_argument")
    }

    @Test func runtimeErrorsKeepTheirCodes() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntimeError("click", ToolError(.timeout, "selector not found in 15 s"))
        #expect(errorCode(await rig.call("browser_click", ["selector": "#ghost"])) == "timeout")
        await rig.backend.setRuntimeError("open", ToolError(.proxyError, "net::ERR_TUNNEL_CONNECTION_FAILED", details: ["request_id": "R"]))
        try rig.seedRequests([["id": .string(ULID.generate()), "source": "egress", "kind": "tunnel", "host": "host.docker.internal", "blocked": true, "blocked_reason": "docker-internal"]])
        // o registro de bloqueio é ANTERIOR à chamada: não conta; é proxy_error
        #expect(errorCode(await rig.call("browser_open", ["url": "http://host.docker.internal/", "wait_s": 0])) == "proxy_error")
    }

    @Test func runtimeErrorMapperCoversTheWireCodes() {
        #expect(RuntimeErrorMapper.map(status: 408, body: ["error": "timeout", "message": "t"]).code == .timeout)
        #expect(RuntimeErrorMapper.map(status: 409, body: ["error": "box_restarted"]).code == .boxRestarted)
        #expect(RuntimeErrorMapper.map(status: 503, body: [:]).code == .boxRestarted)
        #expect(RuntimeErrorMapper.map(status: 502, body: ["error": "navigation_failed", "message": "m"]).code == .proxyError)
        #expect(RuntimeErrorMapper.map(status: 401, body: ["error": "unauthorized"]).code == .appUnavailable)
        #expect(RuntimeErrorMapper.map(status: 400, body: ["error": "invalid_argument", "message": "x"]).code == .invalidArgument)
        #expect(RuntimeErrorMapper.map(status: 501, body: ["error": "not_supported"]).code == .notSupported)
        #expect(RuntimeErrorMapper.map(status: 500, body: ["error": "weird"]).code == .invalidArgument)
    }
}

@Suite struct EvidenceToolTests {
    @Test func journalTracksDoingBlockedAndFeedsTheTimeline() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        _ = await rig.call("journal", ["kind": "PLAN", "text": "search listings"])
        _ = await rig.call("journal", ["kind": "DOING", "text": "opening portal"])
        let found = await rig.call("journal", ["kind": "FOUND", "text": "api at /api/listings", "evidence": ["01ARZ3NDEKTSV4RRFFQ69G5FAV"]])
        #expect(found.json["entry_id"]?.string?.count == 26)
        _ = await rig.call("journal", ["kind": "BLOCKED", "text": "captcha"])
        let lastDoing = await rig.computer.lastDoing, openBlocked = await rig.computer.openBlocked
        #expect(lastDoing == "opening portal" && openBlocked == "captcha")
        #expect(try ReqlogIntegrity.verify(file: rig.computer.journal.file) == .ok(lines: 4))

        try rig.seedRequests([["id": .string(ULID.generate()), "ts": .double(Date().timeIntervalSince1970 + 1), "source": "browser", "status": 200, "method": "GET", "via": "direct", "url": "http://p.test/api"]])
        let md = await rig.call("timeline")
        let content = try #require(md.json["content"]?.string)
        #expect(content.hasPrefix("# Timeline: box-a") && content.contains("PLAN") && content.contains("search listings") && content.contains("BLOCKED"))
        #expect(content.contains("[evidence: 01ARZ3NDEKTSV4RRFFQ69G5FAV]") && content.contains("HTTP") && content.contains("http://p.test/api"))
        let json = try JSON.parse(try #require((await rig.call("timeline", ["format": "json", "include": ["journal"]])).json["content"]?.string))
        #expect(json.array?.count == 4 && json.array?.first?["kind"] == "PLAN")
        // ordem temporal
        let stamps = (json.array ?? []).compactMap { $0["ts"]?.double }
        #expect(stamps == stamps.sorted())
        // since por timestamp futuro: nada
        #expect(try JSON.parse(try #require((await rig.call("timeline", ["format": "json", "since": "2999-01-01T00:00:00Z"])).json["content"]?.string)).array?.isEmpty == true)
        #expect(errorCode(await rig.call("timeline", ["since": "yesterday-ish"])) == "invalid_argument")
        #expect(errorCode(await rig.call("timeline", ["since": .string(ULID.generate())])) == "not_found")
        ComputerToolService.writeTimelineFile(rig.computer)
        #expect(try String(contentsOf: rig.computer.run.timelineFile, encoding: .utf8).contains("# Timeline: box-a"))
    }

    @Test func resultSubmitWritesTheFileAndValidatesCitations() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let real = ULID.generate(), fake = ULID.generate()
        try rig.seedRequests([["id": .string(real), "trust": "observed", "source": "browser"]])
        try Data("a,b\n1,2".utf8).write(to: rig.computer.run.work.appendingPathComponent("data.csv"))
        let result = await rig.call("result_submit", [
            "result": ["price": 10, "owner": "ACME", "count": 3, "rows": 1],
            "evidence": ["/price": [.string(real)], "/owner": [.string(fake)], "/rows": ["/work/data.csv"]],
        ])
        #expect(!result.isError, "\(result.json.text)")
        #expect(result.json["file"] == "/work/result.json")
        let summary = try #require(result.json["validation"]?["summary"])
        #expect(summary["verified"] == 2 && summary["cited_missing"] == 1 && summary["not_verified"] == 1)  // CA-203
        let fields = Dictionary(uniqueKeysWithValues: (result.json["validation"]?["fields"]?.array ?? []).compactMap { f in f["pointer"]?.string.map { ($0, f["status"]?.string ?? "") } })
        #expect(fields["/price"] == "verified" && fields["/owner"] == "cited_missing" && fields["/count"] == "not_verified" && fields["/rows"] == "verified")
        let written = try JSON.parse(try Data(contentsOf: rig.computer.run.work.appendingPathComponent("result.json")))
        #expect(written["price"] == 10)
        // a validação mora em logs/, fora do alcance do agente
        #expect(FileManager.default.fileExists(atPath: rig.computer.run.file("validation.json").path))
        #expect(!FileManager.default.fileExists(atPath: rig.computer.run.work.appendingPathComponent("validation.json").path))
        #expect(errorCode(await rig.call("result_submit", ["result": ["a": 1], "evidence": ["/zzz": [.string(real)]]])) == "invalid_argument")
    }

    @Test func resultSubmitRefusesCitationsThroughSymlinksAndDotDot() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        try FileManager.default.createSymbolicLink(atPath: rig.computer.run.work.appendingPathComponent("b").path, withDestinationPath: "../../../../.ssh/id_rsa")
        #expect(errorCode(await rig.call("result_submit", ["result": ["x": 1], "evidence": ["/x": ["b"]]])) == "path_rejected")  // CA-207
        #expect(errorCode(await rig.call("result_submit", ["result": ["x": 1], "evidence": ["/x": ["../secrets"]]])) == "path_rejected")
        #expect(errorCode(await rig.call("result_submit", ["result": ["x": 1], "evidence": ["/x": ["/etc/passwd"]]])) == "path_rejected")
        #expect(!FileManager.default.fileExists(atPath: rig.computer.run.work.appendingPathComponent("result.json").path))  // nada gravado
    }

    @Test func resultJsonThatIsASymlinkIsNotFollowed() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let target = rig.temp.root.appendingPathComponent("victim.txt")
        try Data("KEEP".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: rig.computer.run.work.appendingPathComponent("result.json"), withDestinationURL: target)
        #expect(errorCode(await rig.call("result_submit", ["result": ["a": 1]])) == "path_rejected")
        #expect(try String(contentsOf: target, encoding: .utf8) == "KEEP")
    }

    @Test func toolResultsAreAlwaysTheSameShapeOnError() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let results = [
            await rig.call("box_status"), await rig.call("browser_open", ["url": 1]), await rig.call("nope"),
            await rig.call("box_claim", ["name": "ghost", "wait_s": 0]),
        ]
        let codes = Set(ToolErrorCode.allCases.map(\.rawValue))
        for result in results {
            #expect(result.isError)
            #expect(codes.contains(result.json["error"]?.string ?? "?"), "\(result.json.text)")
            #expect(result.json["message"]?.string?.isEmpty == false)
        }
    }
}
