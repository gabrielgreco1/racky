import RackyStore
import Foundation

// Biblioteca só leitura (03 §13, 06 §4): agentes e skills das fontes nativas dos CLIs, vistos pela UI. O índice SQLite guarda só
// caminho, hash e metadados; aqui o corpo é lido sob demanda (`LibraryPreviewLoader`). Nada é copiado nem escrito em pasta nativa.

public enum LibraryKind: String, Sendable, CaseIterable, Identifiable {
    case agent, skill
    public var id: String { rawValue }
}

public enum LibraryClient: String, Sendable, CaseIterable {
    case claude, codex, opencode

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
}

/// Filtro de fonte da lista (`All Sources` + um por categoria, com contagem).
public enum LibraryCategory: String, Sendable, CaseIterable, Identifiable {
    case claude, codex, agents, opencode, plugins, project, racky
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claude: "~/.claude"
        case .codex: "~/.codex"
        case .agents: "~/.agents"
        case .opencode: "~/.config/opencode"
        case .plugins: "Plugins"
        case .project: "This Project"
        case .racky: "Racky"
        }
    }
}

/// Estado de um item numa sessão (Claude Code), 03 §13.3 e 06 §4.2.
public enum LibraryActivation: Sendable, Equatable {
    /// Global: o próprio CLI carrega em toda sessão (`Always on (global)`).
    case alwaysOn
    /// Adicionado só nesta sessão (vale no próximo lançamento).
    case thisSession
    /// Pode ser adicionado nesta sessão.
    case off
    /// O Claude Code não usa este item (ou ele ainda não é suportado), com o motivo.
    case unavailable(String)

    public var canToggle: Bool {
        switch self {
        case .thisSession, .off: true
        case .alwaysOn, .unavailable: false
        }
    }
}

public struct LibraryEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: LibraryKind
    public var name: String
    public var summary: String?
    public var path: String
    public var category: LibraryCategory
    public var source: String
    public var scope: String
    public var clients: [LibraryClient]
    public var model: String?
    public var tools: [String]
    public var skills: [String]
    public var mcpServers: [String]
    public var parseError: String?
    public var shadowedBy: String?
    public var isPackaged: Bool
    /// Pasta do repositório de um item de projeto (`<repo>/.claude/…`).
    public var projectRoot: String?
    public var contentHash: String?

    public init(
        id: String, kind: LibraryKind, name: String, summary: String? = nil, path: String, category: LibraryCategory, source: String, scope: String,
        clients: [LibraryClient], model: String? = nil, tools: [String] = [], skills: [String] = [], mcpServers: [String] = [],
        parseError: String? = nil, shadowedBy: String? = nil, isPackaged: Bool = false, projectRoot: String? = nil, contentHash: String? = nil
    ) {
        self.id = id; self.kind = kind; self.name = name; self.summary = summary; self.path = path; self.category = category
        self.source = source; self.scope = scope; self.clients = clients; self.model = model; self.tools = tools; self.skills = skills
        self.mcpServers = mcpServers; self.parseError = parseError; self.shadowedBy = shadowedBy; self.isPackaged = isPackaged
        self.projectRoot = projectRoot; self.contentHash = contentHash
    }

    public var url: URL { URL(fileURLWithPath: path) }
    /// Pasta da skill (`SKILL.md` dentro dela) ou o diretório do arquivo.
    public var folderURL: URL { url.deletingLastPathComponent() }
    public var isSkillFolder: Bool { kind == .skill && url.lastPathComponent == "SKILL.md" }

    public func works(with client: LibraryClient) -> Bool { clients.contains(client) }
}

