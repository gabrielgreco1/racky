import Foundation
import Testing

@testable import RackyCore
@testable import RackyProtocol

/// 03/11: a sessão estava em Full, mas o pai tinha subido em Ask e seguia pedindo aceite. Ask ↔ Full vale na hora, sem reiniciar.
@Suite struct LiveSessionModeTests {
    final class ModeBox: @unchecked Sendable {  // SAFETY: os testes só escrevem antes de chamar o gate.
        var mode: SubagentComputersMode?
        init(_ mode: SubagentComputersMode?) { self.mode = mode }
    }

    static func gate(launched: SubagentComputersMode, live: ModeBox) async -> (SubagentComputersGate, ComputerApprovalCenter) {
        let parents = ParentDirectory()
        let approvals = ComputerApprovalCenter()
        await parents.register(ParentInfo(parentID: "p1", sessionID: UUID(), sessionTitle: "steady", mode: launched))
        let gate = SubagentComputersGate(parents: parents, approvals: approvals, waitSeconds: 0.2, liveMode: { _ in live.mode })
        return (gate, approvals)
    }

    @Test func aSessionSwitchedToFullStopsAskingWithoutARestart() async throws {
        let (gate, approvals) = await Self.gate(launched: .ask, live: ModeBox(.full))
        #expect(try await gate.authorize(parent: "p1", ReserveRequest(names: ["a", "b"])) == .proceed)
        #expect(await approvals.open.isEmpty, "no approval card")
    }

    @Test func aSessionSwitchedBackToAskAsksAgain() async throws {
        let (gate, approvals) = await Self.gate(launched: .full, live: ModeBox(.ask))
        let result = try await gate.authorize(parent: "p1", ReserveRequest(names: ["a"]))
        guard case .pending = result else { Issue.record("expected pending, got \(result)"); return }
        #expect(await approvals.open.count == 1)
    }

    @Test func turnedOffMeansNoComputers() async throws {
        let (gate, _) = await Self.gate(launched: .full, live: ModeBox(.off))
        await #expect(throws: ToolError.self) { try await gate.authorize(parent: "p1", ReserveRequest(names: ["a"])) }
    }

    @Test func withoutTheStoreTheLaunchModeStillDecides() async throws {
        let (gate, _) = await Self.gate(launched: .full, live: ModeBox(nil))
        #expect(try await gate.authorize(parent: "p1", ReserveRequest(names: ["a"])) == .proceed)
    }
}
