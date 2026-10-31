import RackyDocker
import CryptoKit
import Foundation

// T3-06, 07 CS-262/263/303: o que `box_collect` e a aba "Result" mostram. Lê só o run folder (o computador pode já ter sido removido):
// `work/result.json`, `logs/validation.json`, reqlog, diário e timeline. A validação é refeita contra o reqlog de hoje, então um
// `result.json` reescrito à mão depois do `result_submit` volta marcado (padrão de ids) em vez de herdar marcas velhas.

/// Uma citação de evidência já resolvida: o request do reqlog (ou o arquivo de `/work`) que sustenta um campo.
public struct EvidenceLink: Sendable, Equatable, Identifiable {
    public var id: String { ref }
    public var ref: String
    public var kind: Citation.Kind
    public var exists: Bool
    /// `observed` ou `reported` (só request que existe): vira o selo `"Observed"` / `"Agent-reported"` (CS-263).
    public var trust: String?
    /// `200 GET https://host/path` para request; tamanho para arquivo.
    public var summary: String?
    /// Arquivo de `/work` no host (só quando existe): `Reveal in Finder`.
    public var fileURL: URL?

    public var json: JSON {
        var o: [String: JSON] = ["ref": .string(ref), "kind": .string(kind.rawValue), "exists": .bool(exists)]
        if let trust { o["trust"] = .string(trust) }
        if let summary { o["summary"] = .string(summary) }
        if let fileURL { o["path"] = .string(fileURL.path) }
        return .object(o)
    }
}

/// Um campo de topo (ou apontado por `evidence`) do resultado, com a marca e os links de evidência.
public struct FieldReport: Sendable, Equatable, Identifiable {
    public var id: String { pointer }
    public var pointer: String
    public var status: FieldStatus
    /// Valor em uma linha (até 140 caracteres).
    public var preview: String
    public var links: [EvidenceLink]

    /// Rótulo da marca na UI (AC-421): `Verified`, `Cited request not found`, `Not verified`.
    public var statusLabel: String {
        switch status {
        case .verified: "Verified"
        case .citedMissing: "Cited request not found"
        case .notVerified: "Not verified"
        }
    }
}

public struct CollectedRun: Sendable, Equatable {
    public enum Section: String, Sendable, CaseIterable { case result, validation, timeline, transcriptSummary = "transcript_summary" }

    public var name: String
    public var run: RunFolder
    public var metadata: RunMetadata?
    public var result: JSON?
    /// Por que não há resultado (`No result.json yet`, JSON inválido...).
    public var resultNote: String?
    public var fields: [FieldReport]
    /// `true` quando a validação veio do padrão de ids (resultado escrito à mão, sem `result_submit`).
    public var handwritten: Bool
    public var timelineMarkdown: String?
    public var transcriptSummary: String?
    public var integrity: ReqlogIntegrity
    public var usage: JSON
    public var durationSeconds: Int?

    public init(
        name: String, run: RunFolder, metadata: RunMetadata? = nil, result: JSON? = nil, resultNote: String? = nil, fields: [FieldReport] = [], handwritten: Bool = false,
        timelineMarkdown: String? = nil, transcriptSummary: String? = nil, integrity: ReqlogIntegrity = .ok(lines: 0), usage: JSON = [:], durationSeconds: Int? = nil
    ) {
        self.name = name; self.run = run; self.metadata = metadata; self.result = result; self.resultNote = resultNote; self.fields = fields
        self.handwritten = handwritten; self.timelineMarkdown = timelineMarkdown; self.transcriptSummary = transcriptSummary; self.integrity = integrity
        self.usage = usage; self.durationSeconds = durationSeconds
    }

    public var verified: Int { fields.filter { $0.status == .verified }.count }
    public var citedMissing: Int { fields.filter { $0.status == .citedMissing }.count }
    public var notVerified: Int { fields.filter { $0.status == .notVerified }.count }
    public var totalFields: Int { fields.count }
    public var hasResult: Bool { result != nil }

    public var validationJSON: JSON {
        [
            "fields": .array(fields.map { f in
                ["pointer": .string(f.pointer), "status": .string(f.status.rawValue), "citations": .array(f.links.map(\.json))]
            }),
            "summary": ["verified": .int(verified), "cited_missing": .int(citedMissing), "not_verified": .int(notVerified)],
            "handwritten": .bool(handwritten),
        ]
    }

    public var paths: JSON { ["run": .string(run.root.path), "work": .string(run.work.path), "logs": .string(run.logs.path)] }