extension LibraryEntry {
    /// `nil` para o que a Library não mostra (instruções e plugins soltos).
    public init?(row: CatalogRow) {
        guard let kind = LibraryKind(rawValue: row.kind), row.missingAt == nil else { return nil }
        let json = (row.frontmatterJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        func list(_ key: String) -> [String] {
            if let l = json[key] as? [String] { return l }
            if let s = json[key] as? String {
                return s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return []
        }
        let category: LibraryCategory =
            row.scope == "project" ? .project : row.source == "plugin" || row.scope == "plugin" ? .plugins
            : row.source == "claude" ? .claude : row.source == "codex" ? .codex : row.source == "opencode" ? .opencode : .agents
        var clients = row.clients.compactMap(LibraryClient.init(rawValue:))
        if clients.isEmpty { clients = [.claude] }
        let packaged = row.path.lowercased().hasSuffix(".zip")
        self.init(
            id: row.id, kind: kind, name: row.name, summary: row.description, path: row.path, category: category, source: row.source,
            scope: row.scope, clients: clients, model: (json["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }, tools: list("tools"),
            skills: list("skills"), mcpServers: Self.serverNames(json["mcpServers"]), parseError: row.parseError, shadowedBy: row.shadowedBy,
            isPackaged: packaged, projectRoot: row.scope == "project" ? Self.projectRoot(of: row.path) : nil, contentHash: row.contentHash)
    }

    /// Nomes dos servidores de `mcpServers`: lista, ou as chaves de topo do mapa cru do frontmatter.
    static func serverNames(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        guard let raw = value as? String else { return [] }
        var names: [String] = []
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let stripped = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            let leading = line.prefix(while: { $0 == " " }).count
            if leading <= 2, let colon = stripped.firstIndex(of: ":"), !stripped.hasPrefix("{") {
                let key = String(stripped[..<colon]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, key.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil, !["type", "command", "args", "url", "env"].contains(key) {
                    names.append(key)
                }
            } else if !stripped.contains(":"), !stripped.isEmpty, leading <= 2 { names.append(stripped) }
        }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    static func projectRoot(of path: String) -> String? {
        for marker in ["/.claude/", "/.agents/", "/.opencode/"] {
            if let range = path.range(of: marker) { return String(path[..<range.lowerBound]) }
        }
        return nil
    }
}

// MARK: Ativação

extension LibraryEntry {
    /// O estado do item numa sessão do Claude Code: `sessionFolder` é a pasta da sessão e `added` os IDs ativados nela.
    public func activation(sessionFolder: String?, added: Set<String>) -> LibraryActivation {
        if isPackaged { return .unavailable("Packaged skills can't be added yet.") }
        if parseError != nil { return .unavailable("This file has invalid frontmatter.") }
        if works(with: .claude) {
            switch scope {
            case "user", "plugin": return .alwaysOn
            default:
                if let sessionFolder, let projectRoot, Self.isInside(projectRoot, of: sessionFolder) { return .alwaysOn }
                return added.contains(id) ? .thisSession : .off
            }
        }
        // Skills no formato `SKILL.md` das fontes do Codex valem para o Claude Code; o resto não tem equivalente.
        if kind == .skill, isSkillFolder { return added.contains(id) ? .thisSession : .off }
        if kind == .skill { return .unavailable("Codex prompts only work in Codex.") }
        return .unavailable("Not available in Claude Code")
    }

    static func isInside(_ root: String, of folder: String) -> Bool {
        let a = URL(fileURLWithPath: root).standardizedFileURL.path, b = URL(fileURLWithPath: folder).standardizedFileURL.path
        return b == a || b.hasPrefix(a + "/")
    }
}

extension LibraryEntry {
    /// Linha de fonte da aba Context (03 §10.6): `Global · ~/.claude/skills`, `Project · .claude/`, `Plugin · vercel` ou `This session`.
    public func sourceLine(activation: LibraryActivation) -> String {
        if activation == .thisSession { return "This session" }
        switch scope {
        case "project":
            let folder = [".claude", ".agents", ".opencode"].first { path.contains("/\($0)/") } ?? ".claude"
            return "Project · \(folder)/"
        case "plugin": return "Plugin · \(name.split(separator: ":").first.map(String.init) ?? name)"
        default: return "Global · \(category.label)/\(kind == .skill ? "skills" : "agents")"
        }
    }
}

// MARK: Lista, busca e contagens

public enum LibraryIndex {
    public static func items(from rows: [CatalogRow]) -> [LibraryEntry] {
        rows.compactMap(LibraryEntry.init(row:)).sorted {
            ($0.name.lowercased(), $0.path) < ($1.name.lowercased(), $1.path)
        }
    }

    /// Itens de uma seção, da fonte escolhida e que casam com a busca (nome, descrição ou fonte).
    public static func filter(_ items: [LibraryEntry], kind: LibraryKind, category: LibraryCategory?, query: String) -> [LibraryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            guard item.kind == kind else { return false }
            if let category, item.category != category { return false }
            guard !needle.isEmpty else { return true }
            return item.name.lowercased().contains(needle) || (item.summary?.lowercased().contains(needle) ?? false)
                || item.category.label.lowercased().contains(needle)
        }
    }

    /// Contagem por fonte dentro de uma seção (a busca não conta: o número é do que existe no disco).
    public static func counts(_ items: [LibraryEntry], kind: LibraryKind) -> [LibraryCategory: Int] {
        var out: [LibraryCategory: Int] = [:]
        for item in items where item.kind == kind { out[item.category, default: 0] += 1 }
        return out
    }
}
