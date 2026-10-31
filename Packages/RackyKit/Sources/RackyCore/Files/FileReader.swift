import Foundation

/// Conteúdo de um arquivo para o visualizador (somente leitura).
public enum FileContent: Sendable, Equatable {
    /// Texto; `truncated` quando passou do limite de leitura (só o começo é mostrado).
    case text(String, truncated: Bool)
    case image(path: String)
    case binary(size: Int64)
    case unreadable(String)
}

public enum FileReader {
    /// Limite de leitura: 1 MiB cobre código-fonte; acima disso o visualizador mostra o começo e avisa.
    public static let defaultLimit = 1_048_576
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico"]

    public static func read(path: String, limit: Int = defaultLimit) -> FileContent {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image(path: path) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable("Couldn't read this file.") }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return .unreadable("Couldn't read this file.") }
        let truncated = data.count > limit
        let body = truncated ? data.prefix(limit) : data[...]
        if isBinary(body) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return .binary(size: (attributes?[.size] as? NSNumber)?.int64Value ?? Int64(body.count))
        }
        let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
        return .text(text, truncated: truncated)
    }

    /// NUL nos primeiros 8000 bytes (a mesma heurística do git).
    public static func isBinary(_ data: some Collection<UInt8>) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// Número de linhas (um texto sem `\n` final conta a última linha).
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        return text.hasSuffix("\n") ? count : count + 1
    }
}

/// Busca por texto dentro do arquivo aberto.
public enum CodeSearch {
    public static let matchLimit = 5000

    public static func ranges(of query: String, in text: String, caseSensitive: Bool = false) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var result: [NSRange] = []
        var location = 0
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while location < ns.length, result.count < matchLimit {
            let found = ns.range(of: query, options: options, range: NSRange(location: location, length: ns.length - location))
            guard found.location != NSNotFound else { break }
            result.append(found)
            location = found.location + max(found.length, 1)
        }
        return result
    }
}
