import RackyProtocol
import Darwin
import Foundation

/// `meta.json` do cold log (06 §1.5): só nomes de variáveis de ambiente, nunca valores.
struct ColdLogMeta: Codable, Sendable {
    var sessionID: String
    var terminalID: String
    var runID: String
    var argv: [String]
    var cwd: String
    var envKeys: [String]
    var pid: Int32?
    var startedAt: Date
    var exit: ExitInfo?
}

/// Cold log em disco: `output.log` com rotação 2 × 8 MiB (`output.log` e `output.log.1`), escrita assíncrona em lote.
// SAFETY: todo estado mutável só é tocado dentro de `queue`.
final class ColdLog: @unchecked Sendable {
    static let segmentBytes = 8 << 20
    static let flushBytes = 256 << 10
    static let flushDelay: DispatchTimeInterval = .milliseconds(100)
    static let retention: TimeInterval = 7 * 24 * 3600

    let directory: URL
    private let queue = DispatchQueue(label: "app.racky.ptyd.coldlog", qos: .utility)
    private var buffer: [UInt8] = []
    private var fd: Int32 = -1
    private var written = 0
    private var flushScheduled = false
    private var meta: ColdLogMeta

    init(directory: URL, meta: ColdLogMeta) throws {
        self.directory = directory
        self.meta = meta
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.write(meta, to: directory)
    }

    func append(_ bytes: [UInt8]) {
        queue.async { [self] in
            buffer.append(contentsOf: bytes)
            if buffer.count >= Self.flushBytes {
                flush()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + Self.flushDelay) { [self] in
                    flushScheduled = false
                    flush()
                }
            }
        }
    }

    func update(pid: Int32?, exit: ExitInfo?) {
        queue.async { [self] in
            meta.pid = pid ?? meta.pid
            meta.exit = exit ?? meta.exit
            flush()
            try? Self.write(meta, to: directory)
        }
    }

    /// Grava o que está pendente e fecha o arquivo.
    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                flush()
                if fd >= 0 {
                    close(fd)
                    fd = -1
                }
                continuation.resume()
            }
        }
    }

    func remove() {
        queue.async { [self] in
            if fd >= 0 {
                close(fd)
                fd = -1
            }
            buffer.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        if fd < 0 { openSegment(truncate: false) }
        var offset = 0
        while offset < buffer.count {
            if written >= Self.segmentBytes { rotate() }
            let room = Self.segmentBytes - written
            let take = min(buffer.count - offset, room)
            let count = buffer[offset ..< offset + take].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, take) }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            written += count
            offset += count
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func openSegment(truncate: Bool) {
        let path = directory.appendingPathComponent("output.log").path
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | (truncate ? O_TRUNC : 0), 0o600)
        var info = stat()
        written = fd >= 0 && fstat(fd, &info) == 0 ? Int(info.st_size) : 0
    }

    private func rotate() {
        if fd >= 0 { close(fd) }
        let current = directory.appendingPathComponent("output.log").path
        let previous = directory.appendingPathComponent("output.log.1").path
        rename(current, previous)
        openSegment(truncate: true)
    }

    private static func write(_ meta: ColdLogMeta, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("meta.json")
        try encoder.encode(meta).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    /// Apaga diretórios de sessões encerradas há mais de 7 dias (e sem `meta.json` legível e antigo).
    static func sweep(sessionsDirectory: URL, keeping live: Set<String>, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for entry in entries where !live.contains(entry.lastPathComponent) {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("meta.json")),
                let meta = try? decoder.decode(ColdLogMeta.self, from: data), let exit = meta.exit
            else { continue }
            if now.timeIntervalSince(exit.at) > retention { try? manager.removeItem(at: entry) }
        }
    }
}
