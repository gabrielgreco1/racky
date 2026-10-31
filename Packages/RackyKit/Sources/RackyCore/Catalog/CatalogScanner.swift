import RackyStore
import CryptoKit
import Foundation

// Catálogo de agentes e skills por referência (06 §4.1, 01 §5.11). Só leitura: indexa as pastas nativas dos CLIs,
// nunca copia conteúdo e nunca escreve em `~/.claude`, `~/.codex` ou `~/.agents`.

public struct CatalogRoots: Sendable, Equatable {
    public var home: URL
    /// Repositórios abertos: entram `.claude/agents`, `.claude/skills`, `.agents/skills`, `CLAUDE.md` e `AGENTS.md`.
    public var projectRoots: [URL]

    public init(home: URL, projectRoots: [URL] = []) { self.home = home; self.projectRoots = projectRoots }

    public static func current(projectRoots: [URL] = []) -> CatalogRoots {
        CatalogRoots(home: FileManager.default.homeDirectoryForCurrentUser, projectRoots: projectRoots)
    }

    /// Diretórios a observar (existentes ou não: o watcher cai para o ancestral mais próximo).
    public var watchedDirectories: [URL] {
        var dirs = [".claude/agents", ".claude/skills", ".claude/plugins", ".agents/skills", ".codex/agents", ".codex/skills", ".codex/prompts", ".config/opencode/agent", ".config/opencode/agents"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        dirs += [home.appendingPathComponent(".claude", isDirectory: true), home.appendingPathComponent(".codex", isDirectory: true)]
        for root in projectRoots {
            dirs += [".claude/agents", ".claude/skills", ".agents/skills", ".opencode/agent", ".opencode/agents"].map { root.appendingPathComponent($0, isDirectory: true) }
        }
        return dirs
    }
}

public struct CatalogSourceReport: Sendable, Equatable, Codable {
    public var label: String
    public var present: Bool
    public var count: Int
    public var invalid: Int
}

public struct CatalogConflict: Sendable, Equatable {
    public var kind: String
    public var name: String
    public var client: String
    public var winnerID: String
    public var shadowedIDs: [String]
}

public struct CatalogScan: Sendable, Equatable {
    public var items: [CatalogRow]
    public var conflicts: [CatalogConflict]
    /// Agentes com o mesmo nome em `.md` (Claude) e `.toml` (Codex) mas descrição diferente ("Out of sync with Codex agent").
    public var outOfSync: [String]
    public var sources: [CatalogSourceReport]
}

public enum CatalogScanner {
    private enum Layout { case markdownFiles, skillFolders, tomlAgents, singleFile }

    private struct Spec {
        var label: String
        var url: URL
        var source: String
        var kind: String
        var scope: String
        var clients: [String]
        var layout: Layout
        var namePrefix: String? = nil
    }

    static let frontmatterReadLimit = 256 * 1024
    static let descriptionLimit = 500

    public static func scan(_ roots: CatalogRoots, now: Date = Date()) -> CatalogScan {
        var items: [CatalogRow] = []
        var reports: [CatalogSourceReport] = []
        for spec in specs(for: roots) {
            let found = collect(spec, now: now)
            reports.append(CatalogSourceReport(label: spec.label, present: found.present, count: found.items.count,
                                               invalid: found.items.filter { $0.parseError != nil }.count))
            items += found.items
        }
        var seenIDs = Set<String>()
        items = items.filter { seenIDs.insert($0.id).inserted }
        let (resolved, conflicts) = resolveConflicts(items)
        return CatalogScan(items: resolved.sorted { ($0.kind, $0.name, $0.path) < ($1.kind, $1.name, $1.path) },
                           conflicts: conflicts, outOfSync: outOfSync(resolved), sources: reports)
    }

    // MARK: Fontes

