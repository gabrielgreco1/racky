import Foundation
import Testing

import RackyProtocol
@testable import RackyUI

/// Notebook de datasets: o `.ipynb` nasce com o import do pandas, cada dataset novo ganha uma célula que lê o CSV, e reabrir
/// (o app esqueceu o que já tinha carregado) não repete célula.
struct NotebookFileTests {
    @Test func appendsOneCellPerNewDatasetAndNeverRepeats() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-\(UUID().uuidString).ipynb")
        defer { try? FileManager.default.removeItem(at: url) }
        try NotebookFile.append(cells: [("hotels", "data/hotels.csv", "hotels")], title: "hotels", to: url)
        try NotebookFile.append(cells: [("hotels", "data/hotels.csv", "hotels"), ("stays", "data/stays.csv", "stays")], title: "hotels", to: url)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sources = (object["cells"] as? [[String: Any]] ?? []).compactMap { $0["source"] as? String }
        #expect(sources.filter { $0.contains("data/hotels.csv") }.count == 1)
        #expect(sources.filter { $0.contains("data/stays.csv") }.count == 1)
        #expect(sources.contains { $0.hasPrefix("import pandas") })
    }

    @Test func namesAreSafe() {
        #expect(NotebookController.notebookID(for: "Hotels Lisboa!") == "hotels_lisboa_")
        #expect(NotebookController.variable(for: "2024 sales") == "df_2024_sales")
        #expect(NotebookController.variable(for: "hotels-booking") == "hotels_booking")
    }
}

/// A tab de um notebook reabre pelo `data.open` (era recusada como "objeto de conexão removida": notebook não tem conexão).
@MainActor struct NotebookTabReopenTests {
    @Test func aNotebookTabOpensAgainAfterSwitchingToAnotherObject() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nb-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1", "RACKY_DATA_DEMO": "1"])
        env.dataHub.open(.notebook("lisboa_freguesias"))
        _ = try await env.registry.perform(.dataOpen, .select("dataset:other"))
        #expect(try await env.registry.perform(.dataOpen, .select("notebook:lisboa_freguesias")).message == "notebook:lisboa_freguesias")
        #expect(env.dataHub.active == .notebook("lisboa_freguesias"))
        await #expect(throws: (any Error).self) { try await env.registry.perform(.dataOpen, .select("table:gone:public:t")) }
    }
}

/// O notebook vira pane da sessão: o layout salvo guarda e relê o pane de notebook.
struct NotebookPaneLayoutTests {
    @Test func aNotebookPaneSurvivesTheSavedLayout() throws {
        let layout = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .leaf(Pane(content: .terminal(UUID()))), second: .leaf(Pane(content: .notebook("lisboa"))))
        let back = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        #expect(back == layout)
        #expect(back.panes.contains { $0.content == .notebook("lisboa") })
    }
}

/// Arrastar um dataset da coluna Data para o notebook: o texto do arrasto carrega o id, e só ele vira dataset do notebook.
@MainActor struct NotebookDropTests {
    @Test func onlyDatasetDragsAreRecognized() {
        #expect(NotebookDrop.datasetID(NotebookDrop.payload("ds-1")) == "ds-1")
        #expect(NotebookDrop.datasetID("rightPanel.terminal") == nil)
        #expect(NotebookDrop.datasetID(NotebookDrop.prefix) == nil)
    }

    @Test func droppingNeedsAKnownNotebook() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nb-drop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1", "RACKY_DATA_DEMO": "1"])
        await #expect(throws: (any Error).self) { try await env.registry.perform(.notebookAddDataset, .select("missing|ds-1")) }
        await #expect(throws: (any Error).self) { try await env.registry.perform(.notebookAddDataset, .select("no-bar")) }
    }
}

/// `killStale` só encerra o servidor que o app dono (já morto) anotou; nunca o de outra instância viva nem um pid que não é o vigia.
@Suite(.serialized) struct NotebookStaleServerTests {
    private func watcher() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 20; true", "racky-jupyter"]
        try process.run()
        return process
    }

    private func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("owner-\(UUID().uuidString)") }

    @Test func killsAnOrphanWhoseOwnerIsDead() throws {
        let shell = try watcher()
        let owner = file()
        defer { shell.terminate(); try? FileManager.default.removeItem(at: owner) }
        NotebookController.writeOwner(shell.processIdentifier, to: owner, appPID: try deadPID())
        let started = Date()
        NotebookController.killStale(ownerFile: owner, ownPID: getpid())
        shell.waitUntilExit()
        #expect(!shell.isRunning)
        #expect(Date().timeIntervalSince(started) < 10)  // morreu pelo kill, não esperando o sleep acabar
        #expect(!FileManager.default.fileExists(atPath: owner.path))
    }

    @Test func leavesAServerWhoseOwnerIsAliveAlone() throws {
        let shell = try watcher()
        let owner = file()
        defer { shell.terminate(); try? FileManager.default.removeItem(at: owner) }
        NotebookController.writeOwner(shell.processIdentifier, to: owner, appPID: getppid())  // outra instância viva
        NotebookController.killStale(ownerFile: owner, ownPID: getpid())
        #expect(shell.isRunning)
        #expect(FileManager.default.fileExists(atPath: owner.path))
    }

    @Test func ignoresAPidThatIsNotTheJupyterWatcher() throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["20"]
        try other.run()
        let owner = file()
        defer { other.terminate(); try? FileManager.default.removeItem(at: owner) }
        NotebookController.writeOwner(other.processIdentifier, to: owner, appPID: try deadPID())
        NotebookController.killStale(ownerFile: owner, ownPID: getpid())
        #expect(other.isRunning)
    }
}

/// App reiniciado com a tab do notebook aberta: o estado volta da pasta (CSV em `data/`), e soltar um dataset funciona de novo.
@MainActor struct NotebookRestoreTests {
    @Test func aReopenedNotebookTabGetsItsDatasetsBackAndAcceptsDrops() async throws {
        let f = try await DatasetsFixture.make(automation: false); defer { f.remove() }
        let root = f.root.appendingPathComponent("notebooks", isDirectory: true)
        let data = root.appendingPathComponent("hotels/data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try "name\n".write(to: data.appendingPathComponent("hotels.csv"), atomically: true, encoding: .utf8)
        let notebooks = NotebookController(datasets: f.controller)
        let hotels = try #require(f.controller.summaries.first { $0.dataset.name == "hotels" }).id
        #expect(notebooks.restore("hotels", root: root))
        #expect(notebooks.notebooks["hotels"]?.selected == [hotels] && notebooks.notebooks["hotels"]?.loaded == [hotels])
        #expect(!notebooks.restore("nothing-here", root: root))
    }
}

/// "Load into notebook" roda o notebook: cada dataset aparece com a contagem de linhas salva no `.ipynb` (precisa do `uv`).
@MainActor @Suite(.tags(.integration), .enabled(if: NotebookController.uvPath() != nil)) struct NotebookExecuteTests {
    @Test func loadingRunsEveryDatasetCell() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nb-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        try "name\na\nb\n".write(to: folder.appendingPathComponent("data/one.csv"), atomically: true, encoding: .utf8)
        try "name\nx\n".write(to: folder.appendingPathComponent("data/two.csv"), atomically: true, encoding: .utf8)
        let file = folder.appendingPathComponent("nb.ipynb")
        try NotebookFile.append(cells: [("one", "data/one.csv", "one"), ("two", "data/two.csv", "two")], title: "nb", to: file)
        await NotebookController.execute(file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("2 rows") && text.contains("1 rows"))
    }
}
