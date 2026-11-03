import Foundation
import RackyProtocol
import Testing

@testable import RackyStore

/// Sidebar v6 (03/11): a tabela aparece dentro do subagente cujo computador gravou as linhas.
@Suite struct DatasetComputerTests {
    @Test func theSummaryNamesTheComputerThatWroteMostRows() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let session = Session(kind: .clean, folderPath: "/tmp/ds", title: "ds")
        try await store.save(session)
        for (id, name) in [("01A", "permits"), ("01B", "empty"), ("01C", "manual")] {
            try await store.createDataset(Dataset(id: id, sessionID: session.id, name: name, columns: [DatasetColumn(name: "n")], key: ["n"], createdAt: Fixture.t0))
        }
        func row(_ key: String, _ computer: String?) -> DatasetRowInput {
            DatasetRowInput(rowKey: key, data: #"{"n":"\#(key)"}"#, computer: computer, trust: .none)
        }
        _ = try await store.upsertDatasetRows(
            datasetID: "01A", rows: [row("1", "wi-milwaukee"), row("2", "wi-milwaukee"), row("3", "wi-milwaukee-qa-a")], at: Fixture.t0)
        _ = try await store.upsertDatasetRows(datasetID: "01C", rows: [row("1", nil)], at: Fixture.t0)
        let byID = Dictionary(uniqueKeysWithValues: try await store.datasetSummaries(sessionID: session.id).map { ($0.id, $0) })
        #expect(byID["01A"]?.computer == "wi-milwaukee")
        #expect(byID["01A"]?.rowCount == 3)
        #expect(byID["01B"]?.computer == nil, "no rows, no owner")
        #expect(byID["01C"]?.computer == nil, "rows without a computer stay in the session")
        #expect(try await store.datasetSummary(id: "01A")?.computer == "wi-milwaukee")
        try await store.close()
    }
}
