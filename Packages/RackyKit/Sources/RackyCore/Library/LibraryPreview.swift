import Foundation

// Preview de um item (03 §13.2/13.3): frontmatter + corpo lidos sob demanda do arquivo nativo, e a lista de arquivos da pasta da
// skill (scripts marcados). Só leitura; o corpo nunca vai para o banco.

public struct LibraryFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var size: Int64
    /// Arquivo executável ou com extensão de script: `Contains executable scripts`.
    public var isScript: Bool
}

public struct LibraryPreview: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var value: String
    }

    public var fields: [Field] = []
    public var body: String = ""
    public var truncated = false
    public var files: [LibraryFile] = []
    /// `Invalid frontmatter (line 4): …` ou erro de leitura.
    public var error: String?

    public var hasScripts: Bool { files.contains(where: \.isScript) }
}

public enum LibraryPreviewLoader {
    /// Teto do corpo mostrado (o resto fica no editor).
    public static let bodyLimit = 200_000
    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "rb", "js", "mjs", "ts", "pl", "php", "command", "swift"]
    static let maxListedFiles = 200

    public static func load(_ item: LibraryEntry) -> LibraryPreview {
        var preview = LibraryPreview()
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            preview.error = "Couldn't read this file."
            return preview
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bodyLimit + 1)) ?? Data()
        preview.truncated = data.count > bodyLimit
        let text = String(decoding: data.prefix(bodyLimit), as: UTF8.self)
        if item.url.pathExtension.lowercased() == "toml" {
            let toml = AgentTOML.parse(text)
            for key in toml.fields.keys.sorted() where key != "developer_instructions" {
                preview.fields.append(.init(key: key, value: toml.fields[key] ?? ""))
            }
            preview.body = toml.fields["developer_instructions"] ?? ""
            preview.error = toml.error?.summary.replacingOccurrences(of: "Invalid frontmatter", with: "Invalid TOML")
        } else {
            let parsed = FrontmatterParser.parse(text)
            for key in parsed.fields.keys.sorted() {
                preview.fields.append(.init(key: key, value: parsed.fields[key]?.text ?? ""))
            }
            preview.body = FrontmatterParser.body(of: text)
            preview.error = parsed.error?.summary
        }
        if item.isSkillFolder { preview.files = files(in: item.folderURL) }
        return preview
    }

    /// Arquivos da pasta da skill (relativos, ordenados, sem ocultos), limitados em número.
    public static func files(in folder: URL) -> [LibraryFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isExecutableKey], options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.path
        var out: [LibraryFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isExecutableKey]), values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            let script = values.isExecutable == true || scriptExtensions.contains(url.pathExtension.lowercased())
            out.append(LibraryFile(path: relative, size: Int64(values.fileSize ?? 0), isScript: script))
            if out.count >= maxListedFiles { break }
        }
        return out.sorted { $0.path < $1.path }
    }
}
