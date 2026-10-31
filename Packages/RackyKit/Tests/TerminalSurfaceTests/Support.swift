import RackyCore
import RackyProtocol
import RackyUI
import AppKit
import Darwin
import Foundation
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
nonisolated enum SpawnedDaemons {
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

enum HarnessError: Error { case daemonDidNotStart, timeout(String) }

/// `rackyd` real como processo filho, com `RACKY_HOME` isolado em `/tmp` (sun_path limita a 104 bytes).
final class DaemonHarness: @unchecked Sendable {  // SAFETY: `process` só muda em start/stop, chamados em sequência pelo teste.
    let home: URL
    let socketPath: String
    nonisolated(unsafe) private var process: Process?

    init() throws {
        home = URL(fileURLWithPath: "/tmp/abt-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socketPath = home.appendingPathComponent("run/ptyd-v1.sock").path
    }

    nonisolated var pid: Int32? { process?.processIdentifier }

    func start() async throws {
        let process = Process()
        process.executableURL = rackydBinary()
        // Nunca `0`: 5 s sem sessões e o daemon de um teste que travou some sozinho (sem órfãos, F10).
        process.arguments = ["--idle-exit", "5"]
        var environment = ProcessInfo.processInfo.environment
        environment["RACKY_HOME"] = home.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        SpawnedDaemons.add(process.processIdentifier)
        for _ in 0 ..< 100 {
            if let connection = try? await UDSClient.connect(path: socketPath) {
                connection.close()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.daemonDidNotStart
    }

    func stop() async {
        await DaemonReaper.shutdown(home: home)  // `shutdown` do protocolo; SIGKILL de reserva; pega também o filho de um TerminalRuntime no mesmo home
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        if let process { SpawnedDaemons.remove(process.processIdentifier) }
        process = nil
        try? FileManager.default.removeItem(at: home)
    }

    /// `kill -9` no daemon sem apagar o home (o cold log e o banco ficam, como depois de um crash ou reboot).
    func killDaemon() async {
        guard let process, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        SpawnedDaemons.remove(process.processIdentifier)
        self.process = nil
    }

    /// Encerramento síncrono e idempotente (`defer` e `deinit` dos testes): SIGKILL, espera o término e apaga o home.
    nonisolated func terminateNow(removeHome: Bool = true) {
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

    func makeClient(maxBacklogBytes: Int = 4 << 20) -> PTYClient {
        PTYClient(configuration: PTYClientConfiguration(socketPath: socketPath, build: "test", maxBacklogBytes: maxBacklogBytes))
    }
}

func makeCreate(_ argv: [String], cols: UInt16 = 100, rows: UInt16 = 30, env: [String: String] = [:]) -> CreateRequest {
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory(), "TERM": "xterm-256color"]
    environment.merge(env) { $1 }
    return CreateRequest(
        sessionID: SessionID(), argv: argv, cwd: "/tmp", env: environment, cols: cols, rows: rows, ringBytes: 4 << 20, coldLog: false,
        owner: SessionOwner(terminalID: "term-1", runID: "run-1"))
}

/// Espera uma condição (poll curto, sem bloquear a main thread).
@MainActor
func eventually(_ what: String = "condition", timeout: Duration = .seconds(10), _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw HarnessError.timeout(what)
}

/// Coleta o que a view quer escrever no PTY.
final class OutputCollector: Sendable {
    private let items = Mutex<[(bytes: [UInt8], origin: InputOrigin)]>([])

    var sink: TerminalSurfaceView.OutputSink {
        { [self] bytes, origin in items.withLock { $0.append((bytes, origin)) } }
    }

    var all: [(bytes: [UInt8], origin: InputOrigin)] { items.withLock { $0 } }
    func bytes(origin: InputOrigin) -> [UInt8] { all.filter { $0.origin == origin }.flatMap(\.bytes) }
    func reset() { items.withLock { $0.removeAll() } }
}

/// Janela fora da tela com o host dentro (não é exibida; serve de hierarquia para foco, layout e Metal).
@MainActor
func makeWindow(hosting host: TerminalHostView, size: NSSize = NSSize(width: 800, height: 500)) -> NSWindow {
    let window = OffscreenAppKit.makeWindow(size: size, styleMask: [.borderless])
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.makeFirstResponder(host.surface)
    return window
}

/// Alimenta o emulador fora do main, como o app faz (o parse nunca roda no main).
func feedOffMain(_ surface: TerminalSurfaceView, _ text: String) async {
    let feeder = surface.feedSender
    await Task.detached { feeder.feed(byteArray: Array(text.utf8)[...]) }.value
}

@MainActor
func keyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}
