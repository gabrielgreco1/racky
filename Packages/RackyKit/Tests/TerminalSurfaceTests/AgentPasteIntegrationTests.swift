import RackyCore
import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// "Paste into <Agent>" (T11, AC-505) contra o `rackyd` real, com um CLI falso que liga o bracketed paste e grava
/// em arquivo, byte a byte (`dd bs=1`), tudo que o PTY lhe entrega.
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct AgentPasteIntegrationTests {
    private func withFakeAgent(enableBracketedPaste: Bool, _ body: @MainActor (PTYClient, TerminalHostView, SessionID, URL) async throws -> Void) async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("abx-paste-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: dump) }
        var binding: TerminalSessionBinding?
        do {
            try await client.start()
            let host = TerminalHostView(terminalID: "paste-1")
            _ = makeWindow(hosting: host)
            let dims = host.surface.terminalDimensions
            let script = "stty -echo -icanon; \(enableBracketedPaste ? "printf '\\033[?2004h'; " : "")echo ready; exec dd bs=1 of='\(dump.path)' 2>/dev/null"
            let create = makeCreate(["/bin/sh", "-c", script], cols: UInt16(dims.cols), rows: UInt16(dims.rows))
            let created = try await client.create(create)
            let b = TerminalSessionBinding(client: client, sessionID: created.session.sessionID, host: host)
            binding = b
            try await b.start()
            try await eventually("fake agent ready") {
                String(decoding: host.surface.getBufferAsData(kind: .active), as: UTF8.self).contains("ready")
            }
            try await body(client, host, created.session.sessionID, dump)
        } catch {
            binding?.stop()
            await client.stop()
            await harness.stop()
            throw error
        }
        binding?.stop()
        await client.stop()
        await harness.stop()
    }

    private func sender(_ client: PTYClient, _ host: TerminalHostView, _ session: SessionID, copied: CopyBox) -> AgentPasteSender {
        AgentPasteSender(
            bracketedPasteActive: host.surface.terminalStateSnapshot().bracketedPasteMode,
            send: { origin, data in try await client.sendInput(sessionID: session, origin: origin, bytes: data) },
            copy: { copied.value = $0 })
    }

    final class CopyBox: @unchecked Sendable { nonisolated(unsafe) var value: String? }

    @Test func pasteArrivesBracketedWithoutEnterAndIsCountedAsAppPaste() async throws {
        try await withFakeAgent(enableBracketedPaste: true) { client, host, session, dump in
            let copied = CopyBox()
            try await eventually("bracketed paste mode seen by the UI") { host.surface.terminalStateSnapshot().bracketedPasteMode }
            let outcome = try await sender(client, host, session, copied: copied).paste("fix the build\nthen run tests\n", provider: .claude)
            #expect(outcome == .pasted)
            let expected = "\u{1b}[200~fix the build\nthen run tests\u{1b}[201~"
            try await eventually("fake agent received the paste") {
                (try? String(contentsOf: dump, encoding: .utf8)) == expected
            }
            let received = try String(contentsOf: dump, encoding: .utf8)
            #expect(!received.contains("\r"), "nenhum CR")
            #expect(!received.hasSuffix("\n"), "nenhum LF no fim: nada é enviado ao agente")
            #expect(copied.value == nil)

            let counts = try #require(try await client.list().first { $0.sessionID == session }).inputBytesByOrigin
            #expect(counts[.appPaste] == UInt64("\u{1b}[200~fix the build\nthen run tests\u{1b}[201~".utf8.count))
            #expect(counts[.key] == 0 && counts[.userPaste] == 0 && counts[.ctl] == 0 && counts[.parentToChild] == 0)
        }
    }

    @Test func withoutBracketedPasteTheTextGoesToTheClipboardAndNothingIsWritten() async throws {
        try await withFakeAgent(enableBracketedPaste: false) { client, host, session, _ in
            let copied = CopyBox()
            let outcome = try await sender(client, host, session, copied: copied).paste("rm -rf /\n", provider: .codex)
            #expect(outcome == .copied)
            #expect(copied.value == "rm -rf /\n")
            let counts = try #require(try await client.list().first { $0.sessionID == session }).inputBytesByOrigin
            #expect(counts.total == 0)
        }
    }

    @Test func shellsAndCustomCommandsAreNotAgents() async throws {
        let sender = AgentPasteSender(bracketedPasteActive: true, send: { _, _ in Issue.record("não deve escrever") }, copy: { _ in })
        await #expect(throws: AgentPasteError.notAnAgent) { try await sender.paste("x", provider: .shell) }
        #expect(AgentPasteLabel.menuTitle(.claude) == "Paste into Claude")
        #expect(AgentPasteLabel.menuTitle(.codex) == "Paste into Codex")
        #expect(AgentPasteLabel.menuTitle(.opencode) == "Paste into OpenCode")
        #expect(AgentPasteLabel.menuTitle(.custom) == nil)
        #expect(AgentPasteLabel.popoverTitle(.claude) == "Paste into Claude Code")
    }
}
