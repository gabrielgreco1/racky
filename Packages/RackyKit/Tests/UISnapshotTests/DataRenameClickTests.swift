import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// O lápis ao lado do nome do dataset, clicado com o mouse de verdade (eventos de janela, não a ação direto): o campo de nome abre e
/// continua aberto, com o foco, até o Enter.
@MainActor
@Suite(.serialized, .offscreenAppKit, .tags(.integration)) struct DataRenameClickTests {
    private func click(_ window: NSWindow, at frame: CGRect, count: Int = 1) {
        let height = window.contentView?.bounds.height ?? 0
        let point = CGPoint(x: frame.midX, y: height - frame.midY)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: n, pressure: type == .leftMouseUp ? 0 : 1)!
                window.sendEvent(event)
            }
        }
    }

    @Test func pencilOpensTheNameFieldAndKeepsItOpen() async throws { try await run(inSessionTab: false) }

    /// A mesma coisa com o dataset aberto como tab da sessão (pane do workspace), onde a barra também arrasta o pane.
    @Test func pencilWorksInADatasetTabOfTheSession() async throws { try await run(inSessionTab: true) }

    /// Ao lado do agente (pane dividido): a barra também arrasta o pane.
    @Test func pencilWorksBesideTheAgent() async throws { try await run(inSessionTab: true, beside: true) }

    /// Aberto antes na página Data e depois como tab da sessão: o nome existe em dois lugares montados ao mesmo tempo.
    @Test func pencilWorksWhenTheDatasetIsAlsoOpenInTheDataPage() async throws { try await run(inSessionTab: true, alsoInDataPage: true) }

    private func run(inSessionTab: Bool, alsoInDataPage: Bool = false, beside: Bool = false) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-rename-click-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let session = try #require(cast.selectedSessionID)
        env.sidebar.select(session)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1500, height: 900))
        defer { c.window?.close() }
        let window = try #require(c.window)
        window.makeKeyAndOrderFront(nil)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        defer { Task { try? await store.close() } }
        try await store.save(Session(id: session, kind: .clean, folderPath: "/tmp/books", title: "Book prices"))
        await env.datasets.attach(store: store)
        let service = DatasetService(store: store)
        _ = try await service.define(session: session, name: "books2", columns: [DatasetColumn(name: "title", required: true)], key: ["title"])
        _ = try await service.append(session: session, name: "books2", rows: [["title": .string("Doctor Sleep")]], provenance: .none)
        await env.datasets.reloadList()
        let books = try #require(env.datasets.summaries.first { $0.dataset.name == "books2" })
        if alsoInDataPage {
            _ = try await env.registry.perform(.pageDatasets, .press)
            _ = try await env.registry.perform(.dataOpen, .select("dataset:\(books.dataset.id)"))
            await VisualBatchTests.settle(500)
        }
        if inSessionTab {
            _ = try await env.registry.perform(.datasetOpen, .select(beside ? "\(books.dataset.id)|beside" : books.dataset.id))
        } else {
            _ = try await env.registry.perform(.pageDatasets, .press)
            _ = try await env.registry.perform(.dataOpen, .select("dataset:\(books.dataset.id)"))
        }
        await VisualBatchTests.settle(800)

        let pencil = try #require(env.elements.frame(of: .dataRenameButton))
        click(window, at: pencil)
        await VisualBatchTests.settle(400)
        #expect(env.dataHub.renaming == books.dataset.id, "the pencil click should start renaming")
        await VisualBatchTests.settle(1000)
        #expect(env.dataHub.renaming == books.dataset.id, "the field should stay open")
        #expect(env.elements.frame(of: .dataRenameField) != nil)
        #expect(window.firstResponder is NSText, "the name field should have the keyboard focus")
        // Digita um nome novo e aperta Enter, como uma pessoa.
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Livros novos", replacementRange: editor.selectedRange())
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        await VisualBatchTests.settle(600)
        #expect(env.dataHub.renaming == nil, "Enter should close the field")
        #expect(env.datasets.name(of: books.dataset.id) == "Livros novos", "Enter should save the new name")
    }
}
