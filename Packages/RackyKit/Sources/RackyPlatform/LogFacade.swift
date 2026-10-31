import os

/// Fachada mínima de log (08 AR-601). Um `Logger` por (subsystem, categoria).
/// Mensagens são `privacy: .private` por padrão; só `publicInfo`/`publicError` expõem texto
/// (use apenas para texto estático sem caminhos, argv, URLs ou IDs). Segredos nunca são registrados.
/// Com `DiskLog.install(_:)` feito pelo processo, info/error/publicInfo/publicError também vão para `logs/*.jsonl`, já redigidos (AR-602).
public struct LogFacade: Sendable {
    /// Subsystems canônicos (08 §0.1).
    public enum Subsystem: String, Sendable {
        case app = "app.racky"
        case ptyd = "app.racky.ptyd"
        case cli = "app.racky.cli"
    }

    public let subsystem: Subsystem
    public let category: String
    private let logger: Logger

    public init(_ subsystem: Subsystem, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem.rawValue, category: category)
    }

    public func debug(_ message: String) { logger.debug("\(message, privacy: .private)") }
    public func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        toDisk(.info, message)
    }
    public func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        toDisk(.error, message)
    }
    public func publicInfo(_ message: StaticString) {
        logger.info("\(message, privacy: .public)")
        toDisk(.info, "\(message)")
    }
    public func publicError(_ message: StaticString) {
        logger.error("\(message, privacy: .public)")
        toDisk(.error, "\(message)")
    }

    private func toDisk(_ level: DiskLog.Level, _ message: String) {
        DiskLog.current?.write(level: level, subsystem: subsystem.rawValue, category: category, message: message)
    }
}
