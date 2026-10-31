import Foundation

/// Nomes de sessão (03 §6.2, 06 §5.2, P15): derivados do prompt como digitado, ou adjetivo + substantivo (`quiet-harbor`).
public enum SessionNaming {
    /// `quiet-harbor`. O gerador é o `SessionNameGenerator` (um só para pastas limpas, worktrees e composer); injetável para testes.
    public static func automaticName<G: RandomNumberGenerator>(using generator: inout G) -> String {
        SessionNameGenerator.random(using: &generator)
    }

    public static func automaticName() -> String {
        var generator = SystemRandomNumberGenerator()
        return automaticName(using: &generator)
    }

    /// Primeiras palavras do prompt, como digitadas (3 a 5; aqui até 5), sem quebras de linha. `nil` se o prompt é vazio.
    public static func title(fromPrompt prompt: String, maxWords: Int = 5) -> String? {
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(maxWords)
        guard !words.isEmpty else { return nil }
        let text = words.joined(separator: " ")
        return text.count > 60 ? String(text.prefix(60)).trimmingCharacters(in: .whitespaces) : text
    }

    /// Nome de pasta que ainda não existe em `root`: `base`, `base-2`, `base-3`… Nunca reaproveita uma pasta existente (AC-1102).
    public static func uniqueFolderName(_ base: String, in root: URL, fileManager: FileManager = .default) -> String {
        for attempt in 1 ... 500 {
            let candidate = GitNaming.candidate(base, attempt: attempt)
            if !fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path) { return candidate }
        }
        return "\(base)-\(UUID().uuidString.prefix(6).lowercased())"
    }
}
