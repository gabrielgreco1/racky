import Foundation

/// Agente visto nas pastas nativas dos CLIs, já fundido por nome (um só mesmo existindo em `~/.claude` e `~/.codex`).
public struct ImportedAgent: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var instructions: String
    public var model: String?
    public var tools: [String]
    public var skills: [String]
    /// Onde existe e o caminho de cada origem (para mostrar os dois logos).
    public var sources: [LibraryClient: String]
    public var id: String { name }
    public var clients: [LibraryClient] { LibraryClient.allCases.filter { sources[$0] != nil } }

    /// Converte em agente do Racky (a UI chama isso ao importar).
    public func definition(now: Date = Date()) -> AgentDefinition {
        AgentDefinition(name: name, description: description, instructions: instructions, model: model, tools: tools, skills: skills, createdAt: now, updatedAt: now)
    }
}

/// Importador só leitura: lê `~/.claude/agents/*.md`, `~/.codex/agents/*.toml` e `~/.config/opencode/agent/*.md`. Nada é escrito.
public enum AgentImporter {
    public static func discover(home: URL) -> [ImportedAgent] {
        var byName: [String: ImportedAgent] = [:]
        func merge(_ a: ImportedAgent) {
            guard var cur = byName[a.name] else { byName[a.name] = a; return }
            // O primeiro a chegar (Claude) vence nos campos; as outras origens só acrescentam o CLI.
            for (k, v) in a.sources { cur.sources[k] = v }
            if cur.description.isEmpty { cur.description = a.description }
            if cur.instructions.isEmpty { cur.instructions = a.instructions }
            if cur.model == nil { cur.model = a.model }
            if cur.tools.isEmpty { cur.tools = a.tools }
            if cur.skills.isEmpty { cur.skills = a.skills }
            byName[a.name] = cur
        }
        for url in files(home.appendingPathComponent(".claude/agents"), ext: "md") {
            if let a = parseMarkdown(url, client: .claude) { merge(a) }
        }
        for url in files(home.appendingPathComponent(".codex/agents"), ext: "toml") {
            if let a = parseCodexTOML(url) { merge(a) }
        }
        for url in files(home.appendingPathComponent(".config/opencode/agent"), ext: "md") {
            if let a = parseMarkdown(url, client: .opencode) { merge(a) }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Importa um `.md` solto (do zero pelo app, "importando um .md"). O nome vem do frontmatter ou do arquivo.
    public static func importMarkdown(at url: URL) -> AgentDefinition? {
        guard let a = parseMarkdown(url, client: .claude) else { return nil }
        return a.definition()
    }

    static func files(_ dir: URL, ext: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().filter { $0.hasSuffix("." + ext) && !$0.hasPrefix(".") }.map { dir.appendingPathComponent($0) }
    }

    static func parseMarkdown(_ url: URL, client: LibraryClient) -> ImportedAgent? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fm = FrontmatterParser.parse(text)
        guard fm.error == nil else { return nil }
        let name = fm.fields["name"]?.text ?? url.deletingPathExtension().lastPathComponent
        guard AgentDefinition.isValidName(name) else { return nil }
        func list(_ key: String) -> [String] {
            guard let v = fm.fields[key] else { return [] }
            if case .list(let l) = v { return l }
            return (v.text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return ImportedAgent(
            name: name, description: fm.fields["description"]?.text ?? "",
            instructions: FrontmatterParser.body(of: text).trimmingCharacters(in: .whitespacesAndNewlines),
            model: fm.fields["model"]?.text, tools: list("tools"), skills: list("skills"), sources: [client: url.path])
    }

    /// TOML mínimo do Codex: `chave = "valor"` e `developer_instructions = """…"""`.
    static func parseCodexTOML(_ url: URL) -> ImportedAgent? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = parseTOMLStrings(text)
        let name = values["name"] ?? url.deletingPathExtension().lastPathComponent
        guard AgentDefinition.isValidName(name) else { return nil }
        return ImportedAgent(
            name: name, description: values["description"] ?? "",
            instructions: (values["developer_instructions"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            model: values["model"], tools: [], skills: [], sources: [.codex: url.path])
    }

    static func parseTOMLStrings(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]; i += 1
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#"), !line.hasPrefix("[") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"\"\"") {
                var body = String(rest.dropFirst(3))
                if let end = body.range(of: "\"\"\"") { out[key] = String(body[..<end.lowerBound]); continue }
                var parts: [String] = body.isEmpty ? [] : [body]
                while i < lines.count {
                    let l = lines[i]; i += 1
                    if let end = l.range(of: "\"\"\"") { parts.append(String(l[..<end.lowerBound])); break }
                    parts.append(l)
                }
                body = parts.joined(separator: "\n")
                out[key] = body
            } else if rest.hasPrefix("\"") {
                var value = ""; var escaped = false
                for ch in rest.dropFirst() {
                    if escaped { value.append(ch == "n" ? "\n" : ch); escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { break }
                    else { value.append(ch) }
                }
                out[key] = value
            }
        }
        return out
    }
}
