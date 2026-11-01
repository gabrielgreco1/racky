import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Synchronization
import Testing

@testable import RackyUI

/// Workers de app (spec subagent-harness): o terminal do worker abre como pane ao lado do pai (ou tab nova da mesma sessão), sem depender
/// da tab ativa e sem roubar o foco. O CLI aqui é um shell comum (nenhum claude/codex/opencode real).
extension WorkspaceModelTests {
    private func worker(_ n: Int) -> WorkerLaunch {
        WorkerLaunch(parentID: "parent-aaaaaaaa", childID: "parent-a-a\(n)", capability: "cap\(n)", harness: .codex, helperPath: "/usr/bin/true")
    }

    @Test func aWorkerOpensBesideItsParentEvenWhenAnotherTabIsActive() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1600, height: 1000)
        let tabs = rig.model.tabs
        let parent = try #require(tabs[0].layout.terminalIDs.first)
        rig.model.selectTab(tabs[1].id)  // o usuário está olhando a outra tab
        let focusBefore = rig.model.focusedTerminalID
        let first = try #require(rig.model.openWorkerTerminal(
            session: rig.session.id, nextTo: parent, worker: worker(1), spec: LaunchSpec(provider: .shell), title: "Codex · Houston"))
        #expect(rig.model.activeTabID == tabs[1].id && rig.model.focusedTerminalID == focusBefore, "no focus stealing")
        guard case .split(let axis, _, let left, let right)? = rig.model.tab(tabs[0].id)?.layout else { Issue.record("expected a split"); return }
        #expect(axis == .horizontal && left.terminalIDs == [parent] && right.terminalIDs == [first], "parent left, worker right")
        // O segundo empilha abaixo do primeiro (a coluna de workers), o pai fica inteiro.
        let second = try #require(rig.model.openWorkerTerminal(
            session: rig.session.id, nextTo: parent, worker: worker(2), spec: LaunchSpec(provider: .shell), title: "Codex · Phoenix"))
        guard case .split(_, _, let parentSide, let column)? = rig.model.tab(tabs[0].id)?.layout, case .split(let columnAxis, _, let top, let bottom) = column
        else { Issue.record("expected a column of workers"); return }
        #expect(parentSide.terminalIDs == [parent] && columnAxis == .vertical && top.terminalIDs == [first] && bottom.terminalIDs == [second])
        // O terminal é o do worker: título fixo, identidade e nunca pai de orquestração.
        let terminal = try #require(rig.model.terminal(first))
        #expect(terminal.title == "Codex · Houston" && terminal.titleSource == .user && terminal.launchSpec.workerChildID == "parent-a-a1")
        #expect(rig.model.subagentLaunch(for: terminal) == nil && rig.model.subagentHeader(for: terminal) == nil)
        #expect(rig.model.tabs.count == 2, "no extra tab when there is room")
        await rig.model.settlePersistence()
        let stored = try #require(try await rig.store.terminal(id: first))
        #expect(stored.launchSpec.workerChildID == "parent-a-a1" && stored.tabID == tabs[0].id)
        #expect(try await rig.store.tab(id: tabs[0].id)?.layout.terminalIDs.count == 3)
    }

    @Test func aWorkerWithoutRoomOrWithoutAParentFallsBackToANewTabOfTheSameSession() async throws {
        let rig = try await make(tabs: 1)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 300, height: 200)  // abaixo do mínimo de 240 x 120 por lado
        let parent = try #require(rig.model.activeTab?.layout.terminalIDs.first)
        let tabBefore = rig.model.activeTabID
        let tight = try #require(rig.model.openWorkerTerminal(
            session: rig.session.id, nextTo: parent, worker: worker(1), spec: LaunchSpec(provider: .shell), title: "Codex · A"))
        #expect(rig.model.tabs.count == 2 && rig.model.activeTabID == tabBefore, "a new tab, not selected")
        #expect(rig.model.tabs.last?.layout.terminalIDs == [tight] && rig.model.activeTab?.layout.terminalIDs == [parent])
        // Sem pai conhecido (o terminal dele sumiu): também tab nova, na sessão pedida.
        let orphan = try #require(rig.model.openWorkerTerminal(
            session: rig.session.id, nextTo: nil, worker: worker(2), spec: LaunchSpec(provider: .shell), title: "Codex · B"))
        #expect(rig.model.tabs.count == 3 && rig.model.tabs.last?.layout.terminalIDs == [orphan])
        await rig.model.settlePersistence()
        #expect(try await rig.store.tabs(sessionID: rig.session.id).count == 3)
        // Sessão que não existe: nada é aberto.
        #expect(rig.model.openWorkerTerminal(session: UUID(), nextTo: nil, worker: worker(3), spec: LaunchSpec(provider: .shell), title: "x") == nil)
    }

    @Test func closingTheWorkerPaneTellsTheOrchestratorAndTheLaunchStartsWithoutAVisiblePane() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1600, height: 1000)
        let tabs = rig.model.tabs
        let ended = Mutex<[String]>([])
        rig.model.onWorkerTerminalEnded = { child, _ in ended.withLock { $0.append(child) } }
        rig.model.selectTab(tabs[1].id)
        let id = try #require(rig.model.openWorkerTerminal(
            session: rig.session.id, nextTo: tabs[0].layout.terminalIDs.first, worker: worker(1), spec: LaunchSpec(provider: .shell), title: "Codex · C"))
        // O pane está numa tab escondida e mesmo assim o lançamento começa (não espera paneReady; o daemon real fica de fora destes testes).
        #expect([.launching, .running].contains(rig.model.terminal(id)?.state))
        rig.model.closePane(id)
        for _ in 0 ..< 200 where ended.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(ended.withLock { $0 } == ["parent-a-a1"])
    }
}
