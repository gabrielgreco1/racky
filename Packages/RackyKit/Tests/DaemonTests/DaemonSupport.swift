import RackyCore
import RackyProtocol
import Darwin
import Foundation
import SwiftTerm
import Synchronization

@testable import RackyPlatform

/// Localiza o `rackyd` construído ao lado do bundle de testes.
func rackydBinary() -> URL {
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("rackyd")
    }
    return URL(fileURLWithPath: ".build/debug/rackyd")
}

/// Registro dos daemons que os testes subiram: o que sobrar no fim do processo de teste é morto (sem órfãos, F10).
enum SpawnedDaemons {
    private static let pids = Mutex<Set<pid_t>>([])
    private static let installed = Mutex<Bool>(false)

    static func add(_ pid: pid_t) {
        installed.withLock { done in
            guard !done else { return }
            done = true
            DaemonReaper.installExitSweep()
            atexit { SpawnedDaemons.killAll() }
        }
        pids.withLock { _ = $0.insert(pid) }
    }

    static func remove(_ pid: pid_t) { pids.withLock { _ = $0.remove(pid) } }

    static func killAll() {
        for pid in pids.withLock({ $0 }) { Darwin.kill(pid, SIGKILL) }
        DaemonReaper.reap()  // daemons de TerminalRuntime/AppEnvironment que nenhum teste registrou (F34)
    }
}

/// `rackyd` real como processo filho, com `RACKY_HOME` isolado em `/tmp` (sun_path limita a 104 bytes).
final class DaemonHarness: @unchecked Sendable {  // SAFETY: `process` só muda em start/stop, chamados em sequência pelo teste.
    let home: URL
    let socketPath: String
    private var process: Process?

    init() throws {
        home = URL(fileURLWithPath: "/tmp/abd-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socketPath = home.appendingPathComponent("run/ptyd-v1.sock").path
    }

    var sessionsDirectory: URL { home.appendingPathComponent("sessions") }

    /// `sessionLeader`: o daemon roda como líder de sessão sem tty de controle, como o launchd o inicia (`posix_spawn` com
    /// `POSIX_SPAWN_SETSID`). Foi assim que os filhos ficavam sem tty de controle e o resize não virava SIGWINCH.
    func start(idleExit: Int = 0, binary: URL? = nil, sessionLeader: Bool = false) async throws {
        // Nunca `0`: um daemon órfão de um teste que travou some sozinho 5 s depois de ficar sem sessões.
        let daemonArguments = ["--idle-exit", "\(idleExit == 0 ? 5 : idleExit)"]
        let daemon = binary ?? rackydBinary()
        var environment = ProcessInfo.processInfo.environment
        environment["RACKY_HOME"] = home.path
        if sessionLeader {
            leaderPID = try Self.spawnSessionLeader(daemon.path, arguments: daemonArguments, environment: environment)
            SpawnedDaemons.add(leaderPID!)
            try await waitForSocket()
            return
        }
        let process = Process()
        process.executableURL = daemon
        process.arguments = daemonArguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        SpawnedDaemons.add(process.processIdentifier)
        try await waitForSocket()
    }

    private func waitForSocket() async throws {
        for _ in 0 ..< 100 {
            if let connection = try? await UDSClient.connect(path: socketPath) {
                connection.close()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.daemonDidNotStart
    }

    /// Daemon iniciado como líder de sessão (sem `Process`, que já faz do filho um líder de grupo e impede o `setsid`).
    private var leaderPID: pid_t?

    private static func spawnSessionLeader(_ path: String, arguments: [String], environment: [String: String]) throws -> pid_t {
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0 ... 2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard result == 0 else { throw HarnessError.daemonDidNotStart }
        return pid
    }

    private func endLeader() {
        guard let pid = leaderPID else { return }
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        for _ in 0 ..< 100 where waitpid(pid, &status, WNOHANG) == 0 { Thread.sleep(forTimeInterval: 0.02) }
        SpawnedDaemons.remove(pid)
        leaderPID = nil
    }

    var pid: Int32? { process?.processIdentifier ?? leaderPID }

    /// Mata o daemon (SIGKILL: simula crash) e espera o término.
    func kill() async {
        guard let process else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        await waitForExit()
        SpawnedDaemons.remove(process.processIdentifier)
        self.process = nil
    }

    func waitForExit(timeout: Duration = .seconds(5)) async {
        guard let process else { return }
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Encerramento síncrono e idempotente (`defer` e `deinit` dos testes): SIGKILL, espera o término e apaga o home.
    func terminateNow(removeHome: Bool = true) {
        endLeader()
        if let process {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                // Espera limitada: `waitUntilExit` pode travar numa thread sem run loop (o hang que o teto de tempo não resgata).
                for _ in 0 ..< 100 where process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
            }
            SpawnedDaemons.remove(process.processIdentifier)
        }
        process = nil
        DaemonReaper.reap(home: home)
        if removeHome { try? FileManager.default.removeItem(at: home) }
    }

    deinit { terminateNow() }

    func stop() async {
        await DaemonReaper.shutdown(home: home)  // `shutdown` do protocolo; SIGKILL de reserva; pega também o filho de um TerminalRuntime no mesmo home
        endLeader()
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        await waitForExit()
        if let process { SpawnedDaemons.remove(process.processIdentifier) }
        process = nil
        try? FileManager.default.removeItem(at: home)
    }

    func makeClient(build: String = "test") -> PTYClient {
        PTYClient(configuration: PTYClientConfiguration(socketPath: socketPath, build: build))
    }
}

enum HarnessError: Error { case daemonDidNotStart, timeout(String) }

func makeCreate(
    _ argv: [String], cols: UInt16 = 100, rows: UInt16 = 30, ringBytes: Int = 4 << 20, coldLog: Bool = false,
    env: [String: String] = [:], cwd: String = "/tmp"
) -> CreateRequest {
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()]
    environment.merge(env) { $1 }
    return CreateRequest(
        sessionID: SessionID(), argv: argv, cwd: cwd, env: environment, cols: cols, rows: rows, ringBytes: ringBytes, coldLog: coldLog,
        owner: SessionOwner(terminalID: "term-1", runID: "run-1"))
}

/// Emulador do lado do cliente (o que a UI faria): aplica o `snapshot` (preâmbulo + replay) e o stream ao vivo.
/// Não responde a consultas (quem responde é o daemon, AR-105).
actor Replica {
    private final class Delegate: TerminalDelegate {
        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = Delegate()
    private var terminal: SwiftTerm.Terminal
    private let cols: Int
    private let rows: Int
    private var lastUpdate = ContinuousClock.now
    private(set) var snapshots = 0
    private(set) var events: [EventPayload] = []
    private(set) var bytes = 0
    private(set) var disconnects = 0
    private(set) var resumedSnapshots = 0
    private var task: Task<Void, Never>?
    private(set) var replayScreen: String?
    private(set) var replayDescription = ""
    private var replayExpected: UInt64 = 0
    private var replayReceived: UInt64 = 0

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        terminal = SwiftTerm.Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000))
    }

