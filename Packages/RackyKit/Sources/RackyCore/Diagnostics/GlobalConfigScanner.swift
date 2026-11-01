import RackyProtocol
import Foundation

/// Lê (nunca escreve) as configs globais dos CLIs atrás do que colide com o que o Racky injeta por lançamento (R1.5–R1.8):
/// skill global `racky`, MCP `racky` e `notify` do Codex.
/// `home` e o sistema de arquivos são injetáveis; os testes usam pastas temporárias.
public struct GlobalConfigScanner: Sendable {
    public var home: URL
    private let readFile: @Sendable (String) -> Data?
    private let exists: @Sendable (String) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(home: home, readFile: { FileManager.default.contents(atPath: $0) },
                  exists: { FileManager.default.fileExists(atPath: $0) })
    }

    public init(home: URL, readFile: @escaping @Sendable (String) -> Data?, exists: @escaping @Sendable (String) -> Bool) {
        self.home = home
        self.readFile = readFile
        self.exists = exists
    }

    /// Nome da skill e do MCP server globais que competem com os que o Racky injeta por lançamento.
    public static let competingName = "racky"

    public func scan() -> [ConflictFinding] {
        var findings: [ConflictFinding] = []
        findings += skillFindings()
        findings += claudeFindings()
        findings += codexFindings()
        findings += openCodeFindings()
        return findings
    }

    private func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
    private func shown(_ relative: String) -> String { "~/" + relative }

    // MARK: Skills

    private func skillFindings() -> [ConflictFinding] {
        var result: [ConflictFinding] = []
        if exists(path(".claude/skills/\(GlobalConfigScanner.competingName)")) {
            result.append(ConflictFinding(
                kind: .globalSkill, provider: .claude, path: shown(".claude/skills/\(GlobalConfigScanner.competingName)"),
                message: "A global \"\(GlobalConfigScanner.competingName)\" skill is installed and may compete with Racky tools."))
        }
        for (provider, relative) in [(TerminalProvider.codex, ".codex/skills/\(GlobalConfigScanner.competingName)"),
                                     (.opencode, ".config/opencode/skills/\(GlobalConfigScanner.competingName)"), (.opencode, ".config/opencode/skill/\(GlobalConfigScanner.competingName)")]
        where exists(path(relative)) {
            result.append(ConflictFinding(
                kind: .globalSkill, provider: provider, path: shown(relative),
                message: "A global \"\(GlobalConfigScanner.competingName)\" skill in \(shown(relative)) may compete with Racky tools (left untouched)."))
        }
        return result
    }

    // MARK: Claude

    private func claudeFindings() -> [ConflictFinding] {
        var result: [ConflictFinding] = []
        for relative in [".claude/settings.json", ".claude.json"] {
            guard let data = readFile(path(relative)), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let servers = object["mcpServers"] as? [String: Any], servers[GlobalConfigScanner.competingName] != nil {
                result.append(ConflictFinding(
                    kind: .mcpServer, provider: .claude, path: shown(relative),
                    message: "A global \"\(GlobalConfigScanner.competingName)\" MCP server in \(shown(relative)) may duplicate Racky's tools (left untouched)."))
            }
        }
        return result
    }

    // MARK: Codex

    private func codexFindings() -> [ConflictFinding] {
        var result: [ConflictFinding] = []
        if let data = readFile(path(".codex/config.toml")), let text = String(data: data, encoding: .utf8) {
            var topLevel = true
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    topLevel = false
                    if line.hasPrefix("[mcp_servers.\(GlobalConfigScanner.competingName)") {
                        result.append(ConflictFinding(
                            kind: .mcpServer, provider: .codex, path: shown(".codex/config.toml"),
                            message: "A global \"\(GlobalConfigScanner.competingName)\" MCP server in ~/.codex/config.toml may duplicate Racky's tools (left untouched)."))
                    }
                } else if topLevel, line.hasPrefix("notify"), line.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                    result.append(ConflictFinding(
                        kind: .notify, provider: .codex, path: shown(".codex/config.toml"),
                        message: "Codex notify is used by another app (left untouched)."))
                }
            }
        }
        return result
    }

    // MARK: OpenCode

    private func openCodeFindings() -> [ConflictFinding] {
        for relative in [".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"] {
            guard let data = readFile(path(relative)), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let servers = object["mcp"] as? [String: Any], servers[GlobalConfigScanner.competingName] != nil else { continue }
            return [ConflictFinding(
                kind: .mcpServer, provider: .opencode, path: shown(relative),
                message: "A global \"\(GlobalConfigScanner.competingName)\" MCP server in \(shown(relative)) may duplicate Racky's tools (left untouched).")]
        }
        return []
    }
}

public enum GlobalSkillBackupError: Error, Equatable {
    case skillNotFound, backupExists, nothingToRestore, originalExists
}

/// "Disable Globally…" e "Restore Skill" (AC-113): move a pasta da skill global para o backup do app e de volta.
/// É a única escrita em pasta global do onboarding e só acontece por clique confirmado (PP-6).
public struct GlobalSkillBackup: Sendable {
    public var home: URL
    public var backupRoot: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, backupRoot: URL) {
        self.home = home
        self.backupRoot = backupRoot
    }

    var original: URL { home.appendingPathComponent(".claude/skills/\(GlobalConfigScanner.competingName)", isDirectory: true) }
    var backup: URL { backupRoot.appendingPathComponent("global-skill-backup/claude-skills-\(GlobalConfigScanner.competingName)", isDirectory: true) }

    public var hasBackup: Bool { FileManager.default.fileExists(atPath: backup.path) }

    @discardableResult
    public func disable() throws -> URL {
        let fm = FileManager.default
        // `fileExists` segue links; um link quebrado também conta como skill instalada.
        guard (try? fm.attributesOfItem(atPath: original.path)) != nil else { throw GlobalSkillBackupError.skillNotFound }
        guard !hasBackup else { throw GlobalSkillBackupError.backupExists }
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: original, to: backup)
        return backup
    }

    public func restore() throws {
        let fm = FileManager.default
        guard hasBackup else { throw GlobalSkillBackupError.nothingToRestore }
        guard (try? fm.attributesOfItem(atPath: original.path)) == nil else { throw GlobalSkillBackupError.originalExists }
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: backup, to: original)
    }
}
