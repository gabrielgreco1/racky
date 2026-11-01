import RackyCore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// F31 de ponta a ponta, sem abrir o app: fechar/abrir o painel direito, esconder a sidebar, arrastar divisor e redimensionar
/// a janela terminam com UM resize do PTY (cols/rows recalculados pela fonte) e o tamanho que o daemon aplicou acompanha
/// (`stty size` dentro do terminal lê o `TIOCGWINSZ` do PTY do daemon).
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(4))) struct LayoutResizeFlowTests {
    typealias Rig = AppKeyboardFlowTests.Rig

    private static func screen(_ rig: Rig) -> String {
        guard let surface = rig.surface else { return "" }
        return String(decoding: surface.getBufferAsData(kind: .active), as: UTF8.self)
    }

    /// Espera o emulador assentar e o daemon confirmar o tamanho: `stty size` imprime "rows cols" iguais aos da surface.
    private static func expectDaemonFollows(_ label: String, _ rig: Rig) async throws -> (cols: Int, rows: Int) {
        await AppKeyboardFlowTests.settle(500)
        guard let surface = rig.surface, let id = rig.terminalID else { Issue.record("\(label): sem terminal"); return (0, 0) }
        let dims = surface.terminalDimensions
        let applied = rig.env.workspace.runtime.existingEntry(for: id)?.binding?.resizeCoordinator?.appliedSize
        #expect(applied == .init(cols: UInt16(dims.cols), rows: UInt16(dims.rows)), "\(label): o coordenador aplicou \(String(describing: applied)), a surface mede \(dims)")
        let marker = "SZ\(Int.random(in: 1000 ... 9999))"
        if let session = rig.ptySession { try await rig.client.sendInput(sessionID: session, bytes: Data("clear; echo \(marker)-$(stty size | tr ' ' x)\r".utf8)) }
        let wanted = "\(marker)-\(dims.rows)x\(dims.cols)"
        do {
            try await eventually("\(label): daemon PTY size", timeout: .seconds(8)) { Self.screen(rig).contains(wanted) }
        } catch {
            Issue.record("\(label): esperava \(wanted); tela: \(Self.screen(rig).suffix(200).debugDescription)")
            throw error
        }
        return (dims.cols, dims.rows)
    }

    /// Espera a surface medir colunas diferentes de `from` (a animação do AppKit termina sozinha, sem prazo fixo).
    private static func waitCols(changedFrom from: Int, _ rig: Rig, _ label: String = "") async throws {
        try await eventually("\(label): surface mede novas colunas (era \(from))", timeout: .seconds(6)) {
            // Janela fora da tela não roda o ciclo de display: o teste bombeia o layout como o AppKit faria a cada quadro.
            rig.window.contentView?.layoutSubtreeIfNeeded()
            return rig.surface?.terminalDimensions.cols != from }
    }

    @Test func panelSidebarDividerAndWindowChangesAlwaysEndWithAPTYResize() async throws {
        try await AppKeyboardFlowTests.withApp { rig in
            let env = rig.env
            try await AppKeyboardFlowTests.waitTerminalRunning(rig)
            // Normaliza: painel fechado e sidebar visível (o fixture pode abrir o painel).
            if env.rightPanel.isShown {
                let before = rig.surface?.terminalDimensions.cols ?? 0
                env.rightPanel.toggleOpen()
                try await Self.waitCols(changedFrom: before, rig, "normaliza")
            }
            let start = try await Self.expectDaemonFollows("inicial", rig)

            // Painel direito: abrir encolhe, fechar devolve a largura.
            env.rightPanel.toggleOpen()
            try await Self.waitCols(changedFrom: start.cols, rig, "abre painel")
            let withPanel = try await Self.expectDaemonFollows("painel aberto", rig)
            #expect(withPanel.cols < start.cols, "abrir o painel diminui as colunas")
            env.rightPanel.toggleOpen()
            try await Self.waitCols(changedFrom: withPanel.cols, rig, "fecha painel")
            let closedPanel = try await Self.expectDaemonFollows("painel fechado", rig)
            #expect(closedPanel.cols == start.cols, "fechar o painel devolve as colunas")

            // Sidebar: esconder aumenta, mostrar volta.
            rig.controller.setSidebarCollapsed(true)
            try await Self.waitCols(changedFrom: start.cols, rig, "esconde sidebar")
            let noSidebar = try await Self.expectDaemonFollows("sidebar escondida", rig)
            #expect(noSidebar.cols > start.cols, "esconder a sidebar aumenta as colunas")
            rig.controller.setSidebarCollapsed(false)
            try await Self.waitCols(changedFrom: noSidebar.cols, rig, "mostra sidebar")
            let withSidebar = try await Self.expectDaemonFollows("sidebar de volta", rig)
            #expect(withSidebar.cols == start.cols)

            // Divisor da sidebar arrastado (transição aberta e fechada como o `mouseDown` do ChromeSplitView faz).
            let split = rig.controller.splitView
            let beforeResizes = env.workspace.runtime.totalResizes
            env.workspace.runtime.setLayoutTransition(true)
            for width in stride(from: 280, through: 420, by: 20) { split.setPosition(CGFloat(width), ofDividerAt: 0); split.layoutSubtreeIfNeeded() }
            env.workspace.runtime.setLayoutTransition(false)
            let dragged = try await Self.expectDaemonFollows("divisor da sidebar", rig)
            #expect(dragged.cols < start.cols, "alargar a sidebar diminui as colunas")
            #expect(env.workspace.runtime.totalResizes - beforeResizes == 1, "o arrasto inteiro gera um resize de PTY")
            env.workspace.runtime.setLayoutTransition(true)
            split.setPosition(280, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            env.workspace.runtime.setLayoutTransition(false)
            let back = try await Self.expectDaemonFollows("divisor de volta", rig)
            #expect(back.cols == start.cols)

            // Janela maior e menor.
            rig.window.setContentSize(NSSize(width: 1500, height: 900))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            let bigger = try await Self.expectDaemonFollows("janela maior", rig)
            #expect(bigger.cols > start.cols && bigger.rows > start.rows)
            rig.window.setContentSize(NSSize(width: 1280, height: 800))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            let same = try await Self.expectDaemonFollows("janela de volta", rig)
            #expect(same.cols == start.cols)
        }
    }
}
