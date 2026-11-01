import Foundation

/// CSV (RFC 4180) compartilhado pelos exportadores (consolidado do lote, datasets).
public enum CSVFormat {
    /// Células com `,`, `"` ou quebra de linha vão entre aspas, com `"` dobrado.
    public static func cell(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Injeção de fórmula em planilha: texto que começa com `=`, `+`, `-`, `@`, tab ou CR ganha `'` na frente (o texto veio de uma página
    /// da web). Não vale para número já validado (`-5` continua `-5`): quem chama só passa texto não confiável.
    public static func safe(_ text: String) -> String {
        guard let first = text.first, "=+-@\t\r".contains(first) else { return text }
        return "'" + text
    }
}
