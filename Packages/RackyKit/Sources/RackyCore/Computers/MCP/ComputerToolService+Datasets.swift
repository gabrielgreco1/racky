import Foundation
import RackyStore

// Datasets v1: as ferramentas `dataset_*` do worker (proveniência vem do reqlog do computador dele) e as do pai (leitura da sessão).

extension ComputerToolService {
    private func datasetContext(_ identity: String) async throws -> (service: DatasetService, session: UUID) {
        guard let datasets else { throw ToolError(.notSupported, "datasets are not available in this app build") }
        guard let session = await datasets.sessionID(identity) else {
            throw ToolError(.notSupported, "this session is not known to the app, so there is no dataset to write to")
        }
        return (datasets.service, session)
    }

    /// Requisição citada por `_request_id`: procura no `requests.jsonl` do computador (lido uma vez por chamada, só se alguma linha cita um id).
    static func provenance(for rows: [[String: JSON]], computer c: ManagedComputer, runID: String) -> DatasetProvenance {
        let wanted = Set(rows.compactMap { $0[DatasetEngine.requestIDField]?.string }.filter(ResultValidator.looksLikeRequestID))
        var found: [String: DatasetProvenance.Request] = [:]
        if !wanted.isEmpty {
            for record in records(c) {
                guard let id = record["id"]?.string, wanted.contains(id) else { continue }
                let trust = DatasetTrust(rawValue: record["trust"]?.string ?? "observed") ?? .observed
                let info = DatasetRequestInfo(
                    method: record["method"]?.string, status: record["status"]?.int, milliseconds: record["duration_ms"].flatMap { $0.int ?? $0.double.map { Int($0) } })
                found[id] = .init(url: record["url"]?.string, trust: trust == .none ? .observed : trust, info: info)
            }
        }
        let table = found
        return DatasetProvenance(computer: c.name, runID: runID) { table[$0] }
    }

    func datasetTool(_ name: String, _ args: Args, child: String, _ c: ManagedComputer) async throws -> ToolResult {
        let (service, session) = try await datasetContext(child)
        let dataset = args.string("name") ?? ""
        switch name {
        case "dataset_define":
            let columns = try Self.columns(args.values["columns"])
            return ToolResult(try await service.define(session: session, name: dataset, columns: columns, key: args.strings("key")))
        case "dataset_append":
            let rows = (args.values["rows"]?.array ?? []).compactMap(\.object)
            let provenance = Self.provenance(for: rows, computer: c, runID: await c.runID)
            return ToolResult(try await service.append(session: session, name: dataset, rows: rows, provenance: provenance))
        case "dataset_import":
            let file = args.string("file") ?? ""
            let data = try PathGuard.read(root: c.run.work, file)
            let format = args.string("format").flatMap(DatasetImportFormat.init(rawValue:)) ?? DatasetImportFormat.guess(fileName: file) ?? DatasetImportFormat.sniff(data)
            let parsed: ParsedImport
            do { parsed = try DatasetImportParser.parse(data, format: format) } catch let error as DatasetImportError { throw ToolError.invalid(error.message) }
            return ToolResult(try await service.importRows(session: session, name: dataset, parsed: parsed, format: format, provenance: DatasetProvenance(computer: c.name, runID: await c.runID)))
        default:
            return ToolResult(try await service.read(
                session: session, name: dataset, limit: args.int("limit"), offset: args.int("offset"), invalidOnly: args.bool("invalid_only") == true))
        }
    }

    func parentDatasetTool(_ name: String, _ args: Args, parent: String) async throws -> ToolResult {
        let (service, session) = try await datasetContext(parent)
        if name == "dataset_list" { return ToolResult(try await service.list(session: session)) }
        return ToolResult(try await service.read(
            session: session, name: args.string("name") ?? "", limit: args.int("limit"), offset: args.int("offset"), invalidOnly: args.bool("invalid_only") == true))
    }

    static func columns(_ json: JSON?) throws -> [DatasetColumn] {
        try (json?.array ?? []).map { item in
            guard let name = item["name"]?.string else { throw ToolError.invalid("every column needs a name") }
            let type = item["type"]?.string.flatMap(DatasetColumnType.init(rawValue:)) ?? .string
            return DatasetColumn(name: name, type: type, required: item["required"]?.bool ?? false)
        }
    }
}
