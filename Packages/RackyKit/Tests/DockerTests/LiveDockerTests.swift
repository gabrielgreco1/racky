import RackyPlatform
import Foundation
import Testing

@testable import RackyDocker

@Suite("Docker real (RACKY_TEST_DOCKER=1)", .serialized, .enabled(if: Live.enabled), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveDockerTests {
    // MARK: Runtime e capacidade

    @Test func detectsActiveContextMatchingDockerContextInspectAndReadsVMCapacity() async throws {
        let detected = try await Live.detect()
        let info = detected.info
        await Evidence.shared.record("slice3/T3-01/live-runtime.json", "runtime", "\(detected.runtime.kind.rawValue) \(detected.runtime.socketPath) via \(detected.runtime.source)")
        await Evidence.shared.record("slice3/T3-01/live-runtime.json", "engine", "\(detected.version.version) api \(detected.version.apiVersion) \(info.operatingSystem) \(info.architecture)")
        await Evidence.shared.record("slice3/T3-01/live-runtime.json", "vm", "MemTotal=\(info.memTotal) NCPU=\(info.cpuCount)")
        #expect(detected.version.os == "linux" && info.memTotal > 1 << 30 && info.cpuCount >= 1)
        #expect(detected.isVerifiedArchitecture || info.architecture.contains("x86"))

        let capacity = CapacityPlanner(vm: detected.capacity)
        await Evidence.shared.record("slice3/T3-01/live-runtime.json", "capacity", "budget=\(capacity.budgetGiB) GiB; headless=\(capacity.maxConcurrent(.headless)) desktop=\(capacity.maxConcurrent(.desktop)); warning=\(capacity.vmSizeWarning() ?? "none")")

        // O endpoint detectado sem o CLI tem de ser o mesmo que `docker context inspect` informa.
        guard let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              case .activeContext = detected.runtime.source else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        await Evidence.shared.record("slice3/T3-01/live-runtime.json", "docker_context_inspect", output)
        #expect(output == "unix://\(detected.runtime.socketPath)")
    }

    // MARK: Imagens (pull por digest, build com contexto tar, tag por hash, fallback)

    @Test func pullByDigestBuildFromTarContextAndHashTaggedEnsure() async throws {
        try await Live.with { env in
            // pull por digest (já presente: stream curto, mas passa pela Engine API)
            let last = try await env.client.pullImageToCompletion(Live.alpine)
            #expect(last?.contains(Live.alpineDigest) == true || last?.hasPrefix("Status:") == true, "status final: \(last ?? "nil")")
            let base = try await env.client.inspectImage(Live.alpine)
            #expect(base.repoDigests.contains { $0.hasSuffix(Live.alpineDigest) })

            // contexto de build de teste com label racky.test
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-live-ctx-\(env.runID)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data("FROM \(Live.alpine)\nLABEL racky.test=1 racky.test_run=\(env.runID)\nCOPY hello.txt /hello.txt\nRUN cat /hello.txt\n".utf8)
                .write(to: dir.appendingPathComponent("Dockerfile"))
            try Data("hello \(env.runID)\n".utf8).write(to: dir.appendingPathComponent("hello.txt"))

            let source = ImageSource(
                repository: "racky-test-\(env.runID)", contextDirectory: dir,
                extraLabels: [RackyLabel.test: "1", "racky.test_run": env.runID])
            let recorder = ProgressRecorder()
            let first = try await ImageManager(client: env.client).ensure(source) { recorder.add($0) }
            #expect(first.acquisition == .built)
            #expect(first.tag == BuildContext.tag(repository: source.repository, hash: first.contextHash))
            let steps = recorder.steps
            #expect(steps.last?.step == steps.last?.total && (steps.last?.total ?? 0) >= 3, "progresso de passos: \(steps)")
            let built = try await env.client.inspectImage(first.tag)
            #expect(built.labels[RackyLabel.contextHash] == first.contextHash)

            // segunda chamada: tag por hash já existe
            let second = try await ImageManager(client: env.client).ensure(source)
            #expect(second.acquisition == .alreadyPresent && second.imageID == first.imageID)

            // mudar o contexto muda a tag: o app sabe qual tag espera (CS-120)
            try Data("changed\n".utf8).write(to: dir.appendingPathComponent("hello.txt"))
            let third = try await ImageManager(client: env.client).ensure(source)
            #expect(third.tag != first.tag && third.acquisition == .built)

            // digest do GHCR inexistente: pull falha e cai para o build local (CS-121)
            try Data("changed again\n".utf8).write(to: dir.appendingPathComponent("hello.txt"))
            var withGHCR = source
            withGHCR.ghcrRepository = "ghcr.io/racky-test-nonexistent/racky-box"
            withGHCR.digest = "sha256:" + String(repeating: "0", count: 64)
            let logs = ProgressRecorder()
            let fallback = try await ImageManager(client: env.client).ensure(withGHCR) { logs.add($0) }
            #expect(fallback.acquisition == .built)
            #expect(logs.lines.contains { $0.contains("pull falhou") })

            await Evidence.shared.record("slice3/T3-01/live-images.json", "pull_by_digest", last ?? "")
            await Evidence.shared.record("slice3/T3-01/live-images.json", "build_tar_context_steps", "\(steps.last?.step ?? 0) of \(steps.last?.total ?? 0)")
            await Evidence.shared.record("slice3/T3-01/live-images.json", "tag_by_hash", first.tag)
            await Evidence.shared.record("slice3/T3-01/live-images.json", "ghcr_fallback", "pull falhou, build local: \(fallback.tag)")
        }
    }

    /// Build do contexto REAL `runtime/computer` pela Engine API (tar + builder clássico). Lento (apt + pip, ~minutos):
    /// só com `RACKY_TEST_BUILD_RUNTIME_IMAGE=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RACKY_TEST_BUILD_RUNTIME_IMAGE"] == "1"))
    func buildsTheRealRuntimeBoxImageThroughEngineAPI() async throws {
        try await Live.with { env in
            var root = URL(fileURLWithPath: #filePath)
            while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) { root.deleteLastPathComponent() }
            let source = ImageSource(
                repository: "racky-computer-test-\(env.runID)", contextDirectory: root.appendingPathComponent("runtime/computer"),
                extraLabels: [RackyLabel.test: "1", "racky.test_run": env.runID])
            let recorder = ProgressRecorder()
            let started = ContinuousClock.now
            let image = try await ImageManager(client: env.client).ensure(source) { recorder.add($0) }
            let elapsed = ContinuousClock.now - started
            #expect(image.acquisition == .built && image.tag.hasPrefix("racky-computer-test-\(env.runID):ctx-"))
            let steps = recorder.steps
            #expect(steps.last?.step == steps.last?.total, "passos: \(steps)")

            var spec = env.spec("box")
            spec.image = image.tag
            spec.command = nil
            spec.user = "10002:10002"
            let id = try await env.run(spec)  // entrypoint ocioso do papel work
            let probe = try await env.client.run(in: id, command: ["sh", "-c", "id -u; uname -m; python -c 'import curl_cffi, httpx, lxml, bs4, openpyxl, requests, playwright; print(curl_cffi.__version__)'; which Xvfb x11vnc websockify xdotool dtach jq"])
            #expect(probe.exitCode == 0 && probe.stdoutString.hasPrefix("10002\n"), "\(probe.stdoutString) \(probe.stderrString)")
            await Evidence.shared.record("slice3/T3-01/live-images.json", "real_runtime_box_build_via_engine_api", "\(image.tag) em \(elapsed); passos \(steps.last?.step ?? 0) of \(steps.last?.total ?? 0); smoke: \(probe.stdoutString.replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    // MARK: Ciclo de vida, hardening, labels, eventos

    @Test func containerLifecycleHardeningLabelsAndEvents() async throws {
        try await Live.with { env in
            let netID = try await env.client.createNetwork(name: env.name("net"), isInternal: true, labels: env.baseLabels)
            let net = try await env.client.inspectNetwork(netID)
            #expect(net.isInternal && net.labels["racky.test_run"] == env.runID)

            let volume = try await env.client.createVolume(name: env.name("vol"), labels: env.baseLabels)
            #expect(volume.labels[RackyLabel.test] == "1")

            var spec = env.spec("life", command: ["sh", "-c", "echo started; echo oops >&2; sleep 2; exit 3"], role: .runtime)
            spec.network = ContainerNetworkAttachment(network: env.name("net"), aliases: ["runtime"])
            spec.named = ["\(env.name("vol")):/data"]
            spec.user = "10001:10001"

            // Eventos: assina antes de criar, filtrando só os recursos desta execução.
            let collector = EventCollector()
            let stream = try await env.client.events(filters: ["label": env.labelFilter, "type": ["container"]])
            let listening = Task {
                do {
                    for try await event in stream {
                        await collector.add(event)
                        if event.baseAction == "destroy" { break }
                    }
                } catch {}
            }
            let id = try await env.client.createContainer(spec)
            try await env.client.startContainer(id)

            let inspect = try await env.client.inspectContainer(id)
            #expect(inspect.name == env.name("life") && inspect.state.running)
            #expect(inspect.readonlyRootfs && inspect.capDrop == ["ALL"] && inspect.securityOpt == ["no-new-privileges"] && inspect.usesInit)
            #expect(inspect.memoryLimit == 96 << 20 && inspect.nanoCPUs == 500_000_000 && inspect.pidsLimit == 128)
            #expect(inspect.user == "10001:10001")
            #expect(inspect.labels[RackyLabel.role] == "runtime" && inspect.labels[RackyLabel.computer] == "c-\(env.runID)")
            #expect(inspect.networks.keys.contains(env.name("net")) && inspect.networks[env.name("net")]?.aliases.contains("runtime") == true)
            #expect(!inspect.env.contains { $0.lowercased().contains("token") }, "T9: nenhum token em env")
            #expect(inspect.ports.isEmpty, "o runtime não publica porta")

            let code = try await env.client.waitContainer(id, timeout: .seconds(30))
            #expect(code == 3)
            let logs = try await env.client.collectedLogs(id)
            #expect(logs.stdout == "started\n" && logs.stderr == "oops\n")
            let exited = try await env.client.inspectContainer(id)
            #expect(!exited.state.running && exited.state.exitCode == 3)

            // idempotência: stop de container parado e remove duas vezes
            try await env.client.stopContainer(id, graceSeconds: 1)
            try await env.client.removeContainer(id, force: true, removeVolumes: false)
            try await env.client.removeContainer(id, force: true)
            #expect(try await env.client.listContainers(filters: ["label": env.labelFilter]).isEmpty)

            let watchdog = Task {
                try? await Task.sleep(for: .seconds(10))
                listening.cancel()
            }
            await listening.value
            watchdog.cancel()
            let actions = await collector.actions
            await Evidence.shared.record("slice3/T3-01/live-lifecycle.json", "events", actions.joined(separator: ","))
            await Evidence.shared.record("slice3/T3-01/live-lifecycle.json", "exit_code", "\(code)")
            #expect(Array(actions.prefix(3)) == ["create", "start", "die"] && actions.last == "destroy", "eventos: \(actions)")
            let die = await collector.events.first { $0.baseAction == "die" }
            #expect(die?.exitCode == 3 && die?.name == env.name("life"))

            try await env.client.removeNetwork(netID)
            try await env.client.removeVolume(env.name("vol"))
            #expect(try await env.client.listNetworks(filters: ["label": env.labelFilter]).isEmpty)
        }
    }

    @Test func duplicateNameConflictAndCreateTimeoutLeavesNoOrphan() async throws {
        try await Live.with { env in
            let spec = env.spec("dup")
            _ = try await env.client.createContainer(spec)
            do {
                _ = try await env.client.createContainer(spec)
                Issue.record("deveria dar conflito")
            } catch let error as DockerError {
                #expect(error.isConflict)
            }
            try await env.client.removeContainer(env.name("dup"), force: true)

            // CS-106: prazo ridículo; seja qual for o ponto em que estourou, não pode sobrar container com o nome.
            let slow = env.spec("slow")
            do {
                _ = try await env.client.createContainer(slow, timeout: .milliseconds(1))
                try await env.client.removeContainer(env.name("slow"), force: true)
            } catch let error as DockerError {
                #expect(error == .timeout(operation: "container create"))
            }
            try await Task.sleep(for: .seconds(2))  // um create atrasado no daemon não pode reaparecer depois da reconciliação
            let leftover = try await env.client.listContainers(filters: ["name": [env.name("slow")], "label": env.labelFilter])
            #expect(leftover.isEmpty)
        }
    }

    // MARK: Exec hijacked (S9)

    @Test func execStdinStdoutStderrExitCodeAndHalfClose() async throws {
        try await Live.with { env in
            let id = try await env.run(env.spec("exec"))

            // stdin -> stdout, EOF por half-close, exit 0
            let cat = try await env.client.run(in: id, command: ["cat"], stdin: Data("hello via hijack\n".utf8))
            #expect(cat.exitCode == 0 && cat.stdoutString == "hello via hijack\n" && cat.stderrString.isEmpty)

            // stdout e stderr separados e código de saída
            let split = try await env.client.run(in: id, command: ["sh", "-c", "echo out; echo err >&2; exit 7"])
            #expect(split.exitCode == 7 && split.stdoutString == "out\n" && split.stderrString == "err\n")

            // comando inexistente
            do {
                let missing = try await env.client.run(in: id, command: ["/bin/nao-existe"], killableGroup: false)
                #expect(missing.exitCode != 0)
            } catch is DockerError {
                // o daemon também pode recusar o start do exec (OCI runtime exec failed): erro tipado
            }

            // stdin binário de 2 MiB ida e volta (integridade e contrapressão)
            let payload = Data((0 ..< (2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
            let echo = try await env.client.run(in: id, command: ["cat"], stdin: payload, timeout: .seconds(60))
            #expect(echo.exitCode == 0 && echo.stdout == payload)

            // saída grande (16 MiB) sem perder bytes
            let big = try await env.client.run(in: id, command: ["sh", "-c", "head -c 16777216 /dev/zero"], timeout: .seconds(60))
            #expect(big.exitCode == 0 && big.stdout.count == 16 << 20)

            // stdin interativo: escreve em pedaços e só então fecha
            let session = try await env.client.startExec(in: id, spec: ExecSpec(command: ["sh", "-c", "while read l; do echo \"got:$l\"; done"], attachStdin: true))
            let reader = Task { () -> String in
                var out = ""
                for try await frame in session.output where frame.kind == .stdout { out += String(decoding: frame.data, as: UTF8.self) }
                return out
            }
            try await session.writeStdin(Data("a\n".utf8))
            try await Task.sleep(for: .milliseconds(150))
            try await session.writeStdin(Data("b\n".utf8))
            session.closeStdin()
            #expect(try await reader.value == "got:a\ngot:b\n")
            #expect(try await session.exitCode() == 0)

            // 6 execs concorrentes no mesmo container
            try await withThrowingTaskGroup(of: String.self) { group in
                for n in 0 ..< 6 { group.addTask { try await env.client.run(in: id, command: ["sh", "-c", "echo n\(n)"]).stdoutString } }
                var all: [String] = []
                for try await line in group { all.append(line) }
                #expect(all.sorted() == (0 ..< 6).map { "n\($0)\n" })
            }

            let probe = try await env.client.startExec(in: id, spec: ExecSpec(command: ["true"]))
            await Evidence.shared.record("spikes/S9/results.json", "hijack_upgrade", "HTTP \(probe.upgradeStatus), Content-Type \(probe.streamContentType ?? "nil")")
            await Evidence.shared.record("spikes/S9/results.json", "runtime", "\(env.runtime.runtime.kind.rawValue) Engine \(env.runtime.version.version) API \(env.runtime.version.apiVersion); cliente usa /\(env.client.apiVersion)")
            await Evidence.shared.record("spikes/S9/results.json", "stdin_half_close", "cat devolve o stdin inteiro e termina: o half-close (shutdown SHUT_WR) chega ao processo pelo proxy do Docker Desktop")
            await Evidence.shared.record("spikes/S9/results.json", "stdout_stderr_multiplexed", "frames de 8 bytes separam stdout e stderr; exit code via exec inspect")
            await Evidence.shared.record("spikes/S9/results.json", "binary_roundtrip", "\(payload.count) bytes de stdin voltam idênticos em stdout; saída de \(big.stdout.count) bytes sem perda")
            await Evidence.shared.record("slice3/T3-01/live-exec.json", "stdin_echo", "ok (\(cat.stdoutString.count) bytes)")
            await Evidence.shared.record("slice3/T3-01/live-exec.json", "split_streams_exit7", "ok")
            await Evidence.shared.record("slice3/T3-01/live-exec.json", "binary_roundtrip", "\(payload.count) bytes identical")
            probe.close()
            await Evidence.shared.record("slice3/T3-01/live-exec.json", "big_output", "\(big.stdout.count) bytes")
        }
    }

    @Test func s9TerminateKillsTheProcessGroupAndEscalatesToSigkill() async throws {
        try await Live.with { env in
            let id = try await env.run(env.spec("kill"))
            func count(_ pattern: String) async throws -> Int {
                // Linhas de `ps` que são exatamente o comando (`sleep 601`): ignora o `sh -c` que o contém.
                let r = try await env.client.run(in: id, command: ["sh", "-c", "ps -o args | grep -cx '\(pattern)' || true"], killableGroup: false)
                return Int(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            }

            // 1) SIGTERM no grupo: o pai (sh) e os dois filhos (sleep 601) morrem; exit 143
            let polite = try await env.client.startExec(in: id, spec: ExecSpec(command: ["sh", "-c", "sleep 601 & sleep 601 & wait"], killableGroup: true))
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await count("sleep 601") == 2)
            let begin = ContinuousClock.now
            try await polite.terminate(grace: .seconds(3))
            let politeCode = try await polite.exitCode()
            let politeElapsed = ContinuousClock.now - begin
            #expect(politeCode == 143 && politeElapsed < .seconds(3), "exit \(politeCode) em \(politeElapsed)")
            #expect(try await count("sleep 601") == 0, "nenhum filho sobrou")
            polite.close()

            // 2) processo que ignora SIGTERM: depois da graça vem o SIGKILL no grupo; exit 137
            let stubborn = try await env.client.startExec(in: id, spec: ExecSpec(command: ["sh", "-c", "trap '' TERM; sleep 602 & sleep 602; wait"], killableGroup: true))
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await count("sleep 602") == 2)
            let begin2 = ContinuousClock.now
            try await stubborn.terminate(grace: .seconds(1))
            let stubbornCode = try await stubborn.exitCode()
            let stubbornElapsed = ContinuousClock.now - begin2
            #expect(stubbornCode == 137 && stubbornElapsed >= .seconds(1) && stubbornElapsed < .seconds(6), "exit \(stubbornCode) em \(stubbornElapsed)")
            #expect(try await count("sleep 602") == 0)
            stubborn.close()

            // 3) prazo de collect(): termina o grupo e lança .timeout
            let hung = try await env.client.startExec(in: id, spec: ExecSpec(command: ["sh", "-c", "sleep 603 & sleep 603"], killableGroup: true))
            do {
                _ = try await hung.collect(timeout: .milliseconds(500))
                Issue.record("deveria estourar o prazo")
            } catch let error as DockerError {
                #expect(error == .timeout(operation: "exec"))
            }
            #expect(try await count("sleep 603") == 0, "prazo estourado encerrou o grupo")

            // 4) cancelamento da Task também encerra o grupo
            let cancellable = try await env.client.startExec(in: id, spec: ExecSpec(command: ["sh", "-c", "sleep 604 & sleep 604"], killableGroup: true))
            let task = Task { try await cancellable.collect(timeout: nil) }
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await count("sleep 604") == 2)
            task.cancel()
            do { _ = try await task.value } catch let error as DockerError { #expect(error == .cancelled) }
            #expect(try await count("sleep 604") == 0, "cancelamento encerrou o grupo")

            await Evidence.shared.record("spikes/S9/results.json", "timeout_and_cancel", "collect(timeout:) e Task.cancel() encerram o grupo (nenhum sleep sobra) e lançam .timeout/.cancelled")
            await Evidence.shared.record("spikes/S9/results.json", "sigterm_group", "exit \(politeCode) in \(politeElapsed)")
            await Evidence.shared.record("spikes/S9/results.json", "sigkill_escalation", "exit \(stubbornCode) in \(stubbornElapsed)")
        }
    }

    // MARK: GC por labels

    @Test func garbageCollectorRemovesOnlyLabelledResourcesAndKeepsNamedProfiles() async throws {
        try await Live.with { env in
            let computer = "c-\(env.runID)"
            var spec = env.spec("gc")
            spec.named = ["\(env.name("eph")):/e"]
            _ = try await env.client.createVolume(name: env.name("eph"), labels: env.baseLabels)
            _ = try await env.client.createVolume(name: env.name("profile"), labels: env.baseLabels.merging([RackyLabel.ephemeral: "false"]) { $1 })
            _ = try await env.client.createNetwork(name: env.name("gcnet"), isInternal: true, labels: env.baseLabels)
            _ = try await env.run(spec)

            let gc = GarbageCollector(client: env.client)
            let inventory = try await gc.inventory(labels: env.labelFilter)
            #expect(Set(inventory.map(\.kind)) == [.container, .network, .volume] && inventory.count == 4)
            #expect(inventory.allSatisfy { $0.computerID == computer })

            // plano: computador desconhecido, run terminado => efêmeros somem sem perguntar; perfil nomeado pede confirmação
            let plan = gc.plan(inventory: inventory, knownComputerIDs: [], finishedComputerIDs: [computer])
            #expect(plan.removeWithoutAsking.count == 3 && plan.needsConfirmation.map(\.name) == [env.name("profile")])

            // fim do run: tudo some, menos o perfil nomeado (CS-180)
            let failures = try await gc.removeComputer(id: computer)
            #expect(failures.isEmpty)
            let rest = try await gc.inventory(labels: env.labelFilter)
            #expect(rest.map(\.name) == [env.name("profile")])
            await Evidence.shared.record("slice3/T3-01/live-gc.json", "removeComputer", "container+rede+volume efêmero removidos; perfil nomeado mantido")
            // `Live.with` limpa o perfil restante ao final (ambos os labels de teste).
        }
    }

    // MARK: Concorrência

    @Test func twentyConcurrentInspectsAndExecsStayResponsive() async throws {
        try await Live.with { env in
            let id = try await env.run(env.spec("conc"))
            let probe = ResponsivenessProbe()
            let probing = Task { await probe.run() }
            try await withThrowingTaskGroup(of: Int.self) { group in
                for n in 0 ..< 20 {
                    group.addTask {
                        if n % 2 == 0 { return try await env.client.inspectContainer(id).state.running ? 1 : 0 }
                        return try await env.client.run(in: id, command: ["sh", "-c", "sleep 0.2; echo ok"]).exitCode == 0 ? 1 : 0
                    }
                }
                var total = 0
                for try await value in group { total += value }
                #expect(total == 20)
            }
            await probe.stop()
            await probing.value
            let gap = await probe.maxGap
            await Evidence.shared.record("slice3/T3-01/live-exec.json", "twenty_parallel_max_gap_ms", "\(gap.components.attoseconds / 1_000_000_000_000_000)")
            #expect(gap < .milliseconds(50))
        }
    }
}

final class ProgressRecorder: @unchecked Sendable {  // SAFETY: acesso serializado por NSLock; só testes.
    private let lock = NSLock()  // LOCK: sem I/O sob o lock; só testes.
    private var items: [ImageProgress] = []

    func add(_ item: ImageProgress) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    private var snapshot: [ImageProgress] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var steps: [(step: Int, total: Int)] { snapshot.compactMap { if case .building(let s, let t) = $0 { (s, t) } else { nil } } }
    var lines: [String] { snapshot.compactMap { if case .log(let l) = $0 { l } else { nil } } }
}

actor EventCollector {
    private(set) var events: [DockerEvent] = []
    func add(_ event: DockerEvent) { events.append(event) }
    var actions: [String] { events.map(\.baseAction) }
}
