import Foundation
import RackyStore
import Testing

@testable import RackyCore

/// Datasets v1: leitura de CSV / JSON Lines / JSON e exportadores (escape, guarda de fórmula).
@Suite struct DatasetImportExportTests {
    private func rows(_ parsed: ParsedImport) -> [[String: JSON]] { parsed.rows.compactMap { if case .row(let r) = $0 { r } else { nil } } }

    @Test func csvHandlesQuotesNewlinesCRLFAndBOM() throws {
        let text = "\u{FEFF}Hotel Name,Rating,Note\r\n\"Ritz, Paris\",4.5,\"said \"\"wow\"\"\"\r\n\r\n\"Two\nlines\",3,\r\nLast,2\r\n"
        let parsed = try DatasetImportParser.parse(Data(text.utf8), format: .csv)
        #expect(parsed.columns == ["hotel_name", "rating", "note"])
        let r = rows(parsed)
        #expect(r.count == 3, "the empty line is skipped")
        #expect(r[0] == ["hotel_name": "Ritz, Paris", "rating": "4.5", "note": "said \"wow\""])
        #expect(r[1]["hotel_name"] == "Two\nlines" && r[1]["note"] == "")
        #expect(r[2]["note"] == nil, "short rows leave the cell absent")
    }

    @Test func csvWithoutTrailingNewlineAndExtraCells() throws {
        let parsed = try DatasetImportParser.parse(Data("a,b\n1,2,3\n4,5".utf8), format: .csv)
        #expect(rows(parsed).count == 2 && parsed.extraCells == 1)
    }

    @Test func csvHeaderProblemsAreErrors() {
        #expect(throws: DatasetImportError.self) { try DatasetImportParser.parse(Data("a,a\n1,2\n".utf8), format: .csv) }
        #expect(throws: DatasetImportError.self) { try DatasetImportParser.parse(Data("a,\n1,2\n".utf8), format: .csv) }
        #expect(throws: DatasetImportError.self) { try DatasetImportParser.parse(Data("a,b\n".utf8), format: .csv) }
        #expect(throws: DatasetImportError.self) { try DatasetImportParser.parse(Data("".utf8), format: .csv) }
    }

    @Test func jsonLinesSkipsEmptyLinesAndKeepsBrokenOnesVisible() throws {
        let text = "\u{FEFF}{\"a\":1}\n\n{\"a\":2,\"b\":\"x\"}\nnot json\n[1]\n"
        let parsed = try DatasetImportParser.parse(Data(text.utf8), format: .jsonl)
        #expect(parsed.rows.count == 4 && parsed.columns == ["a", "b"])
        guard case .broken(let line, let reason, _) = parsed.rows[2] else { Issue.record("line 4 must be broken"); return }
        #expect(line == 4 && reason.contains("not a JSON object"))
    }

    @Test func jsonArray() throws {
        let parsed = try DatasetImportParser.parse(Data(#"[{"a":1},{"a":2},3]"#.utf8), format: .json)
        #expect(parsed.rows.count == 3 && parsed.columns == ["a"])
        #expect(throws: DatasetImportError.self) { try DatasetImportParser.parse(Data(#"{"a":1}"#.utf8), format: .json) }
    }

    @Test func formatDetection() {
        #expect(DatasetImportFormat.guess(fileName: "x.CSV") == .csv && DatasetImportFormat.guess(fileName: "a.ndjson") == .jsonl && DatasetImportFormat.guess(fileName: "a.txt") == nil)
        #expect(DatasetImportFormat.sniff(Data(" [1]".utf8)) == .json && DatasetImportFormat.sniff(Data("{\"a\":1}\n".utf8)) == .jsonl && DatasetImportFormat.sniff(Data("a,b\n".utf8)) == .csv)
    }

    // MARK: Exportação

    private let columns = [DatasetColumn(name: "name"), DatasetColumn(name: "rating", type: .number), DatasetColumn(name: "note", type: .string)]

    private func row(_ json: String, valid: Bool = true) -> DatasetRow {
        DatasetRow(rowKey: UUID().uuidString, data: json, valid: valid, error: nil, computer: nil, runID: nil, requestID: nil, sourceURL: nil, trust: .none, firstSeen: Date(), lastSeen: Date(), seenCount: 1)
    }

    @Test func csvEscapesAndGuardsFormulas() {
        let rows = [
            row(#"{"name":"=HYPERLINK(\"http://evil\")","rating":-1.5,"note":"a,b"}"#), row(#"{"name":"@cmd","note":"line1\nline2"}"#),
            row(#"{"name":"+1","rating":4}"#), row(#"{"name":"ignored"}"#, valid: false),
        ]
        let text = String(decoding: DatasetExporter.csv(columns: columns, rows: rows), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "name,rating,note")
        #expect(lines[1] == "\"'=HYPERLINK(\"\"http://evil\"\")\",-1.5,\"a,b\"", "formula guard first, then quoting; numbers keep their sign")
        #expect(text.contains("'@cmd,,\"line1\nline2\"") && text.contains("'+1,4,"))
        #expect(!text.contains("ignored"), "invalid rows are not exported")
        #expect(text.hasSuffix("\r\n"))
    }

    @Test func jsonLinesAndJSONKeepSchemaOrderAndRealTypes() throws {
        let rows = [row(#"{"note":"x","rating":4.5,"name":"Ritz"}"#), row(#"{"name":"Plaza"}"#)]
        let lines = String(decoding: DatasetExporter.jsonLines(columns: columns, rows: rows), as: UTF8.self).split(separator: "\n")
        #expect(lines.map(String.init) == [#"{"name":"Ritz","rating":4.5,"note":"x"}"#, #"{"name":"Plaza"}"#])
        let array = try JSON.parse(DatasetExporter.json(columns: columns, rows: rows))
        #expect(array.array?.count == 2 && array.array?[0]["rating"] == 4.5)
        #expect(String(decoding: DatasetExporter.json(columns: columns, rows: []), as: UTF8.self) == "[]\n")
        #expect(DatasetExporter.Format.jsonl.fileExtension == "jsonl")
    }

    @Test func sharedCSVHelperKeepsTheBatchBehaviour() {
        #expect(CSVFormat.cell("a\"b") == "\"a\"\"b\"" && CSVFormat.cell("plain") == "plain")
        #expect(CSVFormat.safe("=1+1") == "'=1+1" && CSVFormat.safe("-5") == "'-5" && CSVFormat.safe("ok") == "ok")
    }
}
