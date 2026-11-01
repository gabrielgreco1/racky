import Foundation
import Synchronization

/// Log em disco, JSONL rotativo (08 AR-602): `logs/<processo>.jsonl` mais `.1` ... `.4` (5 arquivos de até 2 MiB). A redação
/// acontece antes de gravar. A gravação é assíncrona numa fila serial (o chamador nunca espera I/O); `flush()` espera a fila.
public final class DiskLog: Sendable {
    public struct Configuration: Sendable {
        public var directory: URL
        public var process: String
        public var maxBytes: Int
        public var maxFiles: Int
        public init(directory: URL, process: String, maxBytes: Int = 2 << 20, maxFiles: Int = 5) {
            self.directory = directory
            self.process = process
            self.maxBytes = maxBytes
            self.maxFiles = max(1, maxFiles)
        }
    }

    public enum Level: String, Sendable { case debug, info, error, metric }

    private struct State {
        var handle: FileHandle?
        var size = 0
    }

    public let configuration: Configuration
    private let queue: DispatchQueue
    private let state = Mutex(State())

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        self.queue = DispatchQueue(label: "app.racky.disklog.\(configuration.process)", qos: .utility)
    }

    /// Arquivo ativo e rotacionados, do mais novo ao mais antigo.
    public var files: [URL] {
        (0 ..< configuration.maxFiles).map { fileURL(index: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func fileURL(index: Int) -> URL {
        let name = index == 0 ? "\(configuration.process).jsonl" : "\(configuration.process).\(index).jsonl"
        return configuration.directory.appendingPathComponent(name)
    }

    public func write(level: Level, subsystem: String, category: String, message: String, fields: [String: String] = [:], at date: Date = Date()) {
        queue.async { [self] in append(level: level, subsystem: subsystem, category: category, message: message, fields: fields, at: date) }
    }

    /// Espera as gravações pendentes (testes, saída do processo, exportação).
    public func flush() {
        queue.sync {}
        state.withLock { $0.handle?.synchronizeFile() }
    }

    private func append(level: Level, subsystem: String, category: String, message: String, fields: [String: String], at date: Date) {
        var object: [String: Any] = [
            "t": Self.timestamp(date), "level": level.rawValue, "subsystem": subsystem, "category": category, "process": configuration.process,
            "msg": LogRedactor.redact(message),
        ]
        if !fields.isEmpty { object["fields"] = fields.mapValues(LogRedactor.redact) }
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        state.withLock { state in
            do {
                if state.handle == nil { try open(&state) }
                if state.size + line.count > configuration.maxBytes, state.size > 0 { try rotate(&state) }
                try state.handle?.write(contentsOf: line)
                state.size += line.count
            } catch {
                state.handle = nil  // tenta reabrir na próxima; log nunca derruba o processo
            }
        }
    }

    private func open(_ state: inout State) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configuration.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = fileURL(index: 0)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: url)
        state.size = Int(try handle.seekToEnd())
        state.handle = handle
    }

    private func rotate(_ state: inout State) throws {
        try state.handle?.close()
        state.handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(index: configuration.maxFiles - 1))
        for index in stride(from: configuration.maxFiles - 2, through: 0, by: -1) where fm.fileExists(atPath: fileURL(index: index).path) {
            try fm.moveItem(at: fileURL(index: index), to: fileURL(index: index + 1))
        }
        try open(&state)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    // MARK: Instância do processo

    private static let installed = Mutex<DiskLog?>(nil)

    /// Liga o log em disco deste processo (app, daemon ou CLI). `LogFacade` passa a gravar nele além do `os_log`.
    public static func install(_ log: DiskLog?) { installed.withLock { $0 = log } }

    public static var current: DiskLog? { installed.withLock { $0 } }
}