    /// A resposta de `box_collect` (07 §4.2): `result`, `validation`, `timeline_md`, `transcript_summary` conforme `include`, mais
    /// `paths`, `usage`, `duration_s` e `summary_md` (markdown de até `limit` caracteres, CS-303).
    public func json(include: Set<Section> = Set(Section.allCases), limit: Int = RunCollector.summaryLimit) -> JSON {
        var out: [String: JSON] = ["box": .string(name), "paths": paths, "usage": usage, "integrity": .string(integrity.message)]
        if let durationSeconds { out["duration_s"] = .int(durationSeconds) }
        if let outcome = metadata?.outcome { out["run"] = .string(outcome.rawValue) }
        if include.contains(.result) {
            if let result {
                // Resultado enorme não vai inteiro no retorno da ferramenta (o limite é do resumo): fica o caminho.
                if result.text.count > limit { out["result"] = ["truncated": true, "path": .string(run.resultFile.path)] } else { out["result"] = result }
            } else {
                out["result"] = .null
                if let resultNote { out["result_note"] = .string(resultNote) }
            }
        }
        if include.contains(.validation) { out["validation"] = validationJSON }
        if include.contains(.timeline), let timelineMarkdown { out["timeline_md"] = .string(String(timelineMarkdown.suffix(limit / 2))) }
        if include.contains(.transcriptSummary), let transcriptSummary { out["transcript_summary"] = .string(transcriptSummary) }
        out["summary_md"] = .string(summaryMarkdown(limit: limit))
        return .object(out)
    }

    /// Markdown para o pai: marca por campo (as sem evidência voltam marcadas), caminhos e o fim da timeline. Até `limit` caracteres.
    public func summaryMarkdown(limit: Int = RunCollector.summaryLimit) -> String {
        var lines: [String] = []
        lines.append("# \(name): \(verified) verified · \(citedMissing) cited request not found · \(notVerified) not verified")
        var facts: [String] = [integrity.message]
        if let durationSeconds { facts.append("duration \(RunCollector.duration(durationSeconds))") }
        if let requests = usage["requests"]?.int { facts.append("\(requests) proxy requests") }
        lines.append(facts.joined(separator: " · "))
        lines.append("Run folder: \(run.root.path)")
        lines.append("")
        if result == nil {
            lines.append("No result: \(resultNote ?? "result.json is missing")")
        } else {
            if handwritten { lines.append("_result.json was not written by result_submit: evidence ids were found by pattern._") }
            lines.append("| Field | Value | Status | Evidence |")
            lines.append("|---|---|---|---|")
            for field in fields {
                let evidence = field.links.isEmpty ? "-" : field.links.map { $0.exists ? $0.ref : "\($0.ref) (not found)" }.joined(separator: ", ")
                lines.append("| \(RunCollector.cell(field.pointer)) | \(RunCollector.cell(field.preview)) | \(field.statusLabel) | \(RunCollector.cell(evidence)) |")
            }
        }
        if let transcriptSummary, !transcriptSummary.isEmpty { lines += ["", "## Last words", transcriptSummary] }
        var text = lines.joined(separator: "\n")
        if let timelineMarkdown, !timelineMarkdown.isEmpty {
            let room = limit - text.count - 40
            if room > 200 {
                let tail = String(timelineMarkdown.suffix(min(room, limit / 2)))
                text += "\n\n## Timeline (end)\n" + tail
            }
        }
        if text.count > limit {
            let marker = "\n… truncated (see the run folder)"
            text = String(text.prefix(max(0, limit - marker.count))) + marker
        }
        return text
    }
}

