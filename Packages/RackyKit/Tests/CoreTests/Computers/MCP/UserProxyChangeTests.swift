import Foundation
import Testing
@testable import RackyCore

/// Backlog 6: o "Change…" da aba Computers. O egress real já trocou de proxy ao vivo várias vezes pelo `proxy_set` dos agentes
/// (zyte ↔ direct, fechando túneis); aqui fica o que só a UI faz: a troca chega ao backend, o computador passa a mostrar a saída nova
/// e o diário registra que foi o usuário.
struct UserProxyChangeTests {
    @Test func changingTheExitFromTheUIReachesTheEgressAndIsWrittenAsTheUsers() async throws {
        let rig = try await Rig.make(proxiesAllowed: ["zyte"])
        defer { rig.cleanup() }

        let closed = try await rig.computer.switchProxyByUser(to: "zyte")
        #expect(closed == 3)
        #expect(await rig.backend.proxySwitches == ["zyte"])
        #expect(await rig.computer.proxy == "zyte")

        try await rig.computer.switchProxyByUser(to: "direct")
        #expect(await rig.backend.proxySwitches == ["zyte", "direct"])
        #expect(await rig.computer.proxy == "direct")

        let notes = JournalLine.read(run: rig.computer.run.root).filter(\.system).map(\.text)
        #expect(notes == [
            "proxy -> zyte (set by the user): closed 3 open tunnels",
            "proxy -> direct (set by the user): closed 3 open tunnels",
        ])
    }
}
