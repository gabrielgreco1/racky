import Foundation

/// Preço por milhão de tokens, em USD.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
    }

    /// Cache read = 0,1× entrada; cache write 5 min = 1,25×; 1 h = 2× (convenção publicada para os modelos Claude).
    public static func claude(input: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: input * 0.1, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2)
    }

    public func cost(_ c: TokenCounts) -> Double {
        (Double(c.input) * input + Double(c.output) * output + Double(c.cacheRead) * cacheRead
            + Double(c.cacheWrite5m) * cacheWrite5m + Double(c.cacheWrite1h) * cacheWrite1h) / 1_000_000
    }
}

/// Tabela de preços configurável. O custo é uma ESTIMATIVA: a fonte da verdade é a fatura do provedor.
/// A primeira entrada cujo `match` está contido no nome do modelo (sem caixa) vence; ponha as específicas primeiro.
public struct PriceTable: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var match: String
        public var price: ModelPrice
        public init(match: String, price: ModelPrice) { self.match = match; self.price = price }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        return entries.first { m.contains($0.match.lowercased()) }?.price
    }

    /// `nil` quando o modelo não tem preço (o agregado lista o modelo em `unpricedModels`).
    public func cost(model: String, counts: TokenCounts) -> Double? {
        price(for: model)?.cost(counts)
    }

    public static let `default` = PriceTable(entries: [
        Entry(match: "opus", price: .claude(input: 5, output: 25)),
        Entry(match: "sonnet", price: .claude(input: 3, output: 15)),
        Entry(match: "haiku", price: .claude(input: 1, output: 5)),
        Entry(match: "codex", price: ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
        // Família GPT em geral: usa a tarifa do gpt-5 como estimativa até o usuário configurar a do modelo novo.
        Entry(match: "gpt-", price: ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
    ])

    /// Lê o override do usuário (JSON `{"entries":[{"match":"opus","price":{...}}]}`); qualquer falha cai no padrão.
    public static func load(from url: URL) -> PriceTable {
        guard let data = try? Data(contentsOf: url), let table = try? JSONDecoder().decode(PriceTable.self, from: data), !table.entries.isEmpty else {
            return .default
        }
        return table
    }
}
