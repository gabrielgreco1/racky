import Foundation

/// Interpreta a saída de `env -0` (entradas `NOME=valor` separadas por NUL). Valores com quebra de linha ficam intactos.
public enum LoginShellEnvParser {
    public static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex else { continue }
            let name = String(decoding: entry[entry.startIndex..<equals], as: UTF8.self)
            let value = String(decoding: entry[entry.index(after: equals)...], as: UTF8.self)
            result[name] = value
        }
        return result
    }
}
