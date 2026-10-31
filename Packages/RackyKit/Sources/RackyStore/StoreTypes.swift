import RackyProtocol
import Foundation

/// Layout em disco do banco (08 AR-301). `root` = `~/Library/Application Support/Racky` (ou `$RACKY_HOME`).
public struct StorePaths: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> StorePaths {
        if let home = environment["RACKY_HOME"], !home.isEmpty {
            return StorePaths(root: URL(fileURLWithPath: home, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StorePaths(root: support.appendingPathComponent("Racky", isDirectory: true))
    }

    public var dbDirectory: URL { root.appendingPathComponent("db", isDirectory: true) }
    public var databaseFile: URL { dbDirectory.appendingPathComponent("racky.sqlite") }
    public var backupsDirectory: URL { root.appendingPathComponent("backups", isDirectory: true) }
    /// Logs JSONL redigidos de cada processo (08 AR-602), a sentinela de crash (`run/app.alive`, AR-604) e os pacotes exportados (AR-603).
    public var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var runDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var diagnosticsDirectory: URL { root.appendingPathComponent("diagnostics", isDirectory: true) }

    func corruptDirectory(stamp: String) -> URL { dbDirectory.appendingPathComponent("corrupt-\(stamp)", isDirectory: true) }

    func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, dbDirectory, backupsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

/// Avisos não bloqueantes para a UI exibir como banner (08 AR-321/322/331).
public enum StoreNotice: Sendable, Equatable {
    /// Corrupção no boot: arquivo movido e último backup válido restaurado.
    case restoredFromBackup(backupDate: Date, corruptPath: URL)
    /// Corrupção sem backup válido: banco vazio criado ("Reveal Corrupt File").
    case recoveredEmpty(corruptPath: URL)
    /// Banco criado por versão mais nova: aberto somente leitura; nada é apagado.
    case newerDatabase(suggestedBackup: URL?)
    /// Migração falhou: rollback feito, banco intocado, somente leitura ("Open Diagnostics").
    case migrationFailed(message: String)
    /// `SQLITE_CORRUPT`/`NOTADB` em tempo de execução: modo somente leitura até o próximo boot.
    case runtimeCorruption

    public var bannerText: String {
        switch self {
        case .restoredFromBackup(let date, _):
            "Restored from the backup of \(date.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "en_US"))))."
        case .recoveredEmpty: "The database was damaged and no backup was available. Started with an empty workspace."
        case .newerDatabase: "Database was created by a newer Racky"
        case .migrationFailed: "The database could not be upgraded. Racky is running in read-only mode."
        case .runtimeCorruption: "The database was damaged while running. Changes are not being saved."
        }
    }
}

public enum StoreAccessMode: Sendable, Equatable {
    case readWrite
    /// Escritas rejeitadas com `StoreError.readOnly`.
    case readOnly
}

public enum StoreError: Error, Sendable, Equatable {
    case readOnly
    case invalidRow(table: String, detail: String)
    case invalidModel(String)
    case migrationFailed(String)
}

/// Fotografia imutável do estado persistido, entregue à UI pelas observações.
public struct StoreSnapshot: Sendable, Equatable {
    public var projects: [Project]
    public var worktrees: [Worktree]
    public var sessions: [Session]
    public var tabs: [Tab]
    public var terminals: [Terminal]
    public var profiles: [LaunchProfile]

    public init(projects: [Project] = [], worktrees: [Worktree] = [], sessions: [Session] = [],
                tabs: [Tab] = [], terminals: [Terminal] = [], profiles: [LaunchProfile] = []) {
        self.projects = projects; self.worktrees = worktrees; self.sessions = sessions
        self.tabs = tabs; self.terminals = terminals; self.profiles = profiles
    }
}
