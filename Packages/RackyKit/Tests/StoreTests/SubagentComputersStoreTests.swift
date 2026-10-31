import RackyProtocol
import Foundation
import GRDB
import Testing

@testable import RackyStore

/// F12: atributo por sessão "Subagent computers" (`off`/`ask`/`full`), migração `v7_subagent_computers` encadeada após `v6_agent_tree`.
@Suite struct SubagentComputersStoreTests {
    @Test func migrationIsChainedAfterV6() {
        let ids = StoreMigrations.all.map(\.id)
        #expect(ids.suffix(5) == ["v7_subagent_computers", "v8_orchestration_identity", "v9_orchestration_pool", "v10_datasets", "v11_subagent_harness"])
    }

    @Test func modeDefaultsToOffAndPersistsAcrossReopen() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        var off = Session(kind: .clean, folderPath: "/tmp/a", title: "a")
        var ask = Session(kind: .clean, folderPath: "/tmp/b", title: "b")
        var full = Session(kind: .clean, folderPath: "/tmp/c", title: "c")
        #expect(off.subagentComputers == .off)
        ask.subagentComputers = .ask
        full.subagentComputers = .full
        off.title = "a"
        for session in [off, ask, full] { try await store.save(session) }
        try await store.close()

        let reopened = try await home.openStore(day: 1)
        let loaded = Dictionary(uniqueKeysWithValues: try await reopened.sessions().map { ($0.title, $0.subagentComputers) })
        #expect(loaded == ["a": .off, "b": .ask, "c": .full])
        // Mudar só o atributo não toca no resto da sessão.
        try await reopened.setSubagentComputers(sessionID: off.id, mode: .full)
        let changed = try #require(try await reopened.session(id: off.id))
        #expect(changed.subagentComputers == .full && changed.title == "a" && changed.folderPath == "/tmp/a")
        try await reopened.setSubagentComputers(sessionID: off.id, mode: .off)
        #expect(try await reopened.session(id: off.id)?.subagentComputers == .off)
        try await reopened.close()
    }

    @Test func migratesFromV6KeepingSessionsOffAndBackingUpFirst() async throws {
        let home = try TempHome(); defer { home.remove() }
        let chain = Array(StoreMigrations.all.prefix(6))
        #expect(chain.last?.id == "v6_agent_tree")
        let before = try await home.openStore(day: 0, migrations: chain)
        // Na v6 a coluna ainda não existe: grava a sessão por SQL, como um banco de uma versão anterior a esta.
        try await before.close()
        let db = try DatabaseQueue(path: home.paths.databaseFile.path)
        try await db.write {
            try $0.execute(sql: "INSERT INTO session (id, kind, folder_path, title, created_at) VALUES ('11111111-1111-4111-8111-111111111111', 'clean', '/tmp/old', 'old', 1)")
        }
        let columns = try await db.read { try Row.fetchAll($0, sql: "PRAGMA table_info(session)").map { $0["name"] as String } }
        #expect(!columns.contains("subagent_computers"))

        let after = try await home.openStore(day: 1)
        #expect(after.openNotices.isEmpty)
        let sessions = try await after.sessions()
        #expect(sessions.count == 1 && sessions[0].subagentComputers == .off, "old sessions stay without computers")
        try await after.close()
        #expect(home.backups.filter { $0.hasPrefix("pre-migration-v7_subagent_computers-") }.count == 1)
    }

    @Test func checkConstraintRejectsUnknownMode() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.close()
        let db = try DatabaseQueue(path: home.paths.databaseFile.path)
        await #expect(throws: DatabaseError.self) {
            try await db.write {
                try $0.execute(sql: "INSERT INTO session (id, kind, folder_path, title, created_at, subagent_computers) VALUES ('x', 'clean', '/tmp', 't', 1, 'bogus')")
            }
        }
    }
}