    private static func specs(for roots: CatalogRoots) -> [Spec] {
        let h = roots.home
        func dir(_ p: String) -> URL { h.appendingPathComponent(p, isDirectory: true) }
        var list: [Spec] = [
            Spec(label: "~/.claude/agents", url: dir(".claude/agents"), source: "claude", kind: "agent", scope: "user", clients: ["claude"], layout: .markdownFiles),
            Spec(label: "~/.claude/skills", url: dir(".claude/skills"), source: "claude", kind: "skill", scope: "user", clients: ["claude"], layout: .skillFolders),
            Spec(label: "~/.agents/skills", url: dir(".agents/skills"), source: "agents", kind: "skill", scope: "user", clients: ["codex"], layout: .skillFolders),
            Spec(label: "~/.codex/agents", url: dir(".codex/agents"), source: "codex", kind: "agent", scope: "user", clients: ["codex"], layout: .tomlAgents),
            Spec(label: "~/.codex/skills", url: dir(".codex/skills"), source: "codex", kind: "skill", scope: "user", clients: ["codex"], layout: .skillFolders),
            // Prompts do Codex (`/prompts:<nome>`): entram como skills da fonte `codex`, sem ativação por sessão.
            Spec(label: "~/.codex/prompts", url: dir(".codex/prompts"), source: "codex", kind: "skill", scope: "user", clients: ["codex"], layout: .markdownFiles, namePrefix: "prompts"),
            Spec(label: "~/.config/opencode/agent", url: dir(".config/opencode/agent"), source: "opencode", kind: "agent", scope: "user", clients: ["opencode"], layout: .markdownFiles),
            Spec(label: "~/.config/opencode/agents", url: dir(".config/opencode/agents"), source: "opencode", kind: "agent", scope: "user", clients: ["opencode"], layout: .markdownFiles),
            Spec(label: "~/.claude/CLAUDE.md", url: h.appendingPathComponent(".claude/CLAUDE.md"), source: "claude", kind: "instructions", scope: "user", clients: ["claude"], layout: .singleFile),
            Spec(label: "~/.codex/AGENTS.md", url: h.appendingPathComponent(".codex/AGENTS.md"), source: "codex", kind: "instructions", scope: "user", clients: ["codex"], layout: .singleFile),
        ]
        for plugin in installedPlugins(home: h) {
            let base = plugin.path
            list.append(Spec(label: "plugin \(plugin.name) agents", url: base.appendingPathComponent("agents", isDirectory: true), source: "plugin", kind: "agent", scope: "plugin", clients: ["claude"], layout: .markdownFiles, namePrefix: plugin.name))
            list.append(Spec(label: "plugin \(plugin.name) skills", url: base.appendingPathComponent("skills", isDirectory: true), source: "plugin", kind: "skill", scope: "plugin", clients: ["claude"], layout: .skillFolders, namePrefix: plugin.name))
        }
        for root in roots.projectRoots {
            let tag = root.lastPathComponent
            list += [
                Spec(label: "\(tag)/.claude/agents", url: root.appendingPathComponent(".claude/agents", isDirectory: true), source: "claude", kind: "agent", scope: "project", clients: ["claude"], layout: .markdownFiles),
                Spec(label: "\(tag)/.claude/skills", url: root.appendingPathComponent(".claude/skills", isDirectory: true), source: "claude", kind: "skill", scope: "project", clients: ["claude"], layout: .skillFolders),
                Spec(label: "\(tag)/.agents/skills", url: root.appendingPathComponent(".agents/skills", isDirectory: true), source: "agents", kind: "skill", scope: "project", clients: ["codex"], layout: .skillFolders),
                Spec(label: "\(tag)/.opencode/agent", url: root.appendingPathComponent(".opencode/agent", isDirectory: true), source: "opencode", kind: "agent", scope: "project", clients: ["opencode"], layout: .markdownFiles),
                Spec(label: "\(tag)/.opencode/agents", url: root.appendingPathComponent(".opencode/agents", isDirectory: true), source: "opencode", kind: "agent", scope: "project", clients: ["opencode"], layout: .markdownFiles),
                Spec(label: "\(tag)/CLAUDE.md", url: root.appendingPathComponent("CLAUDE.md"), source: "claude", kind: "instructions", scope: "project", clients: ["claude"], layout: .singleFile),
                Spec(label: "\(tag)/AGENTS.md", url: root.appendingPathComponent("AGENTS.md"), source: "agents", kind: "instructions", scope: "project", clients: ["codex"], layout: .singleFile),
            ]
        }
        return list
    }

