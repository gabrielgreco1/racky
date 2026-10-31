import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Varredura das configs globais (R1.5–R1.8) e backup da skill global (AC-113). Só pastas temporárias.
@Suite struct GlobalConfigScannerTests {
    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("racky-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ relative: String, in home: URL) throws {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func emptyHomeHasNoConflicts() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(GlobalConfigScanner(home: home).scan().isEmpty)
    }

    @Test func detectsTheGlobalSkillAndForeignConfigs() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("# skill", ".claude/skills/racky/SKILL.md", in: home)
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/x/.orca/hook.sh stop"}]}]},"mcpServers":{"racky":{"command":"x"}}}"#, ".claude/settings.json", in: home)
        try write("model = \"gpt\"\nnotify = [\"/usr/bin/other-app\"]\n[mcp_servers.racky]\ncommand = \"x\"\n", ".codex/config.toml", in: home)
        try write(#"{"mcp":{"racky":{"type":"local"}}}"#, ".config/opencode/opencode.json", in: home)

        let findings = GlobalConfigScanner(home: home).scan()
        let kinds = findings.map { "\($0.provider.rawValue):\($0.kind.rawValue)" }
        #expect(kinds.contains("claude:globalSkill") && kinds.contains("claude:hooks") && kinds.contains("claude:mcpServer"))
        #expect(kinds.contains("codex:notify") && kinds.contains("codex:mcpServer") && kinds.contains("opencode:mcpServer"))
        #expect(findings.filter(\.isActionable).count == 1, "só a skill global do Claude tem remédio")
        #expect(findings.first { $0.kind == .hooks }?.message.hasPrefix("Hooks from Orca") == true)
    }

    @Test func ordinaryHooksAndNotifyInsideTablesAreNotConflicts() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#, ".claude/settings.json", in: home)
        try write("[tui]\nnotify = true\n", ".codex/config.toml", in: home)
        #expect(GlobalConfigScanner(home: home).scan().isEmpty)
    }

    @Test func scanNeverModifiesAnything() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("# skill", ".claude/skills/racky/SKILL.md", in: home)
        try write("notify = [\"x\"]\n", ".codex/config.toml", in: home)
        func snapshot() -> [String: Date] {
            var result: [String: Date] = [:]
            let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.contentModificationDateKey])
            while let url = walker?.nextObject() as? URL { result[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            return result
        }
        let before = snapshot()
        _ = GlobalConfigScanner(home: home).scan()
        #expect(snapshot() == before)
    }

    @Test func backupMovesTheSkillAndRestoresIt() throws {
        let home = try makeHome()
        let support = try makeHome()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: support) }
        try write("# skill", ".claude/skills/racky/SKILL.md", in: home)
        let backup = GlobalSkillBackup(home: home, backupRoot: support)
        #expect(!backup.hasBackup)
        try backup.disable()
        #expect(backup.hasBackup)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/racky").path))
        #expect(GlobalConfigScanner(home: home).scan().isEmpty)
        #expect(throws: GlobalSkillBackupError.skillNotFound) { try backup.disable() }
        try backup.restore()
        #expect(!backup.hasBackup)
        #expect(try String(contentsOf: home.appendingPathComponent(".claude/skills/racky/SKILL.md"), encoding: .utf8) == "# skill")
        #expect(throws: GlobalSkillBackupError.nothingToRestore) { try backup.restore() }
    }

    @Test func restoreRefusesToOverwriteANewSkill() throws {
        let home = try makeHome()
        let support = try makeHome()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: support) }
        try write("old", ".claude/skills/racky/SKILL.md", in: home)
        let backup = GlobalSkillBackup(home: home, backupRoot: support)
        try backup.disable()
        try write("new", ".claude/skills/racky/SKILL.md", in: home)
        #expect(throws: GlobalSkillBackupError.originalExists) { try backup.restore() }
        #expect(try String(contentsOf: home.appendingPathComponent(".claude/skills/racky/SKILL.md"), encoding: .utf8) == "new")
    }
}
