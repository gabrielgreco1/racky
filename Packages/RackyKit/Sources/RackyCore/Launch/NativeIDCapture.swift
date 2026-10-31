import RackyPlatform
import RackyProtocol
import Foundation

/// Captura do ID nativo da conversa (06 §2.5). Claude não precisa: o app gera o UUID e passa em `--session-id`.
///
/// **Codex** (0.163 não tem `--session-id`):
/// 1. Fatia 2: hook `SessionStart` (`session_id`, `transcript_path`) por lançamento.
/// 2. Fatia 1 e fallback sempre disponível: o primeiro `~/.codex/sessions/AAAA/MM/DD/rollout-*.jsonl` criado depois do
///    spawn cuja primeira linha é `session_meta` com `payload.cwd` igual ao cwd do terminal e `payload.timestamp >= spawn − 2 s`.
///    Leitura somente; nada é escrito em `~/.codex`. Formato conferido na 0.163.0 (fixture `codex-session-meta.jsonl`).
///
/// **OpenCode**: `opencode session list --format json` antes do spawn e de novo 5 s depois; a sessão nova no mesmo
/// diretório. Formato conferido na 1.18.34 (fixture `opencode-session-list.json`).
public enum CodexRolloutScanner {
    public struct Match: Sendable, Equatable {
        public let id: String
        public let file: URL
        public let timestamp: Date
    }

    /// Diretório padrão dos rollouts.
    public static func defaultRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func find(root: URL, cwd: String, spawnedAt: Date, slack: TimeInterval = 2, now: Date = Date()) -> Match? {
        let fm = FileManager.default
        let wanted = canonical(cwd)
        let threshold = spawnedAt.addingTimeInterval(-slack)
        var best: Match?
        for directory in dayDirectories(root: root, around: [spawnedAt.addingTimeInterval(-86_400), spawnedAt, now, spawnedAt.addingTimeInterval(86_400)]) {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let file = directory.appendingPathComponent(name)
                guard let meta = sessionMeta(of: file), meta.timestamp >= threshold, canonical(meta.cwd) == wanted else { continue }
                if best == nil || meta.timestamp < (best?.timestamp ?? .distantFuture) {
                    best = Match(id: meta.id, file: file, timestamp: meta.timestamp)
                }
            }
        }
        return best
    }

    struct Meta { var id: String; var cwd: String; var timestamp: Date }

    /// Lê só a primeira linha (até 512 KiB; a `base_instructions` do Codex é longa) e extrai `session_meta`.
    static func sessionMeta(of file: URL) -> Meta? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let cap = 512 * 1024
        while buffer.count < cap {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) ?? (buffer.count < cap ? buffer.endIndex : nil) else { return nil }
        let line = buffer[buffer.startIndex..<newline]
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, let cwd = payload["cwd"] as? String,
              let stamp = (payload["timestamp"] as? String) ?? (object["timestamp"] as? String),
              let date = parseDate(stamp) else { return nil }
        return Meta(id: id, cwd: cwd, timestamp: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(text, strategy: withFraction) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func dayDirectories(root: URL, around dates: [Date]) -> [URL] {
        let calendar = Calendar.current
        var seen = Set<String>()
        var result: [URL] = []
        for date in dates {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let path = String(format: "%04d/%02d/%02d", y, m, d)
            if seen.insert(path).inserted { result.append(root.appendingPathComponent(path, isDirectory: true)) }
        }
        return result
    }

    /// Nome da conversa em `~/.codex/session_index.jsonl` (`id`, `thread_name`), só leitura.
    public static func threadName(forID id: String, indexFile: URL) -> String? {
        guard let data = try? Data(contentsOf: indexFile) else { return nil }
        var name: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["id"] as? String == id else { continue }
            name = object["thread_name"] as? String // a última linha do ID vence
        }
        return name
    }
}

public struct OpenCodeSession: Sendable, Equatable, Decodable {
    public let id: String
    public let title: String?
    public let directory: String?
    public let created: Int64?
    public let updated: Int64?
}

public enum OpenCodeSessionList {
    /// Saída de `opencode session list --format json` (array). Ruído antes do `[` é ignorado.
    public static func parse(_ data: Data) -> [OpenCodeSession] {
        guard let start = data.firstIndex(of: UInt8(ascii: "[")) else { return [] }
        return (try? JSONDecoder().decode([OpenCodeSession].self, from: data[start...])) ?? []
    }

    /// Sessão que não existia antes, no mesmo diretório; a mais recente se houver mais de uma.
    public static func newSession(before: [OpenCodeSession], after: [OpenCodeSession], cwd: String) -> OpenCodeSession? {
        let known = Set(before.map(\.id))
        let wanted = CodexRolloutScanner.canonical(cwd)
        return after
            .filter { !known.contains($0.id) && $0.directory.map { CodexRolloutScanner.canonical($0) == wanted } == true }
            .max { ($0.created ?? 0) < ($1.created ?? 0) }
    }
}

/// Executa a captura (com polling). Tudo injetável para teste; nenhum agente é executado, só `session list`.
public struct NativeIDCapturer: Sendable {
    public var runner: any CommandRunning
    public var pause: @Sendable (Duration) async -> Void
    public var clock: @Sendable () -> Date

    public init(
        runner: any CommandRunning = SystemCommandRunner(),
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner; self.pause = pause; self.clock = clock
    }

    /// Codex: repete a varredura de rollouts até achar ou estourar `timeout` (padrão 10 s, TA-208).
    public func captureCodex(
        root: URL, cwd: String, spawnedAt: Date, timeout: Duration = .seconds(10), interval: Duration = .milliseconds(500)
    ) async -> String? {
        let deadline = clock().addingTimeInterval(timeout.timeInterval)
        while true {
            if let match = CodexRolloutScanner.find(root: root, cwd: cwd, spawnedAt: spawnedAt, now: clock()) { return match.id }
            if clock() >= deadline || Task.isCancelled { return nil }
            await pause(interval)
        }
    }

    /// OpenCode, antes do spawn.
    public func snapshotOpenCode(executable: String, environment: [String: String], cwd: String) async -> [OpenCodeSession] {
        await list(executable: executable, environment: environment, cwd: cwd)
    }

    /// OpenCode, `delay` (5 s) depois do spawn.
    public func captureOpenCode(
        before: [OpenCodeSession], executable: String, environment: [String: String], cwd: String, delay: Duration = .seconds(5)
    ) async -> String? {
        await pause(delay)
        if Task.isCancelled { return nil }
        let after = await list(executable: executable, environment: environment, cwd: cwd)
        return OpenCodeSessionList.newSession(before: before, after: after, cwd: cwd)?.id
    }

    private func list(executable: String, environment: [String: String], cwd: String) async -> [OpenCodeSession] {
        let request = ProcessRequest(
            executable: URL(fileURLWithPath: executable), arguments: ["session", "list", "--format", "json"],
            environment: environment, currentDirectory: URL(fileURLWithPath: cwd, isDirectory: true), timeout: .seconds(5)
        )
        guard let output = try? await runner.run(request), output.exitCode == 0 else { return [] }
        return OpenCodeSessionList.parse(output.stdout)
    }
}

extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