    func run(_ attachment: PTYAttachment) {
        let stream = attachment.updates
        task = Task { [weak self] in
            for await update in stream { await self?.apply(update) }
        }
    }

    func stop() { task?.cancel() }

    private func apply(_ update: PTYUpdate) {
        lastUpdate = .now
        switch update {
        case .snapshot(let snapshot):
            snapshots += 1
            if snapshot.resumed {
                resumedSnapshots += 1
            } else {
                terminal = SwiftTerm.Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000))
                terminal.feed(buffer: [UInt8](snapshot.modesPreamble)[...])
            }
            let preamble = [UInt8](snapshot.modesPreamble)
            let kind = preamble == [0x1b, 0x63] ? "ring-start" : (preamble.starts(with: [0x1b, 0x63]) ? "checkpoint" : "cut")
            replayDescription = "\(kind) \(snapshot.startSeq)..\(snapshot.endSeq)"
            replayExpected = snapshot.endSeq - snapshot.startSeq
            replayReceived = 0
            replayScreen = nil
            if replayExpected == 0 { replayScreen = screen() }
        case .output(let frame):
            bytes += frame.bytes.count
            terminal.feed(buffer: [UInt8](frame.bytes)[...])
            if replayScreen == nil {
                replayReceived += UInt64(frame.bytes.count)
                if replayReceived >= replayExpected { replayScreen = screen() }
            }
        case .event(let event):
            events.append(event)
        case .disconnected:
            disconnects += 1
        }
    }

    /// Espera `quiet` sem nenhuma atualização (o redraw e o replay assentaram).
    func waitQuiet(_ quiet: Duration = .milliseconds(400), timeout: Duration = .seconds(15)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if ContinuousClock.now - lastUpdate >= quiet { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Tela visível (sem espaços à direita) mais os modos públicos, cursor e tamanho (formato do S-04).
    func screen() -> String {
        let dims = terminal.getDims()
        var lines: [String] = []
        for row in 0 ..< dims.rows { lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "") }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        let cursor = terminal.getCursorLocation()
        return lines.joined(separator: "\n")
            + "\n--modes alt=\(terminal.isCurrentBufferAlternate) bp=\(terminal.bracketedPasteMode) appCursor=\(terminal.applicationCursor) mouse=\(terminal.mouseMode) cursor=\(cursor.x),\(cursor.y) size=\(dims.cols)x\(dims.rows)"
    }

    /// Mesmo formato de `HeadlessEmulatorHost.textSnapshot` (scrollback + tela).
    func bufferText(lines: Int) -> String {
        var rows = String(decoding: terminal.getBufferAsData(kind: .active), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }
}

/// Espera uma condição assíncrona (poll curto, sem bloquear o pool).
func eventually(_ what: String = "condition", timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw HarnessError.timeout(what)
}

func data(_ text: String) -> Data { Data(text.utf8) }

func processIsAlive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 }

/// Coleta o texto que chega no stream de um pane (para procurar marcadores).
actor Collector {
    private(set) var text = ""
    private var task: Task<Void, Never>?
    func run(_ attachment: PTYAttachment) {
        let stream = attachment.updates
        task = Task { [weak self] in
            for await update in stream {
                if case .output(let frame) = update { await self?.append(frame.bytes) }
            }
        }
    }
    private func append(_ bytes: Data) { text += String(decoding: bytes, as: UTF8.self) }
    func stop() { task?.cancel() }
}
