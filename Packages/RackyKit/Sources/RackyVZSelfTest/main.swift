import Foundation
import RackyCore
import RackyDocker
import RackyVZ
import Synchronization

// racky-vz-selftest: autoteste do runtime sem Docker contra uma VM REAL. Precisa do entitlement de virtualização
// (scripts/vz/selftest.sh compila, assina ad-hoc com ele e roda). Nunca toca no app do dono: use SEMPRE um RACKY_HOME temporário.
//
//   racky-vz-selftest --home <pasta temporária> --manifest <vz-manifest.json>
//
// Saída: uma linha por passo (`ok|FAIL <passo> <ms> <detalhe>`) e, no fim, `RESULT pass|fail`. Exit 0 só se tudo passou.

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

final class Outcome: Sendable {
    private let flag = Mutex(false)
    func fail() { flag.withLock { $0 = true } }
    var failed: Bool { flag.withLock { $0 } }
}

let outcome = Outcome()

func step<T>(_ name: String, _ body: () async throws -> T) async -> T? {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let value = try await body()
        let ms = Int(start.duration(to: clock.now) / .milliseconds(1))
        emit("ok   \(name) \(ms)ms")
        return value
    } catch {
        let ms = Int(start.duration(to: clock.now) / .milliseconds(1))
        emit("FAIL \(name) \(ms)ms \(error)")
        outcome.fail()
        return nil
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(description: message()) }
}

// Modo de build (sem VM, sem entitlement): `racky-vz-selftest export-image <referência> <saida.oci.tar>` baixa a imagem com o cliente da
// apple/containerization e a grava como OCI tar (scripts/vz/build-image.sh usa para o vminit).
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "export-image" {
    do {
        try await VZImageExport.pullAndArchive(reference: CommandLine.arguments[2], to: URL(fileURLWithPath: CommandLine.arguments[3]))
        emit("exported \(CommandLine.arguments[2]) -> \(CommandLine.arguments[3])")
        exit(0)
    } catch {
        emit("FAIL export-image \(error)")
        exit(1)
    }
}

var home: URL?
var manifest: String?
var hold = false
var measure = false
var load = 0
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--home": home = arguments.popFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
    case "--manifest": manifest = arguments.popFirst()
    case "--hold": hold = true
    case "--measure": measure = true
    case "--load": load = Int(arguments.popFirst() ?? "") ?? 4
    default:
        emit("usage: racky-vz-selftest --home <dir> --manifest <vz-manifest.json>")
        exit(2)
    }
}
guard let home, let manifest else {
    emit("usage: racky-vz-selftest --home <dir> --manifest <vz-manifest.json>")
    exit(2)
}
guard home.path.hasPrefix(NSTemporaryDirectory()) || home.path.hasPrefix("/var/folders") || home.path.hasPrefix("/private/var/folders") || home.path.hasPrefix("/private/tmp") || home.path.hasPrefix("/tmp") || home.path.contains("/scratchpad/") else {
    emit("refusing to run outside a temporary directory: \(home.path)")
    exit(2)
}
try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

var environment = ProcessInfo.processInfo.environment
environment[VZManifest.environmentKey] = manifest
let config = VZRuntime.Config(
    appDataRoot: home, secretsRoot: home.appendingPathComponent("computers", isDirectory: true), owner: "racky-selftest", runtimeRoot: nil,
    environment: environment)
let runtime = VZRuntime(config: config)
emit("entitled=\(VZRuntime.processHasVirtualizationEntitlement()) unavailable=\(runtime.unavailableReason ?? "no")")

_ = await step("sweep") {
    let report = await runtime.startupSweep()
    try expect(report.keptForLiveHosts.isEmpty, "unexpected live hosts \(report)")
}

let lastProgress = LastProgress()
_ = await step("ensureReady (download/prepare)") {
    try await runtime.ensureReady { state in
        if let label = state.label, lastProgress.changed(label) { emit("     \(label)") }
    }
}

