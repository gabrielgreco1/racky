import Foundation

public enum AgentStoreError: Error, Equatable, Sendable {
    case invalidName(String)
    case notFound(String)
    case alreadyExists(String)
    case photoTooLarge
    case unsupportedPhoto
}

/// Agentes em `~/Racky/agents`, uma pasta por agente:
/// `agent.md` (frontmatter + instruções), `agent.json` (resto dos metadados), `avatar.svg` ou `photo.<ext>`,
/// `attachments.json`, e `memory.sqlite` (ver `AgentMemoryStore`).
public struct AgentStore: Sendable {
    public static let maxPhotoBytes = 5_000_000
    static let photoExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

    public let root: URL
    public init(root: URL) { self.root = root }

    /// `~/Racky/agents` da casa dada.
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Racky/agents", isDirectory: true)
    }

    public func folder(for name: String) throws -> URL {
        guard AgentDefinition.isValidName(name) else { throw AgentStoreError.invalidName(name) }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    public func memoryURL(for name: String) throws -> URL { try folder(for: name).appendingPathComponent("memory.sqlite") }

    // MARK: metadados que não estão no agent.md

    struct Extra: Codable {
        var tone: String
        var avatar: AgentAvatar
        var computer: AgentComputerPreset?
        var variables: [AgentVariable]
        var sites: [AgentSite]
        var createdAt: Date
        var updatedAt: Date
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    // MARK: agent.md

    /// YAML escalar entre aspas duplas (JSON é YAML válido).
    static func quoted(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    public static func markdown(for a: AgentDefinition) -> String {
        var fm = ["---", "name: \(quoted(a.name))", "description: \(quoted(a.description))"]
        if let m = a.model, !m.isEmpty { fm.append("model: \(quoted(m))") }
        if !a.tools.isEmpty { fm.append("tools: [\(a.tools.map(quoted).joined(separator: ", "))]") }
        if !a.skills.isEmpty { fm.append("skills: [\(a.skills.map(quoted).joined(separator: ", "))]") }
        fm.append("---")
        return fm.joined(separator: "\n") + "\n\n" + a.instructions + "\n"
    }

    // MARK: CRUD

    public func list() -> [AgentDefinition] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { try? load($0) }
    }

    public func exists(_ name: String) -> Bool {
        guard let f = try? folder(for: name) else { return false }
        return FileManager.default.fileExists(atPath: f.appendingPathComponent("agent.md").path)
    }

    public func load(_ name: String) throws -> AgentDefinition {
        let dir = try folder(for: name)
        guard let text = try? String(contentsOf: dir.appendingPathComponent("agent.md"), encoding: .utf8) else { throw AgentStoreError.notFound(name) }
        let fm = FrontmatterParser.parse(text)
        func list(_ key: String) -> [String] {
            switch fm.fields[key] {
            case .list(let l): return l
            case .string(let s), .raw(let s):
                return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case nil: return []
            }
        }
        var a = AgentDefinition(name: name)
        a.description = fm.fields["description"]?.text ?? ""
        a.model = fm.fields["model"]?.text
        a.tools = list("tools"); a.skills = list("skills")
        a.instructions = FrontmatterParser.body(of: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = try? Data(contentsOf: dir.appendingPathComponent("agent.json")), let x = try? Self.decoder().decode(Extra.self, from: data) {
            a.tone = x.tone; a.avatar = x.avatar; a.computer = x.computer; a.variables = x.variables; a.sites = x.sites
            a.createdAt = x.createdAt; a.updatedAt = x.updatedAt
        }
        return a
    }

    /// Cria um agente novo e gera o avatar SVG (a menos que já tenha foto).
    @discardableResult
    public func create(_ agent: AgentDefinition, now: Date = Date()) throws -> AgentDefinition {
        guard !exists(agent.name) else { throw AgentStoreError.alreadyExists(agent.name) }
        var a = agent
        a.createdAt = now; a.updatedAt = now
        try write(a)
        if a.avatar.kind == .generated { try writeAvatar(a) }
        return a
    }

    /// Grava alterações de um agente que já existe.
    public func update(_ agent: AgentDefinition, now: Date = Date()) throws {
        guard exists(agent.name) else { throw AgentStoreError.notFound(agent.name) }
        var a = agent; a.updatedAt = now
        try write(a)
    }

    public func delete(_ name: String) throws {
        let dir = try folder(for: name)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw AgentStoreError.notFound(name) }
        try FileManager.default.removeItem(at: dir)
    }

    private func write(_ a: AgentDefinition) throws {
        let dir = try folder(for: a.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(Self.markdown(for: a).utf8).write(to: dir.appendingPathComponent("agent.md"), options: .atomic)
        let extra = Extra(tone: a.tone, avatar: a.avatar, computer: a.computer, variables: a.variables, sites: a.sites, createdAt: a.createdAt, updatedAt: a.updatedAt)
        try Self.encoder().encode(extra).write(to: dir.appendingPathComponent("agent.json"), options: .atomic)
    }

    // MARK: avatar

    private func writeAvatar(_ a: AgentDefinition) throws {
        let dir = try folder(for: a.name)
        try Data(AgentAvatarGenerator.svg(name: a.name, variant: a.avatar.variant).utf8).write(to: dir.appendingPathComponent("avatar.svg"), options: .atomic)
    }

    /// Avatar gerado com outra variação (o botão "Regerar").
    @discardableResult
    public func regenerateAvatar(_ name: String) throws -> AgentDefinition {
        var a = try load(name)
        removePhotos(in: try folder(for: name))
        a.avatar = AgentAvatar(kind: .generated, variant: a.avatar.variant + 1)
        try write(a); try writeAvatar(a)
        return a
    }

    /// Foto enviada pelo usuário no lugar do avatar gerado.
    @discardableResult
    public func setPhoto(_ name: String, data: Data, fileExtension: String) throws -> AgentDefinition {
        let ext = fileExtension.lowercased()
        guard Self.photoExtensions.contains(ext) else { throw AgentStoreError.unsupportedPhoto }
        guard data.count <= Self.maxPhotoBytes else { throw AgentStoreError.photoTooLarge }
        var a = try load(name)
        let dir = try folder(for: name)
        removePhotos(in: dir)
        try data.write(to: dir.appendingPathComponent("photo.\(ext)"), options: .atomic)
        a.avatar = AgentAvatar(kind: .photo, variant: a.avatar.variant, photoFile: "photo.\(ext)")
        try write(a)
        return a
    }

    private func removePhotos(in dir: URL) {
        for ext in Self.photoExtensions { try? FileManager.default.removeItem(at: dir.appendingPathComponent("photo.\(ext)")) }
    }

    /// Arquivo da imagem atual (foto ou SVG gerado).
    public func avatarURL(_ name: String) -> URL? {
        guard let a = try? load(name), let dir = try? folder(for: name) else { return nil }
        let file = a.avatar.kind == .photo ? (a.avatar.photoFile ?? "") : "avatar.svg"
        let url = dir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: anexos

    public func attachments(_ name: String) throws -> AgentAttachmentManifest {
        let dir = try folder(for: name)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("attachments.json")) else { return AgentAttachmentManifest() }
        return (try? Self.decoder().decode(AgentAttachmentManifest.self, from: data)) ?? AgentAttachmentManifest()
    }

    public func setAttachments(_ name: String, _ manifest: AgentAttachmentManifest) throws {
        guard exists(name) else { throw AgentStoreError.notFound(name) }
        try Self.encoder().encode(manifest).write(to: try folder(for: name).appendingPathComponent("attachments.json"), options: .atomic)
    }
}
