import Foundation

/// Tipos de tarefa que a tabela de modelos conhece. O orquestrador diz qual é no `agent_spawn`.
public enum ModelSkill: String, Codable, Sendable, CaseIterable {
    case plan, browse, extract, code, smallEdit = "small_edit", review
}

/// Uma medição publicada: benchmark, artigo ou leaderboard, com fonte e data. Nunca estimada.
public struct ModelReference: Codable, Hashable, Sendable {
    public var model: String
    public var skill: ModelSkill
    public var benchmark: String
    public var score: String
    public var higherIsBetter: Bool
    public var sourceURL: String
    public var sourceDate: String
    /// Medido por terceiros (Vals, Artificial Analysis…) e não pelo próprio fabricante.
    public var independent: Bool
    /// Tirado de um artigo que cita o número, não da página original.
    public var secondary: Bool
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case model, skill, benchmark, score, note, independent, secondary
        case higherIsBetter = "higher_is_better", sourceURL = "source_url", sourceDate = "source_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        skill = try c.decode(ModelSkill.self, forKey: .skill)
        benchmark = try c.decode(String.self, forKey: .benchmark)
        score = try c.decode(String.self, forKey: .score)
        higherIsBetter = try c.decodeIfPresent(Bool.self, forKey: .higherIsBetter) ?? true
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        sourceDate = try c.decode(String.self, forKey: .sourceDate)
        independent = try c.decodeIfPresent(Bool.self, forKey: .independent) ?? false
        secondary = try c.decodeIfPresent(Bool.self, forKey: .secondary) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// O número do placar ("65.15%", "1846 Elo", "58"); `nil` quando a fonte só dá posição ou texto.
    public var value: Double? {
        let digits = score.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }
}

public struct ReferencePrice: Codable, Hashable, Sendable {
    public var model: String
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var sourceURL: String
    public var sourceDate: String
    public var secondary: Bool

    enum CodingKeys: String, CodingKey {
        case model, secondary
        case inputPerMTok = "input_per_mtok_usd", outputPerMTok = "output_per_mtok_usd", sourceURL = "source_url", sourceDate = "source_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        inputPerMTok = try c.decode(Double.self, forKey: .inputPerMTok)
        outputPerMTok = try c.decode(Double.self, forKey: .outputPerMTok)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        sourceDate = try c.decode(String.self, forKey: .sourceDate)
        secondary = try c.decodeIfPresent(Bool.self, forKey: .secondary) ?? false
    }
}

/// A base externa: o que estudos e leaderboards dizem de cada modelo, por tipo de tarefa. Vem com o app
/// (`Resources/ModelReferences/refs.json`) e é o ponto de partida da tabela até o placar do usuário ter dados.
public struct ModelReferences: Codable, Sendable {
    public var generated: String
    public var entries: [ModelReference]
    public var prices: [ReferencePrice]

    public static func bundled() throws -> ModelReferences {
        guard let url = Bundle.module.url(forResource: "refs", withExtension: "json", subdirectory: "ModelReferences") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(ModelReferences.self, from: Data(contentsOf: url))
    }

    /// Medições daquele modelo (pela chave de família) naquele tipo de tarefa; as de fonte original primeiro.
    public func references(family: String, skill: ModelSkill) -> [ModelReference] {
        entries.filter { ModelFamily.key($0.model) == family && $0.skill == skill }
            .sorted { ($0.secondary ? 1 : 0, $0.independent ? 0 : 1) < ($1.secondary ? 1 : 0, $1.independent ? 0 : 1) }
    }

    /// Preço de fonte original quando houver; senão o de artigo.
    public func price(family: String) -> ReferencePrice? {
        prices.filter { ModelFamily.key($0.model) == family }.min { (!$0.secondary ? 0 : 1) < (!$1.secondary ? 0 : 1) }
    }
}
