import Foundation

public enum SkillStoreError: Error, Equatable, Sendable {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
}

public struct RackySkill: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var body: String
    public var id: String { name }
}

/// Skills do Racky em `~/Racky/skills/<nome>/SKILL.md`, com `references/` e `examples/` do que o usuário subiu. O lançamento as copia
/// para o plugin da sessão (como as skills da Library); nada é escrito em `~/.claude` nem em `~/.agents`.
public struct SkillStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Racky/skills", isDirectory: true)
    }

    public func folder(for name: String) throws -> URL {
        guard AgentDefinition.isValidName(name) else { throw SkillStoreError.invalidName(name) }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    public static func markdown(name: String, description: String, body: String) -> String {
        "---\nname: \(AgentStore.quoted(name))\ndescription: \(AgentStore.quoted(description))\n---\n\n\(body)\n"
    }

    public func skillURL(_ name: String) throws -> URL { try folder(for: name).appendingPathComponent("SKILL.md") }

    public func exists(_ name: String) -> Bool { (try? skillURL(name)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Cria a skill e copia os arquivos para `references/` (ou `examples/` quando o nome começa assim). Nome de arquivo sem barras.
    @discardableResult
    public func create(name: String, description: String, body: String, files: [(name: String, data: Data, folder: String)] = []) throws -> URL {
        guard !exists(name) else { throw SkillStoreError.alreadyExists(name) }
        let dir = try folder(for: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(Self.markdown(name: name, description: description, body: body).utf8).write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)
        for f in files {
            let safe = (f.name as NSString).lastPathComponent
            guard !safe.isEmpty, !safe.hasPrefix(".") else { continue }
            let sub = ["references", "examples"].contains(f.folder) ? f.folder : "references"
            let target = dir.appendingPathComponent(sub, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try f.data.write(to: target.appendingPathComponent(safe), options: .atomic)
        }
        return dir
    }

    public func list() -> [RackySkill] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { try? load($0) }
    }

    public func load(_ name: String) throws -> RackySkill {
        guard let text = try? String(contentsOf: try skillURL(name), encoding: .utf8) else { throw SkillStoreError.notFound(name) }
        let fm = FrontmatterParser.parse(text)
        return RackySkill(name: name, description: fm.fields["description"]?.text ?? "", body: FrontmatterParser.body(of: text).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func delete(_ name: String) throws {
        let dir = try folder(for: name)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw SkillStoreError.notFound(name) }
        try FileManager.default.removeItem(at: dir)
    }
}
