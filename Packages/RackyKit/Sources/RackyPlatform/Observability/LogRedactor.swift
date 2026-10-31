import Foundation

/// Redação de texto de log e de diagnóstico (08 AR-602): padrões de token viram `‹redacted›` e `/Users/<nome>` vira `~`.
/// Roda ANTES de gravar em disco e de novo ao montar o pacote de diagnóstico (defesa em profundidade).
public enum LogRedactor {
    public static let marker = "‹redacted›"

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        /// Pré-filtro barato (minúsculas): a regex só roda na linha que contém algum destes trechos.
        let anchors: [String]
    }

    // Padrões fixos e testados (LogRedactorTests); a ordem importa: credenciais em URL e cabeçalhos antes dos prefixos soltos.
    private static let rules: [Rule] = {
        let m = NSRegularExpression.escapedTemplate(for: marker)
        let keywords = ["key", "token", "password", "passwd", "secret", "credential"]
        let table: [(String, String, [String])] = [
            // user:pass@ em URLs (proxy, remotes git); a chave Zyte vai como usuário (`http://<chave>:@host`).
            (#"(?i)([a-z][a-z0-9+.\-]*://)[^/\s:@"']+(?::[^/\s@"']*)?@"#, "$1\(m)@", ["://"]),
            // Cabeçalhos e atribuições de credenciais.
            (#"(?i)\b(authorization|proxy-authorization)(["']?\s*[:=]\s*["']?)(?:bearer|basic|token)\s+[^\s"',;]+"#, "$1$2\(m)", ["authorization"]),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]{6,}"#, "Bearer \(m)", ["bearer"]),
            (#"(?i)\b((?:x-)?api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd|secret|token|credentials?)(["']?\s*[:=]\s*["']?)[^\s"',;&]+"#, "$1$2\(m)", keywords),
            // Prefixos conhecidos de token.
            (#"sk-ant-[A-Za-z0-9_\-]{6,}"#, m, ["sk-ant-"]),
            (#"\bsk-[A-Za-z0-9_\-]{16,}"#, m, ["sk-"]),
            (#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, m, ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, m, ["github_pat_"]),
            (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, m, ["xox"]),
            (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, m, ["akia", "asia"]),
            (#"\bAIza[0-9A-Za-z_\-]{35}"#, m, ["aiza"]),
            (#"\b[sr]k_live_[0-9A-Za-z]{16,}"#, m, ["_live_"]),
            (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, m, ["eyj"]),
            // Pasta pessoal: `/Users/<nome>` vira `~` (o resto do caminho fica).
            (#"/Users/[^/\s"':;,)\]\}]+"#, "~", ["/users/"]),
        ]
        return table.compactMap { pattern, template, anchors in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(regex: $0, template: template, anchors: anchors) }
        }
    }()

    /// Redige linha a linha (logs JSONL têm uma entrada por linha): só aplica as regras cujo pré-filtro bate, o que mantém
    /// a exportação de 10 MB de log em poucos segundos.
    /// Chave privada PEM: o bloco ocupa várias linhas (ou fica numa só, com `\n` escapado em JSONL), então é redigido no texto inteiro,
    /// antes da divisão por linha. Sem o `END` (corte do log), leva também o corpo base64 que vem depois do `BEGIN`.
    private static let pem = try? NSRegularExpression(
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----(?:[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|[A-Za-z0-9+/=\s]*)"#)

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var text = text
        if text.contains("PRIVATE KEY"), let pem {
            text = pem.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: marker))
        }
        guard text.contains("\n") else { return redactLine(text) }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) { out.append(redactLine(String(line))) }
        return out.joined(separator: "\n")
    }

    private static func redactLine(_ line: String) -> String {
        let lower = line.lowercased()
        var result = line
        for rule in rules where rule.anchors.contains(where: { lower.contains($0) }) {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    /// `true` se ainda sobra algo que a redação pegaria (verificação do pacote antes de salvar).
    public static func isClean(_ text: String) -> Bool { redact(text) == text }
}
