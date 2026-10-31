import Foundation

/// Uma falha de check com o trecho de log (quando existe) para o texto de "Send Failures to {Agent}".
public struct CheckFailureEntry: Sendable, Equatable {
    public let check: CheckItem
    public let logExcerpt: String?

    public init(check: CheckItem, logExcerpt: String? = nil) {
        self.check = check
        self.logExcerpt = logExcerpt
    }
}

/// Formatador puro do texto de falhas de check para colar no agente (06 §5.7). Não cola nem executa nada.
public enum CheckFailureFormatter {
    public static let maxLinesPerJob = 120
    public static let maxTotalLogBytes = 12 * 1024

    /// Template padrão (editável em Settings › GitHub). Marcadores: `{number}`, `{url}`, `{title}`, `{failures}`.
    public static let defaultTemplate = """
    CI checks failed on PR #{number} ({url}):
    {failures}
    Please investigate and fix.
    """

    /// Checks que entram no texto: `FAILURE`, `TIMED_OUT`, `ACTION_REQUIRED`, `CANCELLED` (e StatusContext com falha).
    public static func failures(in pullRequest: PullRequestStatus) -> [CheckItem] {
        pullRequest.checks.items.filter(\.isFailure)
    }

    public static func format(pullRequest: PullRequestStatus, entries: [CheckFailureEntry],
                              template: String = defaultTemplate) -> String {
        var remaining = maxTotalLogBytes
        var blocks: [String] = []
        for entry in entries {
            var block = "- \(entry.check.name) (\(provider(of: entry.check))): \(entry.check.url ?? "no link")"
            if let raw = entry.logExcerpt, entry.check.workflowRunId != nil {
                let cleaned = cleanLog(raw)
                if !cleaned.isEmpty, remaining > 0 {
                    let fitted = fit(cleaned, bytes: remaining)
                    remaining -= fitted.utf8.count
                    block += "\n" + fitted.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "  " + $0 }.joined(separator: "\n")
                }
            }
            blocks.append(block)
        }
        return template
            .replacingOccurrences(of: "{number}", with: String(pullRequest.number))
            .replacingOccurrences(of: "{url}", with: pullRequest.url)
            .replacingOccurrences(of: "{title}", with: pullRequest.title)
            .replacingOccurrences(of: "{failures}", with: blocks.joined(separator: "\n"))
    }

    static func provider(of check: CheckItem) -> String {
        check.workflowRunId != nil ? "GitHub Actions" : "external check"
    }

    /// Remove ANSI e timestamps, descarta o prefixo `job<TAB>step<TAB>` do `gh run view --log-failed` e fica
    /// com as últimas `maxLinesPerJob` linhas não vazias.
    public static func cleanLog(_ raw: String, maxLines: Int = maxLinesPerJob) -> String {
        let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
        let timestamp = try? NSRegularExpression(pattern: #"^\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?"#)
        var lines: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine).replacingOccurrences(of: "\r", with: "")
            if let ansi { line = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "") }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 { line = String(parts[2]) }
            if let timestamp {
                line = timestamp.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Mantém o fim do log (onde costuma estar o erro) dentro de `bytes`, marcando o corte.
    static func fit(_ text: String, bytes: Int) -> String {
        if text.utf8.count <= bytes { return text }
        let marker = "[... truncated ...]\n"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while !lines.isEmpty, (marker + lines.joined(separator: "\n")).utf8.count > bytes { lines.removeFirst() }
        if lines.isEmpty { return String(marker.dropLast()) }
        return marker + lines.joined(separator: "\n")
    }
}
