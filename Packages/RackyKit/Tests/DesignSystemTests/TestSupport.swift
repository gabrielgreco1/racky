import Foundation

/// Localiza a raiz do repositório a partir deste arquivo (sobe até achar `design/tokens/colors.json`).
enum Repo {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("design/tokens/colors.json").path) {
                return url
            }
        }
        fatalError("raiz do repositório não encontrada a partir de \(#filePath)")
    }()

    static func json(_ relative: String) -> [String: Any] {
        let url = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fatalError("JSON ilegível: \(relative)") }
        return obj
    }

    static func text(_ relative: String) -> String {
        guard let s = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        else { fatalError("arquivo ilegível: \(relative)") }
        return s
    }

}

/// Cor lida de um JSON: `#rrggbb` ou `#rrggbbaa`.
struct HexColor: Equatable {
    var rgb: UInt32
    var alphaByte: Int?

    init?(_ string: String) {
        var s = string.lowercased()
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            rgb = UInt32(v)
            alphaByte = nil
        } else {
            rgb = UInt32(v >> 8)
            alphaByte = Int(v & 0xFF)
        }
    }
}

/// Achata folhas numéricas com chave pontilhada (mesma regra do gerador).
func flattenNumbers(_ value: Any, prefix: String = "", into out: inout [String: Double]) {
    if let dict = value as? [String: Any] {
        for (k, v) in dict { flattenNumbers(v, prefix: prefix.isEmpty ? k : "\(prefix).\(k)", into: &out) }
    } else if let arr = value as? [Any] {
        for (i, v) in arr.enumerated() { flattenNumbers(v, prefix: "\(prefix).\(i)", into: &out) }
    } else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
        out[prefix] = n.doubleValue
    }
}

func flattenStrings(_ value: Any, prefix: String = "", into out: inout [String: String]) {
    if let dict = value as? [String: Any] {
        for (k, v) in dict { flattenStrings(v, prefix: prefix.isEmpty ? k : "\(prefix).\(k)", into: &out) }
    } else if let arr = value as? [Any] {
        for (i, v) in arr.enumerated() { flattenStrings(v, prefix: "\(prefix).\(i)", into: &out) }
    } else if let s = value as? String {
        out[prefix] = s
    }
}

/// Tokens de cor do JSON fonte, em ordem de grupo.
struct ColorSource {
    struct Token {
        var name: String
        var dark: String
        var opacity: Double?
        var reference: String?
        var light: String?
        var note: String?
    }

    static func load() -> (tokens: [Token], terminal: [String: Any]) {
        let doc = Repo.json("design/tokens/colors.json")
        var tokens: [Token] = []
        for g in doc["groups"] as? [[String: Any]] ?? [] {
            let toks = g["tokens"] as? [String: Any] ?? [:]
            for (name, raw) in toks {
                let d = raw as? [String: Any] ?? [:]
                tokens.append(Token(
                    name: name, dark: d["dark"] as? String ?? "",
                    opacity: (d["opacity"] as? NSNumber)?.doubleValue,
                    reference: d["reference"] as? String, light: d["light"] as? String, note: d["note"] as? String))
            }
        }
        return (tokens, doc["terminal"] as? [String: Any] ?? [:])
    }
}