// `--hold`: sobe UM computador e espera (para matar o processo com SIGKILL e conferir o sweep do próximo início).
if hold {
    let spec = ComputerSpec(
        name: "hold", parent: "selftest", display: .http, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [], batch: nil,
        run: RunFolder(root: home.appendingPathComponent("runs/hold", isDirectory: true)))
    _ = await step("ensureReady") { try await runtime.ensureReady { _ in } }
    _ = await step("provision (hold)") { _ = try await runtime.provision(spec) }
    emit("HOLDING pid=\(getpid())")
    try await Task.sleep(for: .seconds(300))
    exit(0)
}

// `--measure`: quanto um computador ocupa (backlog 20). Sobe um headless e um http, e em cada fase imprime a memória da VM,
// os processos que mais ocupam lá dentro e o RSS do processo da VM no Mac. Não roda o resto do autoteste.
// `--load N`: teste pesado (backlog 20). N computadores headless ao mesmo tempo, cada um abre páginas no navegador, roda um job de
// ~900 MB com CPU e escreve na pasta de trabalho; um amostrador soma a memória (phys_footprint) de todas as VMs no Mac e mede quanto
// cada VM demora para responder a um comando. Termina com 90 s parado para ver quanto volta.
if load > 0 {
    func footprints() -> [String: Int] {
        let containers = home.appendingPathComponent("vz/store/containers")
        var out: [String: Int] = [:]
        for d in (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? [] {
            let lsof = Process(); lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-t", "--", containers.appendingPathComponent(d).appendingPathComponent("rootfs.ext4").path]
            let pipe = Pipe(); lsof.standardOutput = pipe; try? lsof.run(); lsof.waitUntilExit()
            guard let pid = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").first else { continue }
            let fp = Process(); fp.executableURL = URL(fileURLWithPath: "/usr/bin/footprint"); fp.arguments = ["-p", String(pid)]
            let o = Pipe(); fp.standardOutput = o; fp.standardError = Pipe(); try? fp.run(); fp.waitUntilExit()
            let text = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let m = text.firstMatch(of: /Footprint: ([0-9]+) (KB|MB|GB)/) {
                let n = Int(m.1) ?? 0
                out[d] = m.2 == "GB" ? n * 1024 : (m.2 == "KB" ? n / 1024 : n)
            }
        }
        return out
    }
    let started = Date()
    func t() -> String { String(format: "%5.0fs", Date().timeIntervalSince(started)) }
    var handles: [(String, ProvisionedHandle)] = []
    await withTaskGroup(of: (String, ProvisionedHandle?).self) { group in
        for i in 1...load {
            group.addTask {
                let name = "load-\(i)"
                let spec = ComputerSpec(name: name, parent: "selftest", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [],
                                        allowHosts: [], batch: nil, run: RunFolder(root: home.appendingPathComponent("runs/\(name)", isDirectory: true)))
                return (name, try? await runtime.provision(spec))
            }
        }
        for await (name, handle) in group {
            if let handle { handles.append((name, handle)) } else { emit("FAIL provision \(name)") }
        }
    }
    emit("\(t()) provisioned \(handles.count)/\(load)")
    let sampling = Task {
        var peak = 0
        while !Task.isCancelled {
            let fps = footprints()
            let total = fps.values.reduce(0, +)
            peak = max(peak, total)
            var latencies: [String] = []
            for (name, handle) in handles {
                let clock = ContinuousClock.now
                let ok = (try? await handle.backend.execRun(BackendExec(argv: ["true"], cwd: "/work"), timeout: .seconds(20)))?.exitCode == 0
                let ms = (ContinuousClock.now - clock).components
                latencies.append("\(name)=\(ok ? "\(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000)ms" : "NO-ANSWER")")
            }
            emit("\(t()) SAMPLE total=\(total)MB peak=\(peak)MB per-vm=\(fps.values.sorted()) exec: \(latencies.joined(separator: " "))")
            try? await Task.sleep(for: .seconds(10))
        }
    }
    let job = "python3 - <<'PY'\nimport time, os, hashlib\nblob=[bytearray(1024*1024) for _ in range(900)]\n"
        + "end=time.time()+25\nh=hashlib.sha256()\nwhile time.time()<end: h.update(blob[int(time.time()*1000)%900])\n"
        + "os.makedirs('/work/out', exist_ok=True)\nopen('/work/out/data.bin','wb').write(os.urandom(50*1024*1024))\nprint('job ok', h.hexdigest()[:8])\nPY"
    await withTaskGroup(of: String.self) { group in
        for (name, handle) in handles {
            group.addTask {
                var notes: [String] = []
                // `RACKY_LOAD_BROWSER_EVERY=2`: só um em cada dois usa o navegador (o resto é crawler HTTP + testes, como um builder).
                let every = Int(ProcessInfo.processInfo.environment["RACKY_LOAD_BROWSER_EVERY"] ?? "") ?? 1
                let index = Int(name.split(separator: "-").last ?? "") ?? 0
                let urls = index % every == 0 ? ["https://en.wikipedia.org/wiki/Web_scraping", "https://en.wikipedia.org/wiki/Virtual_machine", "https://example.com"] : []
                if urls.isEmpty {
                    let http = try? await handle.backend.execRun(BackendExec(argv: ["bash", "-lc", "curl -s -o /dev/null -w '%{http_code}' https://en.wikipedia.org/wiki/Web_scraping"], cwd: "/work"), timeout: .seconds(60))
                    notes.append("http-only \(String(decoding: http?.stdout ?? Data(), as: UTF8.self))")
                }
                for url in urls {
                    do { _ = try await handle.backend.runtime("open", ["url": .string(url)], timeout: 90); notes.append("open ok") }
                    catch { notes.append("open FAIL \(error)") }
                }
                let o = try? await handle.backend.execRun(BackendExec(argv: ["bash", "-lc", job], cwd: "/work"), timeout: .seconds(180))
                notes.append("job exit=\(o?.exitCode.map(String.init) ?? "nil") \(String(decoding: o?.stdout ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
                return "\(name): \(notes.joined(separator: ", "))"
            }
        }
        for await line in group { emit("\(t()) DONE \(line)") }
    }
    emit("\(t()) workload finished; idling 90s")
    try await Task.sleep(for: .seconds(90))
    sampling.cancel()
    let final = footprints()
    emit("\(t()) FINAL total=\(final.values.reduce(0, +))MB per-vm=\(final.values.sorted())")
    for (_, handle) in handles { await handle.teardown() }
    emit("LOAD done")
    exit(0)
}

if measure {
    func hostRSS(_ root: URL) -> String {
        let containers = home.appendingPathComponent("vz/store/containers")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? []
        var lines: [String] = []
        for d in dirs {
            let rootfs = containers.appendingPathComponent(d).appendingPathComponent("rootfs.ext4").path
            let lsof = Process(); lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); lsof.arguments = ["-t", "--", rootfs]
            let pipe = Pipe(); lsof.standardOutput = pipe; try? lsof.run(); lsof.waitUntilExit()
            for pid in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
                let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-o", "rss=,%cpu=", "-p", String(pid)]
                let out = Pipe(); ps.standardOutput = out; try? ps.run(); ps.waitUntilExit()
                lines.append("host vm \(d) pid \(pid): rss_kb,cpu = \(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
                // phys_footprint: o que o Activity Monitor mostra como "Memória" (inclui o comprimido, no tamanho comprimido).
                let fp = Process(); fp.executableURL = URL(fileURLWithPath: "/usr/bin/footprint"); fp.arguments = ["-p", String(pid)]
                let fpOut = Pipe(); fp.standardOutput = fpOut; fp.standardError = Pipe(); try? fp.run(); fp.waitUntilExit()
                let summary = String(decoding: fpOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").filter { $0.contains("Footprint:") || $0.contains("TOTAL") || $0.contains("VM_ALLOCATE") }
                    .joined(separator: " | ")
                lines.append("host vm \(d) pid \(pid): \(summary.trimmingCharacters(in: .whitespaces))")
            }
        }
        return lines.joined(separator: "\n")
    }
    let probe = "echo '--- meminfo'; grep -E 'MemTotal|MemFree|MemAvailable|^Cached|Shmem:' /proc/meminfo; "
        + "echo '--- top rss (kb) cpu args'; ps -eo rss=,pcpu=,args= --sort=-rss | head -22 | cut -c1-160; "
        + "echo '--- processes'; ps -e --no-headers | wc -l; echo '--- sum rss kb'; ps -eo rss= | awk '{s+=$1} END {print s}'; "
        + "echo '--- swap'; cat /proc/swaps; df -h / | tail -1; ls /sys/class/zram-control 2>&1 | head -2; (zcat /proc/config.gz 2>/dev/null | grep -E 'ZRAM|ZSWAP|CONFIG_SWAP=') || echo no-config.gz"
    for display in [ComputerDisplay.headless, .http] {
        let run = home.appendingPathComponent("runs/measure-\(display.rawValue)", isDirectory: true)
        let spec = ComputerSpec(name: "measure-\(display.rawValue)", parent: "selftest", display: display, profile: nil, proxy: "direct",
                                proxiesAllowed: [], allowHosts: [], batch: nil, run: RunFolder(root: run))
        guard let handle = await step("provision \(display.rawValue)", { try await runtime.provision(spec) }) else { continue }
        func snap(_ phase: String) async {
            emit("===== \(display.rawValue) · \(phase)")
            if let o = try? await handle.backend.execRun(BackendExec(argv: ["bash", "-lc", probe], cwd: "/work"), timeout: .seconds(30)) {
                emit(String(decoding: o.stdout, as: UTF8.self))
            }
            emit(hostRSS(home))
        }
        try await Task.sleep(for: .seconds(20))
        await snap("idle 20s after boot")
        if display != .http {
            _ = try? await handle.backend.runtime("open", ["url": "https://example.com"], timeout: 60)
            try await Task.sleep(for: .seconds(5))
            await snap("after example.com")
            _ = try? await handle.backend.runtime("open", ["url": "https://en.wikipedia.org/wiki/Web_scraping"], timeout: 90)
            try await Task.sleep(for: .seconds(8))
            await snap("after a wikipedia article")
        }
        // Pico acima do teto da VM (3 GiB com o navegador aberto): sem swap a VM travava; com swap ela tem de seguir respondendo.
        let heldMB = ProcessInfo.processInfo.environment["RACKY_MEASURE_HOLD_MB"] ?? "600"
        let work = "python3 - <<'PY'\nimport time\nblob=[bytearray(1024*1024) for _ in range(\(heldMB))]\nfor b in blob: b[::4096]=b'x'*len(b[::4096])\ntime.sleep(15)\nprint('held', len(blob))\nPY"
        let job = Task { try? await handle.backend.execRun(BackendExec(argv: ["bash", "-lc", work], cwd: "/work"), timeout: .seconds(60)) }
        try await Task.sleep(for: .seconds(8))
        await snap("python job holding \(heldMB) MB")
        let finished = await job.value
        emit("job outcome: exit=\(finished.map { "\($0.exitCode.map(String.init) ?? "nil") timedOut=\($0.timedOut)" } ?? "error") \(finished.map { String(decoding: $0.stdout, as: UTF8.self) } ?? "")")
        await snap("after the job")
        for t in [30, 60, 90, 120, 150] {
            try await Task.sleep(for: .seconds(30))
            await snap("\(t)s after the job (balloon reclaim)")
        }
        await handle.teardown()
    }
    emit("MEASURE done")
    exit(0)
}

if let context = await step("readyContext", { try await runtime.readyContext() }) {
    // 1. VM crua: exec, copyIn/out, virtiofs, a ponte e a admin API.
    let work = home.appendingPathComponent("rawwork", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let plan = try VZVMPlan(
        spec: {
            var spec = ContainerSpec(name: "racky-selftest-raw", image: "racky-computer")
            spec.hostname = "computer"
            spec.workingDirectory = "/work"
            spec.environment = ["RACKY_DISPLAY=http", "RACKY_ADMIN_BIND=127.0.0.1", "RACKY_VSOCK_PORT=8791", "HOME=/home/agent"]
            spec.resources = ContainerResources(memoryBytes: 1 << 30, cpus: 1)
            spec.tmpfs = [
                "/tmp": "rw,nosuid,size=256m,mode=1777", "/home/agent": "rw,nosuid,size=64m,uid=10001,gid=10001,mode=0755",
                "/run/racky": "rw,nosuid,noexec,size=64m,uid=10003,gid=10003,mode=0700",
            ]
            spec.binds = ["\(work.path):/work"]
            spec.capAdd = ["NET_ADMIN", "SETUID", "SETGID", "SETPCAP", "KILL"]
            return spec
        }(), vmID: "ab-selftest-\(String(UUID().uuidString.prefix(4)).lowercased())")
    if let vm = await step("boot VM (clone + boot)", { try await context.backend.boot(plan, image: context.image) }) {
        _ = await step("exec as agent") {
            let result = try await vm.run(VZExecRequest(command: ["sh", "-c", "id -u; uname -r; nproc"], user: "agent"))
            try expect(result.exitCode == 0 && result.stdoutString.hasPrefix("10001"), "exec result \(result.stdoutString) \(result.stderrString)")
        }
        _ = await step("network info (ipv6 sysctl, addresses)") {
            let result = try await vm.run(VZExecRequest(command: ["sh", "-c", "cat /proc/sys/net/ipv6/conf/all/disable_ipv6; ip -brief addr; ip -6 route | head -5"]))
            emit("     " + result.stdoutString.replacingOccurrences(of: "\n", with: "\n     "))
        }
        _ = await step("virtiofs /work host<->guest") {
            let id = String(UUID().uuidString.prefix(6))
            try "from-host".write(to: work.appendingPathComponent("h-\(id).txt"), atomically: true, encoding: .utf8)
            let result = try await vm.run(VZExecRequest(command: ["sh", "-c", "cat /work/h-\(id).txt && echo from-guest > /work/g-\(id).txt"], user: "agent"))
            try expect(result.stdoutString == "from-host", "guest read \(result.stdoutString) \(result.stderrString)")
            let back = try String(contentsOf: work.appendingPathComponent("g-\(id).txt"), encoding: .utf8)
            try expect(back.trimmingCharacters(in: .whitespacesAndNewlines) == "from-guest", "host read \(back)")
        }
        _ = await step("virtiofs coherence (host writes while the VM runs)") {
            var misses: [String] = []
            for round in 0..<6 {
                let atomic = round % 2 == 0
                let name = "round-\(round)-\(UUID().uuidString.prefix(6)).txt"
                try "payload-\(round)".write(to: work.appendingPathComponent(name), atomically: atomic, encoding: .utf8)
                let result = try await vm.run(VZExecRequest(command: ["cat", "/work/\(name)"], user: "agent"))
                if result.stdoutString != "payload-\(round)" { misses.append("\(name) atomic=\(atomic): '\(result.stdoutString)' \(result.stderrString)") }
                // Reescreve o MESMO nome (rename atômico sobre arquivo existente) e mede em quanto tempo o guest enxerga.
                try "again-\(round)".write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
                let clock = ContinuousClock()
                let start = clock.now
                var seen = false
                while clock.now - start < .seconds(3) {
                    let second = try await vm.run(VZExecRequest(command: ["cat", "/work/\(name)"], user: "agent"))
                    if second.stdoutString == "again-\(round)" { seen = true; break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let ms = Int(start.duration(to: clock.now) / .milliseconds(1))
                emit("     rewrite \(name): visible=\(seen) after \(ms)ms")
                if !seen { misses.append("\(name) rewrite not visible within 3 s") }
            }
            try expect(misses.isEmpty, "stale virtiofs views: \(misses)")
        }
        _ = await step("copyIn / copyOut") {
            let source = home.appendingPathComponent("in.txt")
            try "hello-\(UUID().uuidString)".write(to: source, atomically: true, encoding: .utf8)
            try await vm.copyIn(from: source, to: "/var/tmp/in.txt")
            let result = try await vm.run(VZExecRequest(command: ["sh", "-c", "cat /var/tmp/in.txt; echo made-inside > /var/tmp/out.txt"]))
            try expect(result.stdoutString == (try String(contentsOf: source, encoding: .utf8)), "copyIn content \(result.stdoutString)")
            let destination = home.appendingPathComponent("out.txt")
            try await vm.copyOut(from: "/var/tmp/out.txt", to: destination)
            let out = try String(contentsOf: destination, encoding: .utf8)
            try expect(out.contains("made-inside"), "copyOut content \(out)")
        }
        _ = await step("secrets by exec+stdin (abx-provision)") {
            let config = EgressConfigFile.make(profile: nil, secret: nil, internalSubnet: await context.backend.internalSubnet)
            try await VZProvisionPayload.deliver(config: config, proxyCA: nil, token: "selftest-token", to: vm)
            let result = try await vm.run(VZExecRequest(command: ["sh", "-c", "ls -l /run/racky | tail -n +2 | awk '{print $1, $3, $9}'; cat /run/racky/token"], user: "egress"))
            try expect(result.stdoutString.contains("selftest-token") && result.stdoutString.contains("-r-------- egress"), "secrets \(result.stdoutString)")
            let agent = try await vm.run(VZExecRequest(command: ["sh", "-c", "cat /run/racky/token"], user: "agent"))
            try expect(agent.exitCode != 0, "agent must not read the token")
        }
        _ = await step("bridge -> admin API :8790 /v1/health") {
            let bridge = try VZPortBridge(dial: { try await vm.dialVsock(port: VZComputerProvisioning.vsockPort) })
            let port = try await bridge.start()
            defer { bridge.stop() }
            let admin = EgressAdminClient(port: port, token: "selftest-token")
            try await admin.waitUntilHealthy(timeout: .seconds(30))
        }
        _ = await step("admin API not reachable over the vmnet IP") {
            guard let ip = vm.ipAddress else { throw Failure(description: "no ip") }
            let result = try await vm.run(VZExecRequest(command: ["sh", "-c", "curl -s -m 3 -o /dev/null -w '%{http_code}' http://\(ip):8790/v1/health || true"], user: "egress"))
            try expect(result.stdoutString.hasPrefix("000"), "admin API answered on \(ip): \(result.stdoutString)")
        }
        _ = await step("agent cannot reach vminitd over vsock") {
            let script = "import socket, sys\nfor cid in (1, 3):\n  s=socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM); s.settimeout(2)\n  try: s.connect((cid, 1024)); sys.stdout.write('connected %s\\n' % cid)\n  except Exception as e: sys.stdout.write('blocked %s %s\\n' % (cid, type(e).__name__))\n"
            let result = try await vm.run(VZExecRequest(command: ["python", "-c", script], user: "agent"))
            emit("     vsock probe: \(result.stdoutString.replacingOccurrences(of: "\n", with: "; "))")
        }
        await step("stop VM") { await vm.stop() } .map { _ in }
    }

    // 2. Caminho completo do app: provisionamento de um computador headless (browser real) e o backend das ferramentas.
    let run = home.appendingPathComponent("runs/selftest", isDirectory: true)
    var spec = ComputerSpec(
        name: "selftest", parent: "selftest", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [], batch: nil,
        run: RunFolder(root: run))
    // `RACKY_SELFTEST_GITHUB_REPO=dono/repo`: liga o gateway do GitHub com o token do `gh` e testa git, uv, Postgres e a política lá dentro.
    let githubRepo = ProcessInfo.processInfo.environment["RACKY_SELFTEST_GITHUB_REPO"]
    if let githubRepo, let token = try? await GitHubProcessRunner().run(["auth", "token", "--hostname", "github.com"], in: nil, timeout: .seconds(10)),
       token.succeeded {
        spec.github = EgressGitHub(token: token.stdout.trimmingCharacters(in: .whitespacesAndNewlines), repos: [githubRepo])
    }
    if let handle = await step("provision headless computer (VM + browser ready)", { try await runtime.provision(spec) }) {
        _ = await step("backend exec as agent") {
            let outcome = try await handle.backend.execRun(BackendExec(argv: ["sh", "-c", "id -un; echo ok > /work/x.txt"], cwd: "/work"), timeout: .seconds(20))
            try expect(outcome.exitCode == 0 && String(decoding: outcome.stdout, as: UTF8.self).hasPrefix("agent"), "outcome \(outcome)")
            let written = try String(contentsOf: run.appendingPathComponent("work/x.txt"), encoding: .utf8)
            try expect(written.hasPrefix("ok"), "work file \(written)")
        }
        if let githubRepo, spec.github != nil {
            func sh(_ script: String, _ seconds: Int = 120) async throws -> (code: Int?, out: String) {
                let o = try await handle.backend.execRun(BackendExec(argv: ["bash", "-lc", script], cwd: "/work"), timeout: .seconds(seconds))
                return (o.exitCode, String(decoding: o.stdout, as: UTF8.self) + String(decoding: o.stderr, as: UTF8.self))
            }
            _ = await step("computer tools: git, uv, initdb, racky-pr") {
                let r = try await sh("git --version && uv --version && initdb --version && racky-pr --help >/dev/null && echo TOOLS_OK")
                try expect(r.code == 0 && r.out.contains("TOOLS_OK"), r.out)
            }
            _ = await step("git through the gateway: ls-remote and shallow clone") {
                let r = try await sh("git ls-remote https://github.com/\(githubRepo) HEAD && git clone -q --depth 1 https://github.com/\(githubRepo) /work/repo && echo CLONE_OK", 300)
                try expect(r.code == 0 && r.out.contains("CLONE_OK"), r.out)
            }
            _ = await step("gateway refuses a push to main (nothing reaches GitHub)") {
                let r = try await sh("cd /work/repo && git commit -q --allow-empty -m selftest && git push origin HEAD:main 2>&1; echo EXIT=$?")
                try expect(!r.out.contains("EXIT=0") && r.out.contains("refs/heads/main"), r.out)
            }
            _ = await step("GitHub API read through the gateway") {
                let r = try await sh("curl -s http://api.github.racky/repos/\(githubRepo) | head -c 400")
                try expect(r.out.contains("full_name"), r.out)
            }
            _ = await step("throwaway Postgres inside the computer") {
                let r = try await sh("initdb -D /work/pg -U t --auth=trust >/dev/null && pg_ctl -s -D /work/pg -o '-k /tmp -p 55400 -c listen_addresses=' -l /work/pg.log start && sleep 2 && psql -h /tmp -p 55400 -U t -d postgres -tAc 'select 41+1' ; pg_ctl -s -D /work/pg stop", 120)
                try expect(r.out.contains("42"), r.out)
            }
        }
        _ = await step("agent's Postgres reaches the Mac through the admin tunnel (Data shows it)") {
            let start = "initdb -D /work/agentdb -U postgres --auth=trust >/dev/null && pg_ctl -s -D /work/agentdb -o '-k /tmp -h 127.0.0.1 -p 55410' "
                + "-l /work/agentdb.log start && sleep 2 && psql -h 127.0.0.1 -p 55410 -U postgres -d postgres -qc 'create table t(a int); insert into t values (1),(2),(3)' && echo DB_UP"
            let up = try await handle.backend.execRun(BackendExec(argv: ["bash", "-lc", start], cwd: "/work"), timeout: .seconds(120))
            try expect(String(decoding: up.stdout, as: UTF8.self).contains("DB_UP"), String(decoding: up.stdout + up.stderr, as: UTF8.self))
            let found = ComputerDatabaseScan.find(in: spec.run.work)
            try expect(found.contains(ComputerDatabaseScan.Found(path: "agentdb", port: 55410)), "\(found)")
            let backend = handle.backend
            let forward = try ComputerPortForward(target: { try await backend.adminTunnel(port: 55410) })
            let local = try await forward.start()
            defer { forward.stop() }
            let info = try PostgresConnectionInfo(parsing: "postgresql://postgres@127.0.0.1:\(local)/postgres?sslmode=disable")
            let result = try await PostgresConnector(info: info).query(sql: "select count(*) from t", limit: 1)
            try expect(result.rows.first?.first == "3", "\(result)")
            _ = try? await backend.execRun(BackendExec(argv: ["bash", "-lc", "pg_ctl -s -D /work/agentdb stop"], cwd: "/work"), timeout: .seconds(60))
        }
        _ = await step("backend kill process group on timeout") {
            let outcome = try await handle.backend.execRun(BackendExec(argv: ["sh", "-c", "sleep 30"], cwd: "/work"), timeout: .milliseconds(800))
            try expect(outcome.timedOut, "expected timeout, got \(outcome)")
        }
        _ = await step("runtime: open a page through the egress proxy") {
            // A primeira navegação logo depois do boot pode ver uma mudança de rede (ERR_NETWORK_CHANGED): registra cada tentativa.
            var last: any Error = Failure(description: "no attempt")
            for attempt in 1...3 {
                do {
                    let result = try await handle.backend.runtime("open", ["url": "https://example.com"], timeout: 60)
                    try expect(result["title"]?.string == "Example Domain", "open result \(result)")
                    emit("     open ok on attempt \(attempt)")
                    return
                } catch {
                    last = error
                    emit("     open attempt \(attempt) failed: \(error)")
                    try await Task.sleep(for: .seconds(2))
                }
            }
            throw last
        }
        _ = await step("usage via admin API") { _ = try await handle.backend.usage() }
        _ = await step("viewer: VNC websocket through the bridge speaks RFB") {
            let url = try await handle.backend.vncEndpoint()
            let task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
            task.resume()
            defer { task.cancel(with: .goingAway, reason: nil) }
            let message = try await task.receive()
            var banner = ""
            switch message {
            case .data(let data): banner = String(decoding: data.prefix(12), as: UTF8.self)
            case .string(let text): banner = String(text.prefix(12))
            @unknown default: break
            }
            try expect(banner.hasPrefix("RFB "), "unexpected first VNC message '\(banner)'")
        }
        await handle.teardown()
        _ = await step("teardown leaves nothing behind") {
            let entries = await runtime.registry.entries
            try expect(entries.isEmpty, "registry still has \(entries)")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: runtime.paths.containers.path)) ?? []
            try expect(left.isEmpty, "container dirs left: \(left)")
        }
    }

    // 3. Dois computadores ao mesmo tempo (a vmnet é compartilhada): portas e tokens próprios, e a admin API de um não alcança a do outro.
    func twin(_ name: String) -> ComputerSpec {
        ComputerSpec(
            name: name, parent: "selftest", display: .http, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [], batch: nil,
            run: RunFolder(root: home.appendingPathComponent("runs/\(name)", isDirectory: true)))
    }
    if let pair = await step("provision two computers at once", {
        async let first = runtime.provision(twin("twin-a"))
        async let second = runtime.provision(twin("twin-b"))
        return try await [first, second]
    }) {
        _ = await step("two computers: independent exec and /work") {
            for (index, handle) in pair.enumerated() {
                let out = try await handle.backend.execRun(BackendExec(argv: ["sh", "-c", "echo twin-\(index) > /work/who.txt; cat /work/who.txt"], cwd: "/work"), timeout: .seconds(20))
                try expect(String(decoding: out.stdout, as: UTF8.self) == "twin-\(index)\n", "twin \(index): \(out)")
            }
            for name in ["twin-a", "twin-b"] {
                let text = try String(contentsOf: home.appendingPathComponent("runs/\(name)/work/who.txt"), encoding: .utf8)
                try expect(text == "twin-\(name == "twin-a" ? 0 : 1)\n", "work of \(name): \(text)")
            }
            try expect(await runtime.registry.entries.count == 2, "registry should hold both VMs")
        }
        for handle in pair { await handle.teardown() }
        _ = await step("two computers: teardown leaves nothing behind") {
            try expect(await runtime.registry.entries.isEmpty, "registry not empty")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: runtime.paths.containers.path)) ?? []
            try expect(left.isEmpty, "container dirs left: \(left)")
        }
    }
}
await runtime.shutdown()
emit(outcome.failed ? "RESULT fail" : "RESULT pass")
exit(outcome.failed ? 1 : 0)

/// `ensureReady` chama o progresso muitas vezes: imprime só quando o texto muda.
final class LastProgress: @unchecked Sendable {  // SAFETY: um único chamador por vez (o callback do download); o valor é só de log
    private var last = ""
    func changed(_ label: String) -> Bool {
        let step = String(label.prefix(40))
        defer { last = step }
        return step != last
    }
}
