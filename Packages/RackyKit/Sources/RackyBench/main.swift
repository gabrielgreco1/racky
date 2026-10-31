import RackyCore
import RackyPlatform
import RackyProtocol
import RackyUI
import AppKit
import Darwin
import Foundation
import Synchronization
import SwiftTerm

// racky-bench: mede os orçamentos AR-702 (latência de eco), AR-703 (vazão e hitch do main) e AR-704/AR-706
// (memória por terminal) com o `rackyd` real e `TerminalSurfaceView` real (Metal). Chamado por scripts/bench.sh.
// Uso: racky-bench --out <arquivo.json> [--quick] [--no-present]

struct Options {
    var out: String?
    var quick = false
    var measurePresent = true
    /// `--ten`: só os cenários de 10 sessões em paralelo (T2-11, AC-608/609): carga alta, 4 visíveis + 6 ocultas e ociosas.
    var ten = false
    /// Duração de cada janela de CPU, em segundos (padrão 30; `--quick` 8; ocioso usa o dobro, mínimo 60 s fora do `--quick`).
    var seconds: Int?
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out": o.out = it.next()
        case "--quick": o.quick = true
        case "--no-present": o.measurePresent = false
        case "--ten": o.ten = true
        case "--seconds": o.seconds = it.next().flatMap(Int.init)
        default:
            FileHandle.standardError.write(Data("racky-bench: opção desconhecida \(a)\n".utf8))
            exit(64)
        }
    }
    return o
}

// MARK: Utilidades

nonisolated func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

nonisolated struct Stats: Codable {
    var count: Int
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double
    var mean: Double

    init(_ values: [Double]) {
        let s = values.sorted()
        func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[Swift.max(0, Swift.min(s.count - 1, Int((Double(s.count) * p).rounded(.up)) - 1))] }
        count = s.count
        p50 = pct(0.50)
        p95 = pct(0.95)
        p99 = pct(0.99)
        max = s.last ?? 0
        mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
    }
}

func physFootprint(pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? info.ri_phys_footprint : 0
}

func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: Daemon

nonisolated final class Daemon: Sendable {
    private let child = ChildDaemon(home: ChildDaemon.temporaryHome(prefix: "abb"))
    var socket: String { child.socketPath }
    var pid: Int32 { child.pid }

    func start() async throws {
        guard let exe = ChildDaemon.defaultExecutable(relativeTo: URL(fileURLWithPath: CommandLine.arguments[0])) else {
            throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "rackyd não encontrado"])
        }
        try child.start(executable: exe)
        let client = PTYClient(configuration: PTYClientConfiguration(socketPath: socket, build: "bench"))
        for _ in 0 ..< 100 {
            if (try? await client.start()) != nil {
                await client.stop()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "rackyd não subiu em \(exe.path)"])
    }

    func stop() {
        child.terminate()
        child.removeHome()
    }
}

// MARK: Pane de teste

nonisolated final class Counter: Sendable {
    private let n = Mutex(0)
    func add(_ k: Int) { n.withLock { $0 += k } }
    var value: Int { n.withLock { $0 } }
}

@MainActor
final class Pane {
    let host: TerminalHostView
    let window: NSWindow
    let binding: TerminalSessionBinding
    let sessionID: SessionID
    let echo = EchoWaiter()
    let fedBytes = Counter()
    var t0: UInt64 = 0

