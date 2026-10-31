import RackyDocker
import CryptoKit
import Foundation

/// Pasta do run no host (07 §2.8): `work/` (bind rw em `/work`) e `logs/` (só o egress e o app escrevem; NÃO é montada no
/// `work`). O diário, os comandos, os pedidos de ajuda e a timeline moram em `logs/`, fora do alcance do agente (CS-149).
public struct RunFolder: Sendable, Equatable {
    public let root: URL
    public var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var transcript: URL { root.appendingPathComponent("transcript", isDirectory: true) }
    public var commandsDirectory: URL { logs.appendingPathComponent("commands", isDirectory: true) }
    public var requestsFile: URL { logs.appendingPathComponent("requests.jsonl") }
    public var timelineFile: URL { logs.appendingPathComponent("timeline.md") }

    public init(root: URL) { self.root = root }

    public func ensureLayout() throws {
        let fm = FileManager.default
        for dir in [work, logs, transcript, commandsDirectory] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        // Só o transcript fica restrito ao dono: `logs/` e `work/` viram bind mount do container e são escritos por outro uid lá dentro.
        chmod(transcript.path, 0o700)
    }

    public func file(_ name: String) -> URL { logs.appendingPathComponent(name) }
}

/// Log append-only com hash encadeado (`prev_sha256`, o mesmo formato do reqlog do egress: `ReqlogIntegrity.verify` confere).
public actor ChainedLog {
    public nonisolated let file: URL
    private var previous: String
    private var count: Int

    public init(file: URL) {
        self.file = file
        var prev = ReqlogIntegrity.genesis
        var lines = 0
        if let data = try? Data(contentsOf: file) {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                prev = Self.hash(Data(line))
                lines += 1
            }
        }
        previous = prev
        count = lines
    }

    static func hash(_ line: Data) -> String { SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined() }

    public var lineCount: Int { count }

    /// Acrescenta `entry` (objeto) com `n`, `ts` e `prev_sha256`. Devolve o objeto gravado.
    @discardableResult
    public func append(_ entry: [String: JSON]) throws -> [String: JSON] {
        var object = entry
        count += 1
        object["n"] = .int(count)
        if object["ts"] == nil { object["ts"] = .double((Date().timeIntervalSince1970 * 1000).rounded() / 1000) }
        object["prev_sha256"] = .string(previous)
        let line = JSON.object(object).data()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data([0x0A]))
        previous = Self.hash(line)
        return object
    }

    public func entries() -> [[String: JSON]] { Self.read(file) }

    public static func read(_ file: URL) -> [[String: JSON]] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSON.parse(Data($0)).object }
    }

    public func integrity() -> ReqlogIntegrity { (try? ReqlogIntegrity.verify(file: file)) ?? .tampered(line: 0) }
}
