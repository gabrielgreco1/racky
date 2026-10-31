import Foundation
import GRDB

/// Backups, verificação de integridade e recuperação (08 AR-321, AR-330, AR-331).
enum Backups {
    static let dailyKeep = 7
    static let preMigrationKeep = 5

    static func isDamage(_ error: Error) -> Bool {
        guard let e = error as? DatabaseError else { return false }
        return e.resultCode == .SQLITE_CORRUPT || e.resultCode == .SQLITE_NOTADB
    }

    /// Conexão de leitura. Um banco em modo WAL sem `-shm` não abre com `readonly` (CANTOPEN); nesse caso usa uma conexão
    /// comum, que o chamador nunca usa para escrever (o `mode` do store barra as escritas).
    static func readerQueue(_ url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        do {
            return try DatabaseQueue(path: url.path, configuration: config)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            return try DatabaseQueue(path: url.path)
        }
    }

    /// `true` se o arquivo abre e `check` devolve "ok". Só danos de arquivo contam como falha; outros erros propagam.
    static func passes(_ url: URL, pragma: String) throws -> Bool {
        do {
            let queue = try readerQueue(url)
            defer { try? queue.close() }
            let rows = try queue.read { try String.fetchAll($0, sql: "PRAGMA \(pragma)") }
            return rows == ["ok"]
        } catch {
            if isDamage(error) { return false }
            throw error
        }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return f.string(from: date)
    }

    static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    static func vacuumInto(_ writer: any DatabaseWriter, to url: URL) throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func files(in dir: URL, prefix: String) -> [(url: URL, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }

    static func prune(_ dir: URL, prefix: String, keep: Int) {
        for old in files(in: dir, prefix: prefix).dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// Backup diário (`daily-YYYYMMDD.sqlite`), no máximo um por dia; mantém os 7 mais novos.
    @discardableResult
    static func dailyIfNeeded(_ writer: any DatabaseWriter, paths: StorePaths, now: Date) throws -> URL? {
        let target = paths.backupsDirectory.appendingPathComponent("daily-\(dayStamp(now)).sqlite")
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        try vacuumInto(writer, to: target)
        prune(paths.backupsDirectory, prefix: "daily-", keep: dailyKeep)
        return target
    }

    /// Backup antes de aplicar migrações pendentes; mantém os 5 mais novos.
    static func preMigration(_ writer: any DatabaseWriter, paths: StorePaths, migrationID: String, now: Date) throws -> URL {
        let target = paths.backupsDirectory.appendingPathComponent("pre-migration-\(migrationID)-\(stamp(now)).sqlite")
        try vacuumInto(writer, to: target)
        prune(paths.backupsDirectory, prefix: "pre-migration-", keep: preMigrationKeep)
        return target
    }

    static func newestPreMigration(_ paths: StorePaths) -> URL? {
        files(in: paths.backupsDirectory, prefix: "pre-migration-").first?.url
    }

    /// Mais novo backup (diário ou pré-migração) que passa em `integrity_check`.
    static func newestValid(_ paths: StorePaths) throws -> (url: URL, modified: Date)? {
        let all = (files(in: paths.backupsDirectory, prefix: "daily-") + files(in: paths.backupsDirectory, prefix: "pre-migration-"))
            .sorted { $0.modified > $1.modified }
        for candidate in all where try passes(candidate.url, pragma: "integrity_check") { return candidate }
        return nil
    }

    /// Move `racky.sqlite*` para `db/corrupt-<ts>/` e restaura o backup válido mais novo (ou deixa vazio).
    static func recover(_ paths: StorePaths, now: Date) throws -> StoreNotice {
        let fm = FileManager.default
        let corruptDir = paths.corruptDirectory(stamp: stamp(now))
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: paths.databaseFile.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try fm.moveItem(at: src, to: corruptDir.appendingPathComponent(src.lastPathComponent))
            }
        }
        let movedFile = corruptDir.appendingPathComponent(paths.databaseFile.lastPathComponent)
        if let backup = try newestValid(paths) {
            try fm.copyItem(at: backup.url, to: paths.databaseFile)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.databaseFile.path)
            return .restoredFromBackup(backupDate: backup.modified, corruptPath: movedFile)
        }
        return .recoveredEmpty(corruptPath: movedFile)
    }
}