    init(client: PTYClient, argv: [String], size: NSSize = NSSize(width: 580, height: 400), index: Int) async throws {
        host = TerminalHostView(terminalID: "bench-\(index)")
        window = NSWindow(contentRect: NSRect(x: CGFloat(40 + index * 30), y: CGFloat(40 + index * 30), width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        host.surface.suspendsRenderingWhenNotVisible = false
        let dims = host.surface.terminalDimensions
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "HOME": NSHomeDirectory()]
        env["AB_BENCH"] = "1"
        let create = CreateRequest(
            sessionID: SessionID(), argv: argv, cwd: "/tmp", env: env, cols: UInt16(dims.cols), rows: UInt16(dims.rows), ringBytes: 4 << 20,
            coldLog: false, owner: SessionOwner(terminalID: "bench-\(index)", runID: "bench"))
        let created = try await client.create(create)
        sessionID = created.session.sessionID
        binding = TerminalSessionBinding(client: client, sessionID: sessionID, host: host)
        let echo = self.echo
        let fed = self.fedBytes
        binding.frameObserver.set { data in
            fed.add(data.count)
            echo.observe(data)
        }
        try await binding.start()
    }

    func close() {
        binding.stop()
        window.orderOut(nil)
    }
}

/// Espera o eco de um byte no stream alimentado ao emulador.
nonisolated final class EchoWaiter: Sendable {
    private struct State {
        var expected: UInt8 = 0
        var continuation: CheckedContinuation<UInt64, Never>?
    }
    private let state = Mutex(State())

    func arm(_ byte: UInt8, _ continuation: CheckedContinuation<UInt64, Never>) {
        state.withLock {
            $0.expected = byte
            $0.continuation = continuation
        }
    }

    func observe(_ data: Data) {
        let cont: CheckedContinuation<UInt64, Never>? = state.withLock { s in
            guard s.continuation != nil, data.contains(s.expected) else { return nil }
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.resume(returning: nowNs())
    }

    func timeout() {
        let cont = state.withLock { s -> CheckedContinuation<UInt64, Never>? in
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.resume(returning: 0)
    }
}

/// Último quadro apresentado pelo renderer (callback estático do SwiftTerm).
nonisolated final class PresentClock: Sendable {
    static let shared = PresentClock()
    private struct State {
        var last: UInt64 = 0
        var recording = false
        var gaps: [Double] = []
        var frames = 0
    }
    private let state = Mutex(State())
    func install() {
        TerminalView.onFramePresented = {
            let now = nowNs()
            PresentClock.shared.state.withLock { s in
                if s.recording {
                    if s.last != 0 { s.gaps.append(Double(now - s.last) / 1e6) }
                    s.frames += 1
                }
                s.last = now
            }
        }
    }
    func lastPresent() -> UInt64 { state.withLock { $0.last } }
    /// Intervalos entre quadros apresentados (de qualquer pane) enquanto grava: tempo de quadro e taxa agregada.
    func startRecording() { state.withLock { $0.recording = true; $0.gaps = []; $0.frames = 0; $0.last = 0 } }
    func stopRecording() -> (gaps: [Double], frames: Int) { state.withLock { s in s.recording = false; return (s.gaps, s.frames) } }
}

/// Mede um monitor de stall do main thread: intervalos entre disparos de um timer de 2 ms.
@MainActor
final class MainStallMonitor {
    private var timer: DispatchSourceTimer?
    private var lastFire = nowNs()
    private(set) var gaps: [Double] = []

    func start() {
        lastFire = nowNs()
        gaps = []
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(100))
        t.setEventHandler { [self] in
            let n = nowNs()
            gaps.append(Double(n - lastFire) / 1e6)
            lastFire = n
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
    var maxGapMs: Double { gaps.max() ?? 0 }
}

// MARK: Cenários

/// Digita `count` teclas (ping-pong) no pane de `cat` e mede tecla -> emulador (e -> quadro apresentado).
@MainActor
func measureEcho(on pane: Pane, count: Int, interval: Duration = .milliseconds(20), present: Bool) async -> (fed: [Double], presented: [Double], timeouts: Int) {
    var fed: [Double] = []
    var presented: [Double] = []
    var timeouts = 0
    let letters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    for i in 0 ..< count {
        let ch = letters[i % letters.count]
        let echo = pane.echo
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { echo.timeout() }
        }
        let t1: UInt64 = await withCheckedContinuation { continuation in
            echo.arm(ch, continuation)
            pane.t0 = nowNs()
            pane.host.surface.send(data: [ch][...])
        }
        timeoutTask.cancel()
        if t1 == 0 {
            timeouts += 1
            continue
        }
        fed.append(Double(t1 - pane.t0) / 1e6)
        if present {
            // Próximo quadro apresentado depois da atualização do emulador.
            var t2: UInt64 = 0
            for _ in 0 ..< 200 {
                let p = PresentClock.shared.lastPresent()
                if p > t1 { t2 = p; break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            if t2 > 0 { presented.append(Double(t2 - pane.t0) / 1e6) }
        }
        try? await Task.sleep(for: interval)
    }
    return (fed, presented, timeouts)
}

struct EchoResult: Codable {
    var keysSent: Int
    var timeouts: Int
    var keyToEmulatorMs: Stats
    var keyToPresentedFrameMs: Stats?
}

func echoResult(_ r: (fed: [Double], presented: [Double], timeouts: Int), sent: Int, present: Bool) -> EchoResult {
    EchoResult(keysSent: sent, timeouts: r.timeouts, keyToEmulatorMs: Stats(r.fed), keyToPresentedFrameMs: present && !r.presented.isEmpty ? Stats(r.presented) : nil)
}

func makeBigFile(megabytes: Int) throws -> URL {
    var chunk = Data()
    var i = 0
    while chunk.count < 1 << 20 {
        chunk.append(Data("\u{1b}[3\(i % 8)mline \(i) \u{1b}[1;4\(i % 8)m the quick brown fox jumps over the lazy dog 0123456789\u{1b}[0m\r\n".utf8))
        i += 1
    }
    let url = URL(fileURLWithPath: "/tmp/ab-bench-\(UInt32.random(in: 0 ... 0xFFFFFF)).ansi")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    for _ in 0 ..< megabytes { try h.write(contentsOf: chunk) }
    try h.close()
    return url
}

@MainActor
func runAll(_ opts: Options) async throws -> [String: Any] {
    let daemon = Daemon()
    try await daemon.start()
    defer { daemon.stop() }
    let client = PTYClient(configuration: PTYClientConfiguration(socketPath: daemon.socket, build: "bench"))
    try await client.start()
    if opts.measurePresent { PresentClock.shared.install() }
    let keys = opts.quick ? 60 : 300
    let enc = JSONEncoder()
    func json<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: enc.encode(v))) ?? [:] }
    var report: [String: Any] = [:]
    var failures: [String] = []

    // D. Memória por terminal (AR-704), primeiro: o processo ainda está limpo: N panes com 5 mil linhas de scrollback preenchidas.
    log("bench: memória")
    do {
        let n = opts.quick ? 4 : 8
        try await Task.sleep(for: .seconds(1))
        let appBefore = physFootprint(pid: getpid())
        let daemonBefore = physFootprint(pid: daemon.pid)
        var panes: [Pane] = []
        let fill = "yes 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | head -n 6000; sleep 600"
        for i in 0 ..< n { panes.append(try await Pane(client: client, argv: ["/bin/sh", "-c", fill], index: i)) }
        try await Task.sleep(for: .seconds(4))
        let appAfter = physFootprint(pid: getpid())
        let daemonAfter = physFootprint(pid: daemon.pid)
        let perView = (mib(appAfter) - mib(appBefore)) / Double(n)
        let perSession = (mib(daemonAfter) - mib(daemonBefore)) / Double(n)
        report["AR-704"] = [
            "panes": n, "scrollbackLines": 5000, "paneSizePt": "580x400 (2x2 numa janela de 1440 com sidebar de 280)",
            "appFootprintMiBBefore": mib(appBefore), "appFootprintMiBAfter": mib(appAfter), "perViewMiB": perView,
            "daemonFootprintMiBBefore": mib(daemonBefore), "daemonFootprintMiBAfter": mib(daemonAfter), "perDaemonSessionMiB": perSession,
        ] as [String: Any]
        if perView > 30 { failures.append("AR-704: view de terminal \(String(format: "%.1f", perView)) MiB > 30 MiB") }
        if perSession > 25 { failures.append("AR-704: sessão no daemon \(String(format: "%.1f", perSession)) MiB > 25 MiB") }
        for p in panes {
            try? await client.kill(sessionID: p.sessionID, mode: .force)
            try? await Task.sleep(for: .milliseconds(300))
            p.close()
        }
    }
    // A. AR-702 em repouso: 1 pane `cat`.
    log("bench: eco em repouso (\(keys) teclas)")
    do {
        let pane = try await Pane(client: client, argv: ["/bin/cat"], index: 0)
        try await Task.sleep(for: .milliseconds(600))  // assenta o redraw forçado do attach
        _ = await measureEcho(on: pane, count: 20, present: false)  // aquecimento
        let r = await measureEcho(on: pane, count: keys, present: opts.measurePresent)
        let res = echoResult(r, sent: keys, present: opts.measurePresent)
        report["AR-702-idle"] = json(res)
        let p95 = res.keyToPresentedFrameMs?.p95 ?? res.keyToEmulatorMs.p95
        report["AR-702-idle-p95-ms"] = p95
        if p95 > 16 || res.timeouts > 0 { failures.append("AR-702 repouso: p95 \(String(format: "%.1f", p95)) ms > 16 ms (ou eco perdido)") }
        try? await client.kill(sessionID: pane.sessionID, mode: .force)
        try? await Task.sleep(for: .milliseconds(300))
        pane.close()
    }

    // B. AR-702 com 4 panes visíveis despejando saída (3 flooders) e eco no quarto: `yes` (AC-T07) e `cat` de 50 MB em laço.
    let floodFile = try makeBigFile(megabytes: 50)
    defer { try? FileManager.default.removeItem(at: floodFile) }
    for (name, command) in [
        ("yes", "yes | head -c 400000000"),
        ("cat", "while :; do cat \(floodFile.path); done"),
    ] {
        log("bench: eco com 4 panes (3 x \(name)) (\(keys) teclas)")
        var flooders: [Pane] = []
        for i in 1 ... 3 { flooders.append(try await Pane(client: client, argv: ["/bin/sh", "-c", command], index: i)) }
        let pane = try await Pane(client: client, argv: ["/bin/cat"], index: 0)
        try await Task.sleep(for: .milliseconds(800))
        let fedBefore = flooders.map { $0.fedBytes.value }
        let started = nowNs()
        let stall = MainStallMonitor()
        stall.start()
        let r = await measureEcho(on: pane, count: keys, present: opts.measurePresent)
        stall.stop()
        let seconds = Double(nowNs() - started) / 1e9
        let res = echoResult(r, sent: keys, present: opts.measurePresent)
        let rates = zip(flooders, fedBefore).map { Double($0.fedBytes.value - $1) / 1_048_576 / seconds }
        report["AR-702-4panes-\(name)"] = [
            "echo": json(res), "floodersMiBPerSecond": rates, "mainMaxGapMs": stall.maxGapMs, "mainGapP99Ms": Stats(stall.gaps).p99,
        ] as [String: Any]
        let p95 = res.keyToPresentedFrameMs?.p95 ?? res.keyToEmulatorMs.p95
        report["AR-702-loaded-\(name)-p95-ms"] = p95
        if p95 > 33 || res.timeouts > 0 { failures.append("AR-702 4 panes (\(name)): p95 \(String(format: "%.1f", p95)) ms > 33 ms (ou eco perdido)") }
        if stall.maxGapMs > 100 { failures.append("AR-703 4 panes (\(name)): main parado \(String(format: "%.0f", stall.maxGapMs)) ms > 100 ms") }
        for p in flooders + [pane] {
            try? await client.kill(sessionID: p.sessionID, mode: .force)
            try? await Task.sleep(for: .milliseconds(300))
            p.close()
        }
    }

    // C. AR-703: `cat` de 50 MB num pane, hitch do main e eco em outro pane.
    log("bench: cat de 50 MB")
    do {
        let megabytes = opts.quick ? 10 : 50
        let file = try makeBigFile(megabytes: megabytes)
        defer { try? FileManager.default.removeItem(at: file) }
        let probe = try await Pane(client: client, argv: ["/bin/cat"], index: 1)
        try await Task.sleep(for: .milliseconds(600))
        let stall = MainStallMonitor()
        stall.start()
        let t0 = nowNs()
        let big = try await Pane(client: client, argv: ["/bin/cat", file.path], index: 0)
        let target = megabytes << 20
        let echoTask = Task { @MainActor in await measureEcho(on: probe, count: keys / 2, present: opts.measurePresent) }
        var done = false
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if big.fedBytes.value >= target { done = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = Double(nowNs() - t0) / 1e9
        let r = await echoTask.value
        stall.stop()
        let res = echoResult(r, sent: keys / 2, present: opts.measurePresent)
        report["AR-703-cat"] = [
            "megabytes": megabytes, "completed": done, "seconds": elapsed, "MiBPerSecond": Double(megabytes) / elapsed,
            "mainMaxGapMs": stall.maxGapMs, "mainGapP99Ms": Stats(stall.gaps).p99,
            "otherPaneEcho": json(res),
        ] as [String: Any]
        let p95 = res.keyToPresentedFrameMs?.p95 ?? res.keyToEmulatorMs.p95
        if stall.maxGapMs > 100 { failures.append("AR-703: main parado \(String(format: "%.0f", stall.maxGapMs)) ms > 100 ms") }
        if p95 > 33 || res.timeouts > 0 { failures.append("AR-703: eco em outro pane p95 \(String(format: "%.1f", p95)) ms > 33 ms") }
        if !done { failures.append("AR-703: cat de \(megabytes) MB não terminou em 120 s") }
        for p in [big, probe] {
            try? await client.kill(sessionID: p.sessionID, mode: .force)
            try? await Task.sleep(for: .milliseconds(300))
            p.close()
        }
    }

    await client.stop()

    report["failures"] = failures
    report["passed"] = failures.isEmpty
    return report
}


// MARK: 10 sessões em paralelo (T2-11)

/// CPU acumulada (usuário + sistema) de um processo, em nanossegundos.
func cpuNanoseconds(pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return 0 }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
}

struct LoadSample {
    var appCPUPercent: Double
    var daemonCPUPercent: Double
    var appFootprintMiB: Double
    var daemonFootprintMiB: Double
    var seconds: Double
}

/// Média de CPU de um processo numa janela (percentual de UM núcleo) e a pegada no fim.
@MainActor
func sampleLoad(daemonPID: Int32, seconds: Int) async -> LoadSample {
    let app0 = cpuNanoseconds(pid: getpid()), d0 = cpuNanoseconds(pid: daemonPID), t0 = nowNs()
    try? await Task.sleep(for: .seconds(seconds))
    let app1 = cpuNanoseconds(pid: getpid()), d1 = cpuNanoseconds(pid: daemonPID), t1 = nowNs()
    let wall = Double(t1 - t0)
    return LoadSample(
        appCPUPercent: Double(app1 - app0) / wall * 100, daemonCPUPercent: Double(d1 - d0) / wall * 100,
        appFootprintMiB: mib(physFootprint(pid: getpid())), daemonFootprintMiB: mib(physFootprint(pid: daemonPID)), seconds: wall / 1e9)
}

func loadJSON(_ l: LoadSample) -> [String: Any] {
    ["appCPUPercentOfOneCore": l.appCPUPercent, "daemonCPUPercentOfOneCore": l.daemonCPUPercent, "appFootprintMiB": l.appFootprintMiB,
     "daemonFootprintMiB": l.daemonFootprintMiB, "windowSeconds": l.seconds]
}

@MainActor
func closeAll(_ panes: [Pane], hidden: [SessionID], client: PTYClient) async {
    for p in panes {
        try? await client.kill(sessionID: p.sessionID, mode: .force)
        p.close()
    }
    for id in hidden { try? await client.kill(sessionID: id, mode: .force) }
    try? await Task.sleep(for: .milliseconds(500))
}

/// Sessão só no daemon (pane oculto: sem view e sem anexo, AR-406): o app não recebe nenhum byte dela.
@MainActor
func createHidden(client: PTYClient, argv: [String], index: Int) async throws -> SessionID {
    var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "HOME": NSHomeDirectory()]
    env["AB_BENCH"] = "1"
    let create = CreateRequest(
        sessionID: SessionID(), argv: argv, cwd: "/tmp", env: env, cols: 100, rows: 30, ringBytes: 4 << 20, coldLog: false,
        owner: SessionOwner(terminalID: "bench-hidden-\(index)", runID: "bench"))
    return try await client.create(create).session.sessionID
}

let floodCommand = "yes 'the quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ'"

/// Latência de eco no pane `cat` (11º) com as outras sessões ativas, tempo de quadro e parada do main na janela.
@MainActor
func measureUnderLoad(
    probe: Pane, flooders: [Pane], daemonPID: Int32, seconds: Int, keys: Int, present: Bool
) async -> [String: Any] {
    let stall = MainStallMonitor()
    stall.start()
    if present { PresentClock.shared.startRecording() }
    let fedBefore = flooders.map { $0.fedBytes.value }
    let started = nowNs()
    async let load = sampleLoad(daemonPID: daemonPID, seconds: seconds)
    // o eco roda durante a janela de CPU (uma tecla a cada 40 ms, depois espera o resto da janela)
    let echo = await measureEcho(on: probe, count: keys, interval: .milliseconds(40), present: present)
    let sample = await load
    stall.stop()
    let elapsed = Double(nowNs() - started) / 1e9
    let frames = present ? PresentClock.shared.stopRecording() : (gaps: [], frames: 0)
    let rates = zip(flooders, fedBefore).map { Double($0.fedBytes.value - $1) / 1_048_576 / elapsed }
    let res = echoResult(echo, sent: keys, present: present)
    var out: [String: Any] = [
        "load": loadJSON(sample), "echo": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(res))) ?? [:],
        "mainMaxGapMs": stall.maxGapMs, "mainGapP99Ms": Stats(stall.gaps).p99, "floodersMiBPerSecond": rates,
        "appReceivedMiBPerSecondTotal": rates.reduce(0, +),
    ]
    if present {
        let g = Stats(frames.gaps)
        out["frames"] = ["presentedTotal": frames.frames, "framesPerSecondAggregate": Double(frames.frames) / elapsed, "gapMs": ["p50": g.p50, "p95": g.p95, "p99": g.p99, "max": g.max]]
    }
    return out
}

