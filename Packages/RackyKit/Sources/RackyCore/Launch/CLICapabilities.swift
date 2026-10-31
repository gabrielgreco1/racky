import Foundation

/// Flag (ou subcomando) que o adapter usa, com o piso de versão verificado (06 §2.2).
/// `since == nil`: existe em todas as versões conhecidas do CLI. Um piso é o MENOR número em que a flag foi
/// vista no `--help` real; versões anteriores ficam "não suportadas" (conservador) até alguém conferir.
public struct FlagRule: Sendable, Hashable {
    public let flag: String
    public let since: CLIVersion?
    /// Rótulo curto para a UI ("Effort", "Shared server opt-out").
    public let label: String

    public init(_ flag: String, since: CLIVersion? = nil, label: String) {
        self.flag = flag; self.since = since; self.label = label
    }
}

/// Resultado do parse de `--help` (texto cru): flags longas e curtas, e subcomandos.
public struct ParsedHelp: Sendable, Equatable {
    public var flags: Set<String>
    public var subcommands: Set<String>
    /// `--help` real sempre lista dezenas de flags; poucas flags = saída inesperada (erro, banner), não use como verdade.
    public var isUsable: Bool { flags.count >= 5 }
}

public enum HelpParser {
    /// Aceita os dois formatos reais: commander (Claude: `  -r, --resume [value]   desc`), clap (Codex: `  -c, --config <k=v>` e
    /// descrição na linha seguinte) e yargs (OpenCode: `  -m, --model   desc`).
    public static func parse(_ text: String) -> ParsedHelp {
        var flags = Set<String>()
        var subcommands = Set<String>()
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !line.hasPrefix(" "), trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast()).lowercased()
                continue
            }
            // Linhas de opção têm recuo de até 6 colunas (clap usa 6 para flags sem forma curta); descrições recuam mais.
            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("-"), indent <= 6 {
                // Só o "cabeçalho" da opção: até 2+ espaços seguidos (início da descrição) ou o fim da linha.
                let head = trimmed.split(separator: /\s{2,}/, maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
                for token in head.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "|" }) {
                    if token.hasPrefix("--") {
                        let name = token.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
                        if name.count > 2 { flags.insert(String(name)) }
                    } else if token.count == 2, token.hasPrefix("-"), token.last?.isLetter == true {
                        flags.insert(String(token))
                    }
                }
                continue
            }
            if section == "commands", line.hasPrefix("  "), !line.hasPrefix("   ") || trimmed.hasPrefix("opencode") {
                var words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                if words.first == "opencode" || words.first == "claude" || words.first == "codex" { words.removeFirst() }
                if let first = words.first, first.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil {
                    subcommands.insert(first)
                }
            }
        }
        return ParsedHelp(flags: flags, subcommands: subcommands)
    }
}

/// O que a versão detectada de um CLI sabe fazer. Flag ausente = opção desabilitada na UI, com o motivo.
public struct CLICapabilities: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable { case help, versionTable, baseline }

    public var version: CLIVersion?
    public var flags: Set<String>
    public var subcommands: Set<String>
    public var source: Source

    public init(version: CLIVersion?, flags: Set<String>, subcommands: Set<String> = [], source: Source) {
        self.version = version; self.flags = flags; self.subcommands = subcommands; self.source = source
    }

    public func supports(_ flag: String) -> Bool { flags.contains(flag) }
    public func supports(subcommand: String) -> Bool { subcommands.contains(subcommand) }

    /// `--help` utilizável vence (é o que o binário instalado realmente aceita); sem ele, a tabela por versão.
    public static func resolve(version: CLIVersion?, help: ParsedHelp?, adapter: any ProviderAdapter) -> CLICapabilities {
        if let help, help.isUsable {
            return CLICapabilities(version: version, flags: help.flags, subcommands: help.subcommands, source: .help)
        }
        guard let version else {
            return CLICapabilities(version: nil, flags: [], subcommands: [], source: .versionTable)
        }
        let flags = adapter.flagRules.filter { rule in rule.since.map { version >= $0 } ?? true }.map(\.flag)
        let subs = adapter.subcommandRules.filter { rule in rule.since.map { version >= $0 } ?? true }.map(\.flag)
        return CLICapabilities(version: version, flags: Set(flags), subcommands: Set(subs), source: .versionTable)
    }

    /// Tudo que a tabela declara, como nas versões verificadas (testes e lançamentos sem sonda).
    public static func baseline(for adapter: any ProviderAdapter) -> CLICapabilities {
        CLICapabilities(
            version: nil,
            flags: Set(adapter.flagRules.map(\.flag)),
            subcommands: Set(adapter.subcommandRules.map(\.flag)),
            source: .baseline
        )
    }

    /// Texto da UI para uma opção desabilitada ("Requires Claude Code ≥ 2.1.302").
    public static func unsupportedReason(flag: String, adapter: any ProviderAdapter) -> String {
        if let rule = adapter.flagRules.first(where: { $0.flag == flag }), let since = rule.since {
            return "Requires \(adapter.displayName) ≥ \(since)"
        }
        return "Not supported by this version of \(adapter.displayName)"
    }
}
