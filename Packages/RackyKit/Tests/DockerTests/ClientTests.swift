import RackyPlatform
import Foundation
import Testing

@testable import RackyDocker

/// Cliente contra um daemon Docker de brincadeira (sem Docker real): framing HTTP, erros, streams, hijack e prazos.
@Suite(.tags(.integration)) struct ClientAgainstFakeDaemonTests {
    @Test func pingVersionInfoAndApiVersionInPath() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch request.path {
            case "/_ping": await Reply.text(connection, "OK")
            case "/v1.43/version": await Reply.json(connection, body: (try? Fixtures.data("version-desktop.json")) ?? Data())
            case "/v1.43/info": await Reply.json(connection, body: (try? Fixtures.data("info-desktop.json")) ?? Data())
            default: await Reply.json(connection, status: 404, body: Data(#"{"message":"nope"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let client = daemon.client
        try await client.ping()
        #expect(try await client.version().os == "linux")
        #expect(try await client.info().cpuCount == 14)
        let paths = await daemon.log.items.map(\.path)
        #expect(paths == ["/_ping", "/v1.43/version", "/v1.43/info"])
    }

    @Test func missingSocketIsRuntimeUnavailable() async throws {
        let dir = try TempSocketDir()
        let client = DockerClient(socketPath: dir.socketPath)
        do {
            try await client.ping()
            Issue.record("deveria falhar")
        } catch let error as DockerError {
            #expect(error.isRuntimeUnavailable)
        }
    }

    @Test func statusCodesMapToTypedErrorsAndIdempotentOperations() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch (request.method, request.path) {
            case ("GET", "/v1.43/containers/missing/json"): await Reply.json(connection, status: 404, body: (try? Fixtures.data("error-404.json")) ?? Data())
            case ("POST", "/v1.43/containers/create"): await Reply.json(connection, status: 409, body: (try? Fixtures.data("error-409.json")) ?? Data())
            case ("POST", "/v1.43/containers/started/start"): await Reply.raw(connection, status: 304, headers: [:], body: Data())
            case ("POST", "/v1.43/containers/stopped/stop"): await Reply.raw(connection, status: 304, headers: [:], body: Data())
            case ("DELETE", _): await Reply.json(connection, status: 404, body: Data(#"{"message":"No such container"}"#.utf8))
            default: await Reply.json(connection, status: 500, body: Data(#"{"message":"boom"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let client = daemon.client
        await #expect(throws: DockerError.self) { try await client.inspectContainer("missing") }
        do { _ = try await client.inspectContainer("missing") } catch let error as DockerError { #expect(error.isNotFound) }
        do { _ = try await client.createContainer(ContainerSpec(name: "dup", image: "x")) } catch let error as DockerError { #expect(error.isConflict) }
        try await client.startContainer("started")  // 304 = já iniciado
        try await client.stopContainer("stopped", graceSeconds: 1)  // 304 = já parado
        try await client.removeContainer("gone", force: true)  // 404 = já removido
        try await client.removeNetwork("gone")
        try await client.removeVolume("gone")
        do { try await client.killContainer("x") } catch let error as DockerError { #expect(error == .api(status: 500, message: "container kill: boom")) }
    }

    @Test func containerCreateSendsNameAndBodyAndReturnsId() async throws {
        let daemon = try await FakeDockerDaemon { _, connection in
            await Reply.json(connection, status: 201, body: Data(#"{"Id":"abc123","Warnings":[]}"#.utf8))
        }
        defer { daemon.stop() }
        var spec = ContainerSpec(name: "ab-1234abcd-work", image: "racky-box:ctx-x", command: ["sleep", "1"])
        spec.labels = [RackyLabel.test: "1"]
        let id = try await daemon.client.createContainer(spec)
        #expect(id == "abc123")
        let request = try #require(await daemon.log.items.first)
        #expect(request.method == "POST" && request.path == "/v1.43/containers/create" && request.query == "name=ab-1234abcd-work")
        #expect(request.headers["content-type"] == "application/json")
        #expect((request.jsonBody?["Labels"] as? [String: String])?[RackyLabel.test] == "1")
    }

    @Test func eventsStreamParsesChunkedJSONLinesSplitAcrossChunks() async throws {
        let lines = try Fixtures.text("events.jsonl")
        let bytes = Data(lines.utf8)
        // Fatia arbitrária: eventos cortados no meio do JSON entre chunks.
        let slices = stride(from: 0, to: bytes.count, by: 97).map { Data(bytes[$0 ..< min($0 + 97, bytes.count)]) }
        let daemon = try await FakeDockerDaemon { request, connection in
            #expect(request.path == "/v1.43/events")
            await Reply.chunked(connection, chunks: slices)
        }
        defer { daemon.stop() }
        var actions: [String] = []
        for try await event in try await daemon.client.events(filters: ["label": ["racky.test=1"]], since: 1) { actions.append(event.baseAction) }
        #expect(actions.first == "create" && actions.contains("destroy"))
        let query = try #require(await daemon.log.items.first).query
        #expect(query.contains("filters=%7B%22label%22%3A%5B%22racky.test%3D1%22%5D%7D") && query.contains("since=1"))
    }

    @Test func pullStreamsProgressAndSurfacesRegistryErrors() async throws {
        let ok = try await FakeDockerDaemon { request, connection in
            #expect(request.method == "POST" && request.path == "/v1.43/images/create" && request.query.hasPrefix("fromImage=ghcr.io%2Facme%2Fbox%40sha256%3Aabc"))
            await Reply.chunked(connection, chunks: [Data((try? Fixtures.data("pull-stream.jsonl")) ?? Data())])
        }
        defer { ok.stop() }
        let last = try await ok.client.pullImageToCompletion("ghcr.io/acme/box@sha256:abc")
        #expect(last?.hasPrefix("Status: Downloaded newer image") == true)
        var statuses: [String] = []
        for try await event in try await ok.client.pullImage("ghcr.io/acme/box@sha256:abc") { if let s = event.status { statuses.append(s) } }
        #expect(statuses.contains("Pull complete"))

        let bad = try await FakeDockerDaemon { _, connection in
            await Reply.chunked(connection, chunks: [Data((try? Fixtures.data("pull-error-stream.jsonl")) ?? Data())])
        }
        defer { bad.stop() }
        await #expect(throws: DockerError.imagePullFailed("manifest unknown")) { try await bad.client.pullImageToCompletion("x@sha256:1") }
    }

    @Test func buildSendsTarContextAndReportsStepsAndFailures() async throws {
        let ok = try await FakeDockerDaemon { _, connection in
            await Reply.chunked(connection, chunks: [Data((try? Fixtures.data("build-stream.jsonl")) ?? Data())])
        }
        defer { ok.stop() }
        let context = Data(repeating: 7, count: 2048)
        var steps: [Int] = []
        var imageID: String?
        for try await event in try await ok.client.buildImage(context: context, tag: "racky-box:ctx-abc", labels: ["racky.test": "1"]) {
            if let step = event.step { steps.append(step.index) }
            if let id = event.imageID { imageID = id }
        }
        #expect(steps == [1, 2, 3] && imageID?.hasPrefix("sha256:feedface") == true)
        let request = try #require(await ok.log.items.first)
        #expect(request.headers["content-type"] == "application/x-tar" && request.body == context)
        #expect(request.query.contains("t=racky-box%3Actx-abc") && request.query.contains("version=1") && request.query.contains("labels="))

        let bad = try await FakeDockerDaemon { _, connection in
            await Reply.chunked(connection, chunks: [Data((try? Fixtures.data("build-error-stream.jsonl")) ?? Data())])
        }
        defer { bad.stop() }
        do {
            for try await _ in try await bad.client.buildImage(context: context, tag: "t") {}
            Issue.record("deveria falhar")
        } catch let error as DockerError {
            if case .imageBuildFailed(let message) = error {
                #expect(message.contains("non-zero code"))
            } else {
                Issue.record("tipo errado \(error)")
            }
        }
    }

    @Test func logsDemultiplexStdoutAndStderrFromChunkedBody() async throws {
        let payload = Reply.mux(1, "hello\n") + Reply.mux(2, "oops\n") + Reply.mux(1, "bye\n")
        let daemon = try await FakeDockerDaemon { request, connection in
            #expect(request.path == "/v1.43/containers/c1/logs")
            await Reply.chunked(connection, contentType: "application/vnd.docker.multiplexed-stream", chunks: [payload.prefix(5), payload.dropFirst(5)].map { Data($0) })
        }
        defer { daemon.stop() }
        let logs = try await daemon.client.collectedLogs("c1")
        #expect(logs.stdout == "hello\nbye\n" && logs.stderr == "oops\n")
    }

    @Test func waitReturnsStatusCode() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            #expect(request.query == "condition=not-running")
            await Reply.json(connection, body: Data(#"{"StatusCode":137}"#.utf8))
        }
        defer { daemon.stop() }
        #expect(try await daemon.client.waitContainer("c1") == 137)
    }

    @Test func operationsHaveDeadlineAndCancelClosesTheSocket() async throws {
        let daemon = try await FakeDockerDaemon { _, _ in try? await Task.sleep(for: .seconds(30)) }
        defer { daemon.stop() }
        let client = DockerClient(socketPath: daemon.socketPath, defaultTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        await #expect(throws: DockerError.timeout(operation: "info")) { try await client.info() }
        #expect(ContinuousClock.now - started < .seconds(3))

        let task = Task { try await client.waitContainer("c1", timeout: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let begin = ContinuousClock.now
        do {
            _ = try await task.value
            Issue.record("deveria cancelar")
        } catch {
            #expect(error as? DockerError == .cancelled)
        }
        #expect(ContinuousClock.now - begin < .seconds(2))
    }

    @Test func createTimeoutReconcilesWithForceRemoveByDeterministicName() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            if request.method == "POST", request.path.hasSuffix("/containers/create") {
                try? await Task.sleep(for: .seconds(30))  // daemon "preso" no create
            } else {
                await Reply.json(connection, status: 404, body: Data(#"{"message":"No such container"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        await #expect(throws: DockerError.timeout(operation: "container create")) {
            try await daemon.client.createContainer(ContainerSpec(name: "ab-deadbeef-runtime", image: "x"), timeout: .milliseconds(150))
        }
        let removals = await daemon.log.matching("DELETE", prefix: "/containers/ab-deadbeef-runtime")
        #expect(removals.count == 5, "o create pode ainda estar a caminho: o rm -f é repetido até a janela acabar")
        #expect(removals.allSatisfy { $0.query.contains("force=1") && $0.query.contains("v=1") })
    }

    @Test func interruptedCreateThatLandsLateIsStillRemoved() async throws {
        let created = ConnectionCounter()
        let daemon = try await FakeDockerDaemon { request, connection in
            if request.method == "POST", request.path.hasSuffix("/containers/create") {
                try? await Task.sleep(for: .seconds(30))
            } else if request.method == "DELETE" {
                // O container "aparece" só depois da 2ª tentativa de remoção (create atrasado no daemon).
                let n = await created.next()
                if n < 3 {
                    await Reply.json(connection, status: 404, body: Data(#"{"message":"No such container"}"#.utf8))
                } else {
                    await Reply.raw(connection, status: 204, headers: [:], body: Data())
                }
            }
        }
        defer { daemon.stop() }
        await #expect(throws: DockerError.timeout(operation: "container create")) {
            try await daemon.client.createContainer(ContainerSpec(name: "ab-late-runtime", image: "x"), timeout: .milliseconds(100))
        }
        #expect(await daemon.log.matching("DELETE", prefix: "/containers/ab-late-runtime").count == 3, "para de tentar depois de remover")
    }

    @Test func hijackedExecEchoesStdinWithHalfCloseAndSeparatesStreams() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch request.path {
            case "/v1.43/containers/c1/exec":
                #expect((request.jsonBody?["Cmd"] as? [String]) == ["cat"] && request.jsonBody?["AttachStdin"] as? Bool == true)
                await Reply.json(connection, status: 201, body: Data(#"{"Id":"exec1"}"#.utf8))
            case "/v1.43/exec/exec1/start":
                #expect(request.headers["upgrade"] == "tcp" && request.headers["connection"] == "Upgrade")
                try? await connection.send(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8))
                // Lê o stdin até o half-close do cliente, devolve em stdout e escreve algo em stderr.
                var input = Data()
                while let chunk = try? await connection.receive() { input.append(chunk) }
                try? await connection.send(Reply.mux(1, String(decoding: input, as: UTF8.self).uppercased()) + Reply.mux(2, "done\n"))
            case "/v1.43/exec/exec1/json":
                await Reply.json(connection, body: Data(#"{"Running":false,"ExitCode":3,"Pid":42}"#.utf8))
            default:
                await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let result = try await daemon.client.run(in: "c1", command: ["cat"], stdin: Data("hello stdin".utf8), killableGroup: false)
        #expect(result.stdoutString == "HELLO STDIN" && result.stderrString == "done\n" && result.exitCode == 3)
    }

    @Test func execFailsClearlyWhenDaemonDoesNotUpgrade() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            if request.path.hasSuffix("/exec") {
                await Reply.json(connection, status: 201, body: Data(#"{"Id":"e"}"#.utf8))
            } else {
                await Reply.json(connection, status: 409, body: Data(#"{"message":"Container x is not running"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        do {
            _ = try await daemon.client.startExec(in: "c", spec: ExecSpec(command: ["true"]))
            Issue.record("deveria falhar")
        } catch let error as DockerError {
            #expect(error.isConflict)
        }
    }

    @Test func killableExecWrapsCommandAndTerminateSignalsGroupThenKills() async throws {
        let daemon = try await FakeDockerDaemon { request, connection in
            switch request.path {
            case "/v1.43/containers/c1/exec":
                await Reply.json(connection, status: 201, body: Data(#"{"Id":"exec\#(request.body.count)"}"#.utf8))
            case let path where path.hasSuffix("/start"):
                try? await connection.send(Data("HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8))
                try? await Task.sleep(for: .seconds(30))
            case let path where path.hasSuffix("/json"):
                await Reply.json(connection, body: Data(#"{"Running":true,"Pid":1}"#.utf8))
            default:
                await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
            }
        }
        defer { daemon.stop() }
        let session = try await daemon.client.startExec(in: "c1", spec: ExecSpec(command: ["sleep", "300"], killableGroup: true))
        let create = try #require(await daemon.log.matching("POST", prefix: "/exec").first)
        let cmd = try #require(create.jsonBody?["Cmd"] as? [String])
        #expect(cmd.prefix(2) == ["/bin/sh", "-c"] && cmd.suffix(2) == ["sleep", "300"] && cmd[3].hasPrefix("/tmp/.abx-exec-"))
        #expect(cmd[2].contains("echo $$ > \"$0\"") && cmd[2].contains("exec \"$@\""))
        // Sem exec controlável, signalGroup falha de forma tipada.
        let plain = try await daemon.client.startExec(in: "c1", spec: ExecSpec(command: ["sleep", "1"]))
        await #expect(throws: DockerError.execNotKillable) { try await plain.signalGroup("TERM") }
        session.close()
        plain.close()
    }

    @Test func twentyParallelSlowCallsDoNotBlockTheCooperativePool() async throws {
        // AR-404: 20 chamadas de 2 s em paralelo; um await trivial no actor de teste responde em < 50 ms o tempo todo.
        let daemon = try await FakeDockerDaemon { _, connection in
            try? await Task.sleep(for: .seconds(2))
            await Reply.json(connection, body: (try? Fixtures.data("info-desktop.json")) ?? Data())
        }
        defer { daemon.stop() }
        let client = DockerClient(socketPath: daemon.socketPath, defaultTimeout: .seconds(20))
        // Um pool bloqueado aparece como lacuna de ~2 s (a duração de cada chamada). Com a máquina cheia (suíte inteira em
        // paralelo) o agendador pode atrasar 50 ms por outro motivo, então vale a melhor de até 3 tentativas.
        var best = Duration.seconds(99)
        for _ in 0 ..< 3 {
            let probe = ResponsivenessProbe()
            let probing = Task { await probe.run() }
            let started = ContinuousClock.now
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0 ..< 20 { group.addTask { try await client.info().cpuCount } }
                var total = 0
                for try await cpus in group { total += cpus }
                #expect(total == 20 * 14)
            }
            let elapsed = ContinuousClock.now - started
            await probe.stop()
            await probing.value
            #expect(elapsed < .seconds(6), "as 20 chamadas rodam em paralelo (~2 s), não em série")
            best = min(best, await probe.maxGap)
            if best < .milliseconds(50) { break }
        }
        #expect(best < .milliseconds(50), "lacuna máxima \(best)")
    }
}

/// Mede o maior atraso de um `Task.sleep` curto: pool cooperativo bloqueado apareceria como lacuna grande.
actor ResponsivenessProbe {
    private(set) var maxGap: Duration = .zero
    private var running = true

    func run() async {
        var last = ContinuousClock.now
        while running {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            maxGap = max(maxGap, now - last - .milliseconds(5))
            last = now
        }
    }

    func stop() { running = false }
}
