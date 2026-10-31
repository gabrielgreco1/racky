import Foundation

// T3-07: exportação do consolidado do lote (CSV e JSON); a UI não grava arquivo.

public enum BatchExportFormat: String, Sendable, CaseIterable { case csv, json }

public enum BatchExporter {
    /// `listings-oct.csv` / `listings-oct.json`: nome sugerido no painel de salvar.
    public static func suggestedName(batch: String, format: BatchExportFormat) -> String { "\(BatchLedger.safe(batch)).\(format.rawValue)" }

    public static func data(_ summary: BatchSummary, format: BatchExportFormat) -> Data {
        switch format {
        case .csv: Data(summary.csv().utf8)
        case .json: summary.json().data(pretty: true)
        }
    }

    @discardableResult
    public static func write(_ summary: BatchSummary, format: BatchExportFormat, to url: URL) throws -> URL {
        try data(summary, format: format).write(to: url, options: .atomic)
        return url
    }
}
