import RackyDocker
import Foundation

// T3-07, 03 §16.15, 07 CS-324: o pedido do "New Batch…". O app não orquestra: monta o prompt inicial do terminal Claude pai (que já nasce
// com a skill de orquestração) e o pai cria os filhos. Tipos puros: leitura da lista ou CSV de alvos, modelo de brief e o prompt.

public struct BatchTarget: Sendable, Equatable, Identifiable {
    /// Nome do computador (slug): `phoenix-az`.
    public var name: String
    public var id: String { name }
    /// Colunas do CSV (`city`, `state`...) para `{{city}}` no brief.
    public var columns: [String: String]

    public init(name: String, columns: [String: String] = [:]) { self.name = name; self.columns = columns }
}

public struct NewBatchRequest: Sendable, Equatable {
    public var name: String
    public var targets: [BatchTarget]
    public var brief: String
    public var display: ComputerDisplay
    /// `nil` = o padrão de Settings.
    public var proxy: String?
    public var allowedProxies: [String]

    public init(
        name: String, targets: [BatchTarget], brief: String, display: ComputerDisplay = .headless, proxy: String? = nil, allowedProxies: [String] = []
    ) {
        self.name = name; self.targets = targets; self.brief = brief; self.display = display; self.proxy = proxy; self.allowedProxies = allowedProxies
    }
}

public enum NewBatchPrompt {
    /// Brief inicial do editor: as três partes obrigatórias do template do worker, com os marcadores.
    public static let defaultBrief = """
        TASK: <what to find for {{target}}, one paragraph>
        WHAT WE ALREADY KNOW: <known URLs, endpoints, earlier findings, access notes; "nothing yet" if empty>
        OUTPUT: <the exact JSON shape for result_submit: fields, types, one example>
        """

    static let maxTargets = 100

    /// Um nome de computador válido (letras, dígitos, `.`, `_`, `-`; até 100) a partir de texto livre.
    public static func slug(_ text: String) -> String {
        var out = ""
        var dash = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.unicodeScalars.append(scalar)
            } else { dash = true }
        }
        while let last = out.last, last == "-" || last == "." || last == "_" { out.removeLast() }
        // O nome do computador começa por letra ou dígito (`boxes_reserve` recusa o resto).
        while let first = out.first, first == "-" || first == "." || first == "_" { out.removeFirst() }
        return String(out.prefix(100))
    }

    /// Linhas de um CSV (RFC 4180: aspas, aspas duplas escapadas, vírgula e quebra de linha dentro de aspas).
    public static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()
        func endCell() { row.append(cell); cell = "" }
        func endRow() { endCell(); if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }
        while let ch = pending {
            pending = iterator.next()
            if quoted {
                if ch == "\"" {
                    if pending == "\"" { cell.append("\""); pending = iterator.next() } else { quoted = false }
                } else { cell.append(ch) }
            } else if ch == "\"" && cell.isEmpty {
                quoted = true
            } else if ch == "," {
                endCell()
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                endRow()
            } else { cell.append(ch) }
        }
        if !cell.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Lista (uma linha por alvo) ou CSV. Com CSV (primeira linha com mais de uma coluna), a coluna `name`/`target` (ou a primeira)
    /// dá o nome e as demais viram `{{coluna}}`. Linhas vazias e nomes repetidos somem; no máximo 100 alvos.
    public static func parseTargets(_ text: String) -> [BatchTarget] {
        let rows = parseCSV(text)
        guard let header = rows.first else { return [] }
        var targets: [BatchTarget] = []
        var seen = Set<String>()
        func add(_ target: BatchTarget) {
            guard !target.name.isEmpty, targets.count < maxTargets, seen.insert(target.name).inserted else { return }
            targets.append(target)
        }
        if header.count > 1 {
            let names = header.map { $0.trimmingCharacters(in: .whitespaces) }
            let nameIndex = names.firstIndex { ["name", "target"].contains($0.lowercased()) } ?? 0
            for row in rows.dropFirst() {
                var columns: [String: String] = [:]
                for (i, column) in names.enumerated() where i < row.count && !column.isEmpty { columns[column] = row[i].trimmingCharacters(in: .whitespaces) }
                let raw = nameIndex < row.count ? row[nameIndex] : ""
                add(BatchTarget(name: slug(raw), columns: columns))
            }
        } else {
            for row in rows { add(BatchTarget(name: slug(row[0]), columns: ["target": row[0].trimmingCharacters(in: .whitespaces)])) }
        }
        return targets
    }

    /// Substitui `{{target}}` e `{{coluna}}` pelos valores do alvo; marcador desconhecido fica como está.
    public static func render(brief: String, target: BatchTarget) -> String {
        var out = brief
        var values = target.columns
        values["target"] = target.name
        for (key, value) in values { out = out.replacingOccurrences(of: "{{\(key)}}", with: value) }
        return out
    }

    /// Texto de um CSV ou lista no disco (até 1 MB); `nil` se não lê.
    public static func loadTargets(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nome de lote padrão: `batch-261020-1430`.
    public static func defaultName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmm"
        return "batch-" + f.string(from: date)
    }

    /// O pedido inicial do terminal Claude pai. Só a skill de orquestração (injetada por lançamento) sabe os passos; aqui vão os dados.
    public static func prompt(for request: NewBatchRequest) -> String {
        let names = request.targets.map(\.name)
        var reserve = "boxes_reserve(names: [\(names.map { "\"\($0)\"" }.joined(separator: ", "))], display: \"\(request.display.rawValue)\", batch: \"\(request.name)\""
        if let proxy = request.proxy { reserve += ", proxy: \"\(proxy)\"" }
        if !request.allowedProxies.isEmpty { reserve += ", proxies_allowed: [\(request.allowedProxies.map { "\"\($0)\"" }.joined(separator: ", "))]" }
        reserve += ")"
        var lines = [
            "Run a batch named \"\(request.name)\" with \(request.targets.count) target\(request.targets.count == 1 ? "" : "s"), one Racky computer and one worker subagent per target.",
            "",
            "1. Reserve all computers in ONE call: \(reserve).",
            "2. Spawn one background worker per computer with the brief below, replacing {{...}} with that target's values.",
            "3. When the workers finish, call batch_collect(\"\(request.name)\") and answer with a table per target: status, key findings, evidence ids, what could not be verified.",
            "",
            "Targets:",
        ]
        for (index, target) in request.targets.enumerated() {
            let extra = target.columns.filter { $0.key != "target" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            lines.append("\(index + 1). \(target.name)" + (extra.isEmpty ? "" : " (\(extra))"))
        }
        lines += ["", "Brief template (COMPUTER: <name> goes first in each brief):", "```", request.brief, "```"]
        return lines.joined(separator: "\n")
    }
}