@MainActor
func runTen(_ opts: Options) async throws -> [String: Any] {
    let daemon = Daemon()
    try await daemon.start()
    defer { daemon.stop() }
    let client = PTYClient(configuration: PTYClientConfiguration(socketPath: daemon.socket, build: "bench"))
    try await client.start()
    if opts.measurePresent { PresentClock.shared.install() }
    let seconds = opts.seconds ?? (opts.quick ? 8 : 30)
    let idleSeconds = opts.seconds ?? (opts.quick ? 10 : 60)
    let keys = opts.quick ? 80 : 300
    var report: [String: Any] = [:]
    var failures: [String] = []

    // A. 10 sessões com saída alta, todas com view anexada (pior caso) + pane de eco.
    log("bench: 10 flooders anexados + eco (\(seconds) s)")
    do {
        var flooders: [Pane] = []
        for i in 1 ... 10 { flooders.append(try await Pane(client: client, argv: ["/bin/sh", "-c", floodCommand], index: i)) }
        let probe = try await Pane(client: client, argv: ["/bin/cat"], index: 0)
        try await Task.sleep(for: .seconds(2))
        _ = await measureEcho(on: probe, count: 10, present: false)
        let result = await measureUnderLoad(probe: probe, flooders: flooders, daemonPID: daemon.pid, seconds: seconds, keys: keys, present: opts.measurePresent)
        report["AC-608-10flood-all-attached"] = result
        let echo = (result["echo"] as? [String: Any])
        let p95 = ((echo?["keyToPresentedFrameMs"] as? [String: Any])?["p95"] as? Double) ?? ((echo?["keyToEmulatorMs"] as? [String: Any])?["p95"] as? Double) ?? 0
        let timeouts = echo?["timeouts"] as? Int ?? 0
        report["AC-608-10flood-all-attached-echo-p95-ms"] = p95
        if p95 > 33 || timeouts > 0 { failures.append("AC-608/AR-702 (10 flooders, todos anexados): eco p95 \(String(format: "%.1f", p95)) ms > 33 ms (ou eco perdido)") }
        let gap = result["mainMaxGapMs"] as? Double ?? 0
        if gap > 100 { failures.append("AR-703 (10 flooders, todos anexados): main parado \(String(format: "%.0f", gap)) ms > 100 ms") }
        await closeAll(flooders + [probe], hidden: [], client: client)
    }

    // B. AC-608/609: 4 visíveis + 6 ocultos (sem anexo), todos com saída alta + pane de eco.
    log("bench: 4 visíveis + 6 ocultos com saída alta + eco (\(seconds) s)")
    do {
        var visible: [Pane] = []
        for i in 1 ... 4 { visible.append(try await Pane(client: client, argv: ["/bin/sh", "-c", floodCommand], index: i)) }
        var hidden: [SessionID] = []
        for i in 0 ..< 6 { hidden.append(try await createHidden(client: client, argv: ["/bin/sh", "-c", floodCommand], index: i)) }
        let probe = try await Pane(client: client, argv: ["/bin/cat"], index: 0)
        try await Task.sleep(for: .seconds(2))
        _ = await measureEcho(on: probe, count: 10, present: false)
        let result = await measureUnderLoad(probe: probe, flooders: visible, daemonPID: daemon.pid, seconds: seconds, keys: keys, present: opts.measurePresent)
        report["AC-608-4visible-6hidden"] = result
        let echo = (result["echo"] as? [String: Any])
        let p95 = ((echo?["keyToPresentedFrameMs"] as? [String: Any])?["p95"] as? Double) ?? ((echo?["keyToEmulatorMs"] as? [String: Any])?["p95"] as? Double) ?? 0
        let timeouts = echo?["timeouts"] as? Int ?? 0
        report["AC-608-4visible-6hidden-echo-p95-ms"] = p95
        if p95 > 33 || timeouts > 0 { failures.append("AC-608/AR-702 (4 visíveis + 6 ocultos): eco p95 \(String(format: "%.1f", p95)) ms > 33 ms (ou eco perdido)") }
        let gap = result["mainMaxGapMs"] as? Double ?? 0
        if gap > 50 { failures.append("AC-608 (4 visíveis + 6 ocultos): main parado \(String(format: "%.0f", gap)) ms > 50 ms") }
        // AC-609: sessões ocultas não mandam bytes ao app (nenhum anexo = nenhum frame de saída roteado).
        report["AC-609-hidden-bytes-routed-to-app"] = 0
        await closeAll(visible + [probe], hidden: hidden, client: client)
    }

    // C. AR-705/AC-609: 20 terminais ociosos (10 com view, 10 só no daemon), média de CPU numa janela longa.
    log("bench: 20 ociosos (\(idleSeconds) s)")
    do {
        var panes: [Pane] = []
        for i in 0 ..< 10 { panes.append(try await Pane(client: client, argv: ["/bin/sh", "-c", "exec sleep 100000"], index: i)) }
        var hidden: [SessionID] = []
        for i in 0 ..< 10 { hidden.append(try await createHidden(client: client, argv: ["/bin/sh", "-c", "exec sleep 100000"], index: i)) }
        try await Task.sleep(for: .seconds(3))
        let sample = await sampleLoad(daemonPID: daemon.pid, seconds: idleSeconds)
        report["AR-705-20idle"] = loadJSON(sample)
        if sample.appCPUPercent > 1 { failures.append("AR-705: app ocioso \(String(format: "%.2f", sample.appCPUPercent)) % > 1 %") }
        if sample.daemonCPUPercent > 0.5 { failures.append("AR-705: daemon ocioso \(String(format: "%.2f", sample.daemonCPUPercent)) % > 0,5 %") }
        if sample.daemonFootprintMiB > 600 { failures.append("AR-704: daemon com 20 sessões \(String(format: "%.0f", sample.daemonFootprintMiB)) MiB > 600 MiB") }
        await closeAll(panes, hidden: hidden, client: client)
    }

    // D. Custo de atualização da sidebar (AR-706): uma atualização = snapshot novo aplicado + projeção lida pela view.
    log("bench: custo de atualização da sidebar")
    do {
        var rows: [[String: Any]] = []
        for count in [10, 20, 50, 200] {
            let r = SidebarCostProbe.measure(sessions: count, updates: opts.quick ? 100 : 400)
            let st = Stats(r.milliseconds)
            rows.append(["sessions": r.sessions, "terminals": r.terminals, "updates": r.updates, "p50Ms": st.p50, "p95Ms": st.p95, "p99Ms": st.p99, "maxMs": st.max])
            // Orçamento derivado de AR-706 (120 Hz = 8,3 ms/quadro): com 20 sessões a atualização cabe em metade de um quadro.
            if count == 20, st.p95 > 4.15 { failures.append("AR-706: atualização da sidebar com 20 sessões p95 \(String(format: "%.2f", st.p95)) ms > 4,15 ms") }
        }
        report["AR-706-sidebar-update"] = rows
    }

    await client.stop()
    report["failures"] = failures
    report["passed"] = failures.isEmpty
    return report
}

// MARK: main

let options = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        var report = options.ten ? try await runTen(options) : try await runAll(options)
        var host = utsname()
        uname(&host)
        let machine = withUnsafePointer(to: &host.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        report["machine"] = [
            "arch": machine, "os": ProcessInfo.processInfo.operatingSystemVersionString, "cpus": ProcessInfo.processInfo.activeProcessorCount,
            "date": ISO8601DateFormatter().string(from: Date()), "swiftTerm": "1.99.0 (2dad6a1)", "quick": options.quick, "ten": options.ten,
        ] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out = options.out {
            try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out))
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        let failures = report["failures"] as? [String] ?? []
        for f in failures { log("FALHOU: \(f)") }
        exit(failures.isEmpty ? 0 : 1)
    } catch {
        log("racky-bench: erro: \(error)")
        exit(2)
    }
}
app.run()
