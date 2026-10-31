import Foundation

/// Erros recentes lidos do log em disco (`logs/*.jsonl`, AR-602) para a tela Diagnostics e o pacote exportável.
public struct LoggedError: Sendable, Equatable, Identifiable {
    public var at: String
    public var process: String
    public var category: String
    public var message: String
    public var id: String { "\(at)|\(process)|\(category)|\(message)" }
    public var line: String { "\(at) [\(process)/\(category)] \(message)" }
}

public enum RecentErrors {
    /// Arquivos de `logs/` (JSONL e relatórios do MetricKit), em ordem estável.
    public static func logFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Lê o final de cada arquivo (até 512 KiB) e devolve os `limit` erros mais novos, do mais novo ao mais antigo.
    public static func read(logFiles: [URL], limit: Int = 10) -> [LoggedError] {
        var all: [LoggedError] = []
        for url in logFiles where url.pathExtension == "jsonl" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let window: UInt64 = 512 << 10
            try? handle.seek(toOffset: size > window ? size - window : 0)
            let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            for raw in text.split(separator: "\n") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any], object["level"] as? String == "error" else { continue }
                all.append(LoggedError(
                    at: object["t"] as? String ?? "", process: object["process"] as? String ?? "", category: object["category"] as? String ?? "",
                    message: object["msg"] as? String ?? ""))
            }
        }
        return Array(all.sorted { $0.at > $1.at }.prefix(limit))
    }
}