public enum RunCollector {
    /// CS-303: o resumo devolvido ao pai tem até 20 mil caracteres.
    public static let summaryLimit = 20_000
    static let maxResultBytes = 4 << 20

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    /// Lê o run e monta o relatório. `usage` e `timeline` vêm do computador vivo, quando há; sem eles, `logs/usage.json` e
    /// `logs/timeline.md`. Não escreve nada.
    public static func collect(run: RunFolder, name: String, usage: JSON? = nil, timeline: String? = nil, now: Date = Date()) -> CollectedRun {
        let metadata = run.readMetadata()
        var result: JSON?
        var resultData: Data?
        var note: String?
        do {
            let data = try PathGuard.read(root: run.work, "/work/result.json", maxBytes: maxResultBytes)
            resultData = data
            if let parsed = try? JSON.parse(data) {
                if parsed.object != nil { result = parsed } else { note = "result.json must be an object" }
            } else { note = "result.json is not valid JSON" }
        } catch let error as ToolError {
            note = error.code == .notFound ? "No result.json yet" : error.message
        } catch { note = "result.json could not be read" }

        let entries = ChainedLog.read(run.requestsFile)
        var requests: [String: [String: JSON]] = [:]
        var trusts: [String: String] = [:]
        for entry in entries { if let id = entry["id"]?.string { requests[id] = entry; trusts[id] = entry["trust"]?.string ?? "observed" } }
        let validator = ResultValidator(requests: trusts) { [work = run.work] ref in PathGuard.exists(root: work, ref) }

        var validation: ResultValidation?
        var handwritten = false
        if let result, let resultData {
            if let stored = storedEvidence(run: run, resultHash: sha256(resultData)), let checked = try? validator.validate(result: result, evidence: stored) {
                validation = checked
            } else {
                validation = try? validator.validateHandwritten(resultData: resultData)
                handwritten = true
            }
        }
        let fields = (validation?.fields ?? []).map { field in
            FieldReport(
                pointer: field.pointer, status: field.status, preview: result.flatMap { ResultValidator.resolve(field.pointer, in: $0) }.map(preview) ?? "",
                links: field.citations.map { link($0, requests: requests, run: run) })
        }

        let integrity = integrity(run)
        var timelineText = timeline
        if timelineText == nil, let data = try? Data(contentsOf: run.timelineFile) { timelineText = String(decoding: data.suffix(summaryLimit), as: UTF8.self) }
        var usageJSON = usage
        if usageJSON == nil, let data = try? Data(contentsOf: run.usageFile) { usageJSON = try? JSON.parse(data) }
        var duration = metadata?.durationSeconds
        if duration == nil, let metadata, metadata.outcome == .running { duration = max(0, Int(now.timeIntervalSince(metadata.startedAt))) }

        return CollectedRun(
            name: name, run: run, metadata: metadata, result: result, resultNote: note, fields: fields, handwritten: handwritten,
            timelineMarkdown: timelineText, transcriptSummary: transcriptSummary(run), integrity: integrity,
            usage: usageJSON ?? ["requests": 0, "tunnels": 0, "bytes": 0, "renders": 0], durationSeconds: duration)
    }

    /// Citações gravadas pelo `result_submit` (ponteiro -> refs), só se o `result.json` ainda é o que ele escreveu.
    static func storedEvidence(run: RunFolder, resultHash: String) -> [String: [String]]? {
        guard let data = try? Data(contentsOf: run.validationFile), let json = try? JSON.parse(data), json["result_sha256"]?.string == resultHash,
              let fields = json["fields"]?.array else { return nil }
        var out: [String: [String]] = [:]
        for field in fields {
            guard let pointer = field["pointer"]?.string else { continue }
            let refs = (field["citations"]?.array ?? []).compactMap { $0["ref"]?.string }
            if !refs.isEmpty { out[pointer] = refs }
        }
        return out
    }

    static func preview(_ value: JSON) -> String {
        let text: String
        if case .string(let s) = value { text = s } else { text = value.text }
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    static func link(_ citation: Citation, requests: [String: [String: JSON]], run: RunFolder) -> EvidenceLink {
        switch citation.kind {
        case .request:
            var summary: String?
            if let entry = requests[citation.ref] {
                let status = entry["status"]?.int.map(String.init) ?? "ERR"
                summary = "\(status) \(entry["method"]?.string ?? "GET") \(String((entry["url"]?.string ?? "").prefix(120)))"
            }
            return EvidenceLink(ref: citation.ref, kind: .request, exists: citation.exists, trust: citation.trust, summary: summary, fileURL: nil)
        case .file:
            var url: URL?
            var summary: String?
            if citation.exists, let parts = try? PathGuard.components(citation.ref) {
                url = parts.reduce(run.work) { $0.appendingPathComponent($1) }
                if let size = (try? FileManager.default.attributesOfItem(atPath: url?.path ?? ""))?[.size] as? NSNumber {
                    summary = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
                }
            }
            return EvidenceLink(ref: citation.ref, kind: .file, exists: citation.exists, trust: nil, summary: summary, fileURL: url)
        }
    }

    static func integrity(_ run: RunFolder) -> ReqlogIntegrity {
        for file in [run.requestsFile, run.file("journal.jsonl")] {
            if case .tampered(let line) = (try? ReqlogIntegrity.verify(file: file)) ?? .ok(lines: 0) { return .tampered(line: line) }
        }
        return .ok(lines: ChainedLog.read(run.requestsFile).count)
    }

    /// As últimas falas do filho (cópia indexada do transcript, quando o app já a fez).
    static func transcriptSummary(_ run: RunFolder) -> String? {
        let entries = ChainedLog.read(run.transcript.appendingPathComponent("agent.jsonl"))
        let texts = entries.compactMap { $0["text"]?.string }.filter { !$0.isEmpty }.suffix(3)
        guard !texts.isEmpty else { return nil }
        return String(texts.joined(separator: "\n").prefix(2000))
    }
}
