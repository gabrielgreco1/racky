import Foundation

// Plugin gerado por lançamento (06 §4.2): `AB/run/launch/<runID>/plugin-session/` com `.claude-plugin/plugin.json`
// (`name: "racky-session"`) e as skills ativadas na sessão copiadas por lançamento, mais os agentes ativados em `--agents`.
// Nada é escrito em `~/.claude`, `~/.codex` nem `~/.agents`: a origem só é lida.

public struct SessionLibraryInjection: Sendable, Equatable {
    public static let pluginName = "racky-session"
    public static let directoryName = "plugin-session"

    /// Arquivos do plugin, com nome relativo ao diretório do lançamento (`plugin-session/…`).
    public var pluginFiles: [LaunchFile]
    /// `--agents`: nome do agente → definição (`description`, `prompt`, `tools`, `model`, `skills`).
    public var agents: [String: [String: LibraryJSON]]
    public var skillNames: [String]
    /// Itens que não deu para ler (sumiram ou ilegíveis): o lançamento segue sem eles.
    public var skipped: [String]

    public var isEmpty: Bool { pluginFiles.isEmpty && agents.isEmpty }

    /// `--agents` do lançamento com os agentes da sessão somados aos que já vieram (os que já existem vencem).
    public func mergedAgentsJSON(into base: Data?) -> Data? {
        var merged: [String: Any] = [:]
        if let base, !base.isEmpty, let object = try? JSONSerialization.jsonObject(with: base) as? [String: Any] { merged = object }
        for (name, definition) in agents where merged[name] == nil { merged[name] = definition.mapValues(\.any) }
        guard !merged.isEmpty else { return base }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }
}

/// JSON mínimo, `Sendable` e comparável, para as definições de `--agents`.
public enum LibraryJSON: Sendable, Equatable {
    case string(String)
    case strings([String])

    var any: Any {
        switch self {
        case .string(let s): s
        case .strings(let l): l
        }
    }
}

public enum SessionLibraryBuilder {
    static let maxFilesPerSkill = 200
    static let maxBytesPerSkill = 4_000_000
    static let maxPromptBytes = 200_000

    /// Lê as origens e monta o plugin e os agentes. `nil` quando nada foi ativado (ou nada pôde ser lido).
    public static func build(_ refs: [ActivationRef]) -> SessionLibraryInjection? {
        guard !refs.isEmpty else { return nil }
        var files: [LaunchFile] = []
        var agents: [String: [String: LibraryJSON]] = [:]
        var skills: [String] = []
        var skipped: [String] = []
        var usedSkillNames = Set<String>()
        for ref in refs.sorted(by: { ($0.kind, $0.name) < ($1.kind, $1.name) }) {
            switch ref.kind {
            case "skill":
                let source = URL(fileURLWithPath: ref.path)
                guard source.lastPathComponent == "SKILL.md", let copied = copySkill(folder: source.deletingLastPathComponent(), name: folderName(ref, used: &usedSkillNames)) else {
                    skipped.append(ref.name); continue
                }
                files += copied
                skills.append(ref.name)
            case "agent":
                guard let definition = agentDefinition(path: ref.path) else { skipped.append(ref.name); continue }
                agents[definition.name ?? ref.name] = definition.fields
            default: skipped.append(ref.name)
            }
        }
        if !skills.isEmpty {
            let manifest: [String: Any] = [
                "name": SessionLibraryInjection.pluginName, "version": "1.0.0",
                "description": "Skills added to this Racky session from the Library",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]) {
                files.insert(LaunchFile(name: "\(SessionLibraryInjection.directoryName)/.claude-plugin/plugin.json", contents: data), at: 0)
            }
        }
        let injection = SessionLibraryInjection(pluginFiles: files, agents: agents, skillNames: skills.sorted(), skipped: skipped)
        return injection.isEmpty ? nil : injection
    }

    /// Nome da pasta no plugin: o da pasta de origem, sem colidir com outra skill ativada.
    private static func folderName(_ ref: ActivationRef, used: inout Set<String>) -> String {
        var base = URL(fileURLWithPath: ref.path).deletingLastPathComponent().lastPathComponent
        base = base.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        if base.isEmpty { base = "skill" }
        var name = base, n = 2
        while !used.insert(name).inserted { name = "\(base)-\(n)"; n += 1 }
        return name
    }

    /// Copia a pasta da skill (arquivos regulares, sem ocultos) para `plugin-session/skills/<nome>/…`, com teto de arquivos e bytes.
    static func copySkill(folder: URL, name: String) -> [LaunchFile]? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [LaunchFile] = []
        var bytes = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            guard out.count < maxFilesPerSkill, bytes + size <= maxBytesPerSkill, let data = try? Data(contentsOf: url) else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            let executable = fm.isExecutableFile(atPath: url.path)
            out.append(LaunchFile(name: "\(SessionLibraryInjection.directoryName)/skills/\(name)/\(relative)", contents: data, posixMode: executable ? 0o700 : 0o600))
            bytes += size
        }
        return out.contains { $0.name.hasSuffix("/SKILL.md") } ? out : nil
    }

    struct AgentDefinition { var name: String?; var fields: [String: LibraryJSON] }

    /// Agente Markdown (`.md`) → definição de `--agents`: `description`, `prompt` (corpo), `tools`, `model`, `skills`. `mcpServers`
    /// não entra (precisa do formato de array, S-08; v1.1).
    static func agentDefinition(path: String) -> AgentDefinition? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "md", let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: maxPromptBytes)) ?? Data(), as: UTF8.self)
        let parsed = FrontmatterParser.parse(text)
        guard parsed.error == nil else { return nil }
        let body = FrontmatterParser.body(of: text).trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: LibraryJSON] = ["prompt": .string(body)]
        fields["description"] = .string(parsed.fields["description"]?.text ?? url.deletingPathExtension().lastPathComponent)
        if let model = parsed.fields["model"]?.text, !model.isEmpty { fields["model"] = .string(model) }
        for key in ["tools", "skills"] {
            guard let value = parsed.fields[key] else { continue }
            let items: [String]
            switch value {
            case .list(let l): items = l
            case .string(let s), .raw(let s): items = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if !items.isEmpty { fields[key] = .strings(items) }
        }
        return AgentDefinition(name: parsed.fields["name"]?.text, fields: fields)
    }
}

// MARK: Texto de invocação (adapter do CLI, 06 §4.2)

public enum LibraryInvocation {
    /// O texto que `Insert in Prompt` cola no prompt do agente (nunca com Enter). `nil` = o CLI não tem forma de invocar o item.
    public static func text(for item: LibraryEntry, provider: LibraryClient, addedToSession: Bool) -> String? {
        switch (provider, item.kind) {
        case (.claude, .skill):
            guard item.works(with: .claude) || item.isSkillFolder else { return nil }
            if addedToSession { return "/\(SessionLibraryInjection.pluginName):\(item.name)" }
            return "/\(item.name)"
        case (.claude, .agent):
            guard item.works(with: .claude) || addedToSession else { return nil }
            return "@agent-\(item.name)"
        case (.codex, .skill):
            guard item.works(with: .codex) else { return nil }
            return item.name.hasPrefix("prompts:") ? "/\(item.name)" : "$\(item.name)"
        case (.codex, .agent): return nil
        case (.opencode, .agent):
            guard item.works(with: .opencode) else { return nil }
            return "@\(item.name)"
        case (.opencode, .skill): return nil
        }
    }
}