    struct InstalledPlugin { var name: String; var path: URL }

    /// `~/.claude/plugins/installed_plugins.json`: `{"plugins": {"<nome>@<marketplace>": [{"installPath": …}]}}`. Tolerante.
    static func installedPlugins(home: URL) -> [InstalledPlugin] {
        let file = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        var out: [InstalledPlugin] = []
        for (key, value) in plugins.sorted(by: { $0.key < $1.key }) {
            let name = String(key.split(separator: "@", maxSplits: 1).first ?? Substring(key))
            let entries = (value as? [[String: Any]]) ?? []
            if let path = entries.compactMap({ $0["installPath"] as? String }).first {
                out.append(InstalledPlugin(name: name, path: URL(fileURLWithPath: path, isDirectory: true)))
            }
        }
        return out
    }

    // MARK: Coleta

    private static func collect(_ spec: Spec, now: Date) -> (present: Bool, items: [CatalogRow]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: spec.url.path, isDirectory: &isDir) else { return (false, []) }
        switch spec.layout {
        case .singleFile:
            guard !isDir.boolValue else { return (false, []) }
            return (true, [item(spec, file: spec.url, name: spec.url.lastPathComponent, text: nil, parsed: nil, now: now)])
        case .markdownFiles:
            guard isDir.boolValue else { return (false, []) }
            var out: [CatalogRow] = []
            for file in recursiveFiles(spec.url, ext: "md") { out.append(markdownItem(spec, file: file, fallbackName: file.deletingPathExtension().lastPathComponent, now: now)) }
            return (true, out)
        case .tomlAgents:
            guard isDir.boolValue else { return (false, []) }
            var out: [CatalogRow] = []
            for file in recursiveFiles(spec.url, ext: "toml") { out.append(tomlItem(spec, file: file, now: now)) }
            return (true, out)
        case .skillFolders:
            guard isDir.boolValue else { return (false, []) }
            var out: [CatalogRow] = []
            let children = ((try? fm.contentsOfDirectory(at: spec.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
            for child in children {
                var childIsDir: ObjCBool = false
                _ = fm.fileExists(atPath: child.path, isDirectory: &childIsDir)   // segue symlink
                if childIsDir.boolValue {
                    let skill = child.appendingPathComponent("SKILL.md")
                    if fm.fileExists(atPath: skill.path) {
                        out.append(markdownItem(spec, file: skill, fallbackName: child.lastPathComponent, now: now))
                    }
                } else if child.pathExtension.lowercased() == "zip" {
                    out.append(zipItem(spec, file: child, now: now))
                }
            }
            return (true, out)
        }
    }

    private static func recursiveFiles(_ dir: URL, ext: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension.lowercased() == ext { out.append(url) }
        return out.sorted { $0.path < $1.path }
    }

    private static func head(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: frontmatterReadLimit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// SHA-256 em blocos: nunca carrega o arquivo inteiro.
    static func sha256(of file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func itemID(_ spec: Spec, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(spec.source)|\(spec.kind)|\(path)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func item(_ spec: Spec, file: URL, name: String, text: String?, parsed: ParsedMeta?, now: Date) -> CatalogRow {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let finalName = (spec.namePrefix.map { "\($0):" } ?? "") + name
        return CatalogRow(
            id: itemID(spec, path: file.path), source: spec.source, kind: spec.kind, scope: spec.scope, path: file.path,
            name: finalName, description: parsed?.description, contentHash: sha256(of: file), clients: spec.clients,
            mtime: attrs?[.modificationDate] as? Date, frontmatterJSON: parsed?.json, parseError: parsed?.error,
            discoveredAt: now)
    }

    struct ParsedMeta { var name: String?; var description: String?; var json: String?; var error: String? }

    private static func markdownItem(_ spec: Spec, file: URL, fallbackName: String, now: Date) -> CatalogRow {
        let text = head(file) ?? ""
        let result = FrontmatterParser.parse(text)
        let name = clean(result.fields["name"]?.text) ?? fallbackName
        var meta = ParsedMeta(name: name, description: clean(result.fields["description"]?.text).map { String($0.prefix(descriptionLimit)) })
        if let err = result.error { meta.error = err.summary }
        var reduced: [String: Any] = [:]
        for key in ["name", "description", "model", "tools", "skills", "mcpServers"] {
            guard let v = result.fields[key] else { continue }
            switch v {
            case .string(let s): reduced[key] = String(s.prefix(descriptionLimit))
            case .list(let l): reduced[key] = l
            case .raw(let s): reduced[key] = String(s.prefix(descriptionLimit))
            }
        }
        meta.json = reduced.isEmpty ? nil : json(reduced)
        return item(spec, file: file, name: name, text: text, parsed: meta, now: now)
    }

    private static func tomlItem(_ spec: Spec, file: URL, now: Date) -> CatalogRow {
        let result = AgentTOML.parse(head(file) ?? "")
        let fallback = file.deletingPathExtension().lastPathComponent
        let name = clean(result.fields["name"]) ?? fallback
        var meta = ParsedMeta(name: name, description: clean(result.fields["description"]).map { String($0.prefix(descriptionLimit)) })
        if let err = result.error { meta.error = err.summary.replacingOccurrences(of: "Invalid frontmatter", with: "Invalid TOML") }
        var reduced: [String: Any] = ["name": name]
        if let d = meta.description { reduced["description"] = d }
        meta.json = json(reduced)
        return item(spec, file: file, name: name, text: nil, parsed: meta, now: now)
    }

    private static func zipItem(_ spec: Spec, file: URL, now: Date) -> CatalogRow {
        let name = file.deletingPathExtension().lastPathComponent
        let meta = ParsedMeta(name: name, description: "Packaged skill (.zip)", json: json(["packaged": true]), error: nil)
        return item(spec, file: file, name: name, text: nil, parsed: meta, now: now)
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: Conflitos (06 §4.4)

    private static func rank(_ scope: String) -> Int { scope == "project" ? 0 : scope == "user" ? 1 : 2 }
    /// Desempate no mesmo escopo: `~/.codex/skills` é o formato legado e perde para `~/.agents/skills`.
    private static func sourceRank(_ source: String) -> Int { source == "codex" ? 1 : 0 }

    /// Mesmo nome em mais de uma fonte do mesmo cliente: vence project > user > plugin; as outras ganham `shadowedBy`.
    static func resolveConflicts(_ items: [CatalogRow]) -> ([CatalogRow], [CatalogConflict]) {
        var shadow: [String: String] = [:]
        var conflicts: [CatalogConflict] = []
        for client in ["claude", "codex"] {
            let groups = Dictionary(grouping: items.filter { $0.clients.contains(client) && ($0.kind == "agent" || $0.kind == "skill") },
                                    by: { "\($0.kind)|\($0.name)" })
            for key in groups.keys.sorted() {
                let group = groups[key]!.sorted { (rank($0.scope), sourceRank($0.source), $0.path) < (rank($1.scope), sourceRank($1.source), $1.path) }
                guard group.count > 1, let winner = group.first else { continue }
                let losers = group.dropFirst().map(\.id)
                conflicts.append(CatalogConflict(kind: winner.kind, name: winner.name, client: client, winnerID: winner.id, shadowedIDs: Array(losers)))
                for loser in group.dropFirst() where shadow[loser.id] == nil { shadow[loser.id] = winner.id }
            }
        }
        // Só fica "shadowed" quem perdeu em todos os clientes em que existe.
        let result = items.map { row -> CatalogRow in
            var r = row
            if let w = shadow[row.id] {
                let lostEverywhere = row.clients.allSatisfy { client in
                    conflicts.contains { $0.client == client && $0.shadowedIDs.contains(row.id) } || !["claude", "codex"].contains(client)
                }
                if lostEverywhere { r.shadowedBy = w }
            }
            return r
        }
        return (result, conflicts)
    }

    static func outOfSync(_ items: [CatalogRow]) -> [String] {
        let md = Dictionary(items.filter { $0.kind == "agent" && $0.source == "claude" && $0.scope == "user" }.map { ($0.name, $0.description ?? "") },
                            uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for toml in items where toml.kind == "agent" && toml.source == "codex" {
            if let d = md[toml.name], d != (toml.description ?? "") { out.append(toml.name) }
        }
        return out.sorted()
    }
}
