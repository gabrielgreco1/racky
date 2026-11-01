import Foundation

/// Onde o livro-caixa de gasto mora entre execuções (o `CloudHostManager` só fala com isto).
public protocol SpendLedgerStore: Sendable {
    /// `SpendLedger()` vazio se ainda não existe; lança se o arquivo existe e está ilegível.
    func load() throws -> SpendLedger
    func save(_ ledger: SpendLedger) throws
}

/// JSON em um arquivo (a URL vem do app: pasta de dados). Escrita atômica; datas em ISO 8601.
public struct FileSpendLedgerStore: SpendLedgerStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> SpendLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return SpendLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SpendLedger.self, from: Data(contentsOf: url))
    }

    public func save(_ ledger: SpendLedger) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }
}
