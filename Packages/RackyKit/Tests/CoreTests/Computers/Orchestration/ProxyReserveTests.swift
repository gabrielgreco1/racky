import RackyDocker
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// F29: `boxes_reserve(proxy:)` aplica um ProxyProfile no computador; sem `proxy` vale o padrão da sessão (card de aprovação) e depois o
// padrão global (Settings). Nome desconhecido vira `unavailable` com a lista dos proxies. Provisionador falso: o Docker real fica em
// LiveProxyReserveTests.

struct StubProxies: ProxyDirectory {
    var known: [String]
    var global: String?
    func names() async -> [String] { known }
    func globalDefault() async -> String? { global }
}

@Suite("F29 - proxy na reserva", .tags(.integration), .serialized) struct ProxyReserveTests {
    func proxy(of rig: SchedulerRig, _ name: String) async -> String? {
        #expect(await rig.wait(name, .ready))
        return await rig.provisioning.specs[name]?.proxy
    }

    @Test func explicitProxyBeatsSessionAndGlobalDefaults() async throws {
        let rig = try await SchedulerRig.make(proxies: StubProxies(known: ["zyte", "corp"], global: "corp"), sessionProxy: { _ in "corp" })
        defer { rig.cleanup() }
        let out = await rig.parentCall("boxes_reserve", ["names": ["a"], "proxy": "zyte"])
        #expect(rig.states(out.json) != ["unavailable"])
        #expect(await proxy(of: rig, "a") == "zyte")
    }

    @Test func sessionDefaultThenGlobalDefaultThenDirect() async throws {
        let session = try await SchedulerRig.make(proxies: StubProxies(known: ["zyte", "corp"], global: "corp"), sessionProxy: { _ in "zyte" })
        defer { session.cleanup() }
        await session.parentCall("boxes_reserve", ["names": ["a"]])
        #expect(await proxy(of: session, "a") == "zyte")

        let global = try await SchedulerRig.make(proxies: StubProxies(known: ["zyte", "corp"], global: "corp"))
        defer { global.cleanup() }
        await global.parentCall("boxes_reserve", ["names": ["a"]])
        #expect(await proxy(of: global, "a") == "corp")

        let none = try await SchedulerRig.make(proxies: StubProxies(known: ["zyte"], global: nil))
        defer { none.cleanup() }
        await none.parentCall("boxes_reserve", ["names": ["a"]])
        #expect(await proxy(of: none, "a") == "direct")

        // `proxy: "direct"` explícito ignora os padrões
        let direct = try await SchedulerRig.make(proxies: StubProxies(known: ["zyte"], global: "zyte"))
        defer { direct.cleanup() }
        await direct.parentCall("boxes_reserve", ["names": ["a"], "proxy": "direct"])
        #expect(await proxy(of: direct, "a") == "direct")
    }

    @Test func unknownProxyIsRefusedWithTheAvailableNames() async throws {
        let rig = try await SchedulerRig.make(proxies: StubProxies(known: ["zyte", "corp"], global: nil))
        defer { rig.cleanup() }
        let out = await rig.parentCall("boxes_reserve", ["names": ["a"], "proxy": "nope"])
        let box = try #require(out.json["boxes"]?.array?.first)
        #expect(box["state"] == "unavailable" && box["reason"] == "unknown_proxy")
        #expect(box["message"]?.string?.contains("corp, zyte") == true)
        #expect(await rig.provisioning.provisioned.isEmpty)
    }

    @Test func approvalCardChoiceBecomesTheSessionDefaultAndWinsOverTheAgent() async throws {
        let parents = ParentDirectory()
        let approvals = ComputerApprovalCenter()
        await parents.register(ParentInfo(parentID: "p1", sessionID: UUID(), sessionTitle: "houston", mode: .ask))
        let gate = SubagentComputersGate(
            parents: parents, approvals: approvals, waitSeconds: 5, effectiveProxy: { _, requested in requested ?? "corp" })
        let task = Task { try await gate.authorize(parent: "p1", ReserveRequest(names: ["a"], proxy: "zyte")) }
        var card: ComputerApprovalRequest?
        for _ in 0..<100 where card == nil { card = await approvals.open.first; try await Task.sleep(for: .milliseconds(20)) }
        #expect(card?.proxy == "zyte")  // o card mostra o proxy que a reserva receberia
        await approvals.setProxy(id: try #require(card?.id), proxy: "corp")
        #expect(await approvals.open.first?.proxy == "corp")
        await approvals.decide(id: try #require(card?.id), .allow)
        #expect(try await task.value == .proceedWith(proxy: "corp"))
        #expect(await parents.info("p1")?.proxy == "corp")
        // sem escolha no card: segue o pedido
        let again = Task { try await gate.authorize(parent: "p1", ReserveRequest(names: ["b"])) }
        var second: ComputerApprovalRequest?
        for _ in 0..<100 where second == nil { second = await approvals.open.first; try await Task.sleep(for: .milliseconds(20)) }
        await approvals.decide(id: try #require(second?.id), .allow)
        #expect(try await again.value == .proceed)
    }

    @Test func theCardShowsAndChangesWhatTheComputerLeavesBehindAndTheRunRecordsIt() async throws {
        let parents = ParentDirectory()
        let approvals = ComputerApprovalCenter()
        let session = UUID()
        await parents.register(ParentInfo(parentID: "p1", sessionID: session, sessionTitle: "houston", mode: .ask))
        let gate = SubagentComputersGate(
            parents: parents, approvals: approvals, waitSeconds: 5,
            effectiveLeftovers: { _ in await approvals.leftovers(parentID: "p1", sessionID: session) ?? .days7 })
        let task = Task { try await gate.authorize(parent: "p1", ReserveRequest(names: ["a"])) }
        var card: ComputerApprovalRequest?
        for _ in 0..<100 where card == nil { card = await approvals.open.first; try await Task.sleep(for: .milliseconds(20)) }
        #expect(card?.leftovers == .days7)  // o padrão de Settings
        #expect(await approvals.setLeftovers(id: try #require(card?.id), .whenDone))
        #expect(await approvals.open.first?.leftovers == .whenDone)
        await approvals.decide(id: try #require(card?.id), .allow)
        #expect(try await task.value == .proceed)
        #expect(await approvals.leftovers(parentID: "p1", sessionID: session) == .whenDone, "the next computers of the session get it too")

        // O scheduler grava a escolha no `box.json` do run.
        let rig = try await SchedulerRig.make()
        defer { rig.cleanup() }
        await rig.scheduler.setLeftoversPolicy { _ in .days30 }
        await rig.parentCall("boxes_reserve", ["names": ["a"]])
        #expect(await rig.wait("a", .ready))
        let run = try #require(await rig.scheduler.activeRunRoots().first)
        #expect(RunFolder(root: URL(fileURLWithPath: run)).readMetadata()?.leftovers == .days30)
    }
}
