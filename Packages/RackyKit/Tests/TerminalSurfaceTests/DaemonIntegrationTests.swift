import RackyCore
import RackyProtocol
import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import RackyUI

/// Integração com o `rackyd` real: zsh num PTY do daemon, `TerminalHostView` anexado por `TerminalSessionBinding`.
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct DaemonIntegrationTests {
    private struct Rig {
        let harness: DaemonHarness
        let client: PTYClient
        let host: TerminalHostView
        let window: NSWindow
        let binding: TerminalSessionBinding
        let session: SessionID
    }

    private func withRig(
        argv: [String] = ["/bin/zsh", "-f", "-i"], env: [String: String] = ["PROMPT": "%# ", "RPROMPT": ""],
        _ body: (Rig) async throws -> Void
    ) async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        var binding: TerminalSessionBinding?
        do {
            try await client.start()
            let host = TerminalHostView(terminalID: "it-1")
            let window = makeWindow(hosting: host)
            let dims = host.surface.terminalDimensions
            var create = makeCreate(argv, cols: UInt16(dims.cols), rows: UInt16(dims.rows), env: env)
            create.cwd = NSTemporaryDirectory()
            let created = try await client.create(create)
            let b = TerminalSessionBinding(client: client, sessionID: created.session.sessionID, host: host)
            binding = b
            try await b.start()
            try await body(Rig(harness: harness, client: client, host: host, window: window, binding: b, session: created.session.sessionID))
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

    private func screen(_ rig: Rig) -> String {
        String(decoding: rig.host.surface.getBufferAsData(kind: .active), as: UTF8.self)
    }

    private func type(_ text: String, into rig: Rig) {
        rig.host.surface.send(txt: text)
    }

    private func originBytes(_ rig: Rig) async throws -> InputByteCounts {
        let sessions = try await rig.client.list()
        return sessions.first { $0.sessionID == rig.session }?.inputBytesByOrigin ?? InputByteCounts()
    }

    @Test func typeInZshAndSeeTheOutput() async throws {
        try await withRig { rig in
            try await eventually("prompt") { screen(rig).contains("% ") }
            type("echo hello-$((6*7))\r", into: rig)
            try await eventually("echo output") { screen(rig).contains("hello-42") }
            let bytes = try await originBytes(rig)
            #expect(bytes[.key] == UInt64("echo hello-$((6*7))\r".utf8.count))
            #expect(bytes[.userPaste] == 0)
        }
    }

    @Test func coloredOutputKeepsAttributes() async throws {
        try await withRig { rig in
            try await eventually("prompt") { screen(rig).contains("% ") }
            type("printf '\\033[31mRED\\033[0m \\033[1;32mGREEN\\033[0m\\n'\r", into: rig)
            try await eventually("colored output") { screen(rig).contains("RED GREEN") }
            let snapshot = rig.host.surface.terminalStateSnapshot()
            let row = try #require(snapshot.visibleRows.first { $0.text.contains("RED GREEN") && !$0.text.contains("printf") })
            #expect(row.text.hasPrefix("RED GREEN"))
        }
    }

    @Test func resizeReachesThePTYOncePerTransition() async throws {
        try await withRig { rig in
            try await eventually("prompt") { screen(rig).contains("% ") }
            // O attach faz o redraw forçado (cols-1 e volta em 50 ms, 06 §1.5): espera assentar antes de medir.
            try await Task.sleep(for: .milliseconds(400))
            type("stty size\r", into: rig)
            let first = rig.host.surface.terminalDimensions
            do {
                try await eventually("initial stty") { screen(rig).contains("\(first.rows) \(first.cols)") }
            } catch {
                Issue.record("screen was: \(screen(rig).debugDescription) dims \(first.rows)x\(first.cols)")
                throw error
            }

            rig.window.setContentSize(NSSize(width: 1000, height: 640))
            rig.host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
            rig.host.layoutSubtreeIfNeeded()
            let resized = rig.host.surface.terminalDimensions
            #expect(resized.cols > first.cols)
            try await eventually("daemon applied the resize") { rig.binding.resizeCoordinator?.appliedSize == .init(cols: UInt16(resized.cols), rows: UInt16(resized.rows)) }
            type("clear; stty size\r", into: rig)
            try await eventually("stty after resize") { screen(rig).contains("\(resized.rows) \(resized.cols)") }
        }
    }

    @Test func pasteReachesTheShellWithTheUserPasteOrigin() async throws {
        try await withRig { rig in
            try await eventually("prompt") { screen(rig).contains("% ") }
            rig.host.surface.pasteUser("echo pasted-ok")
            try await eventually("paste echo") { screen(rig).contains("echo pasted-ok") }
            let bytes = try await originBytes(rig)
            // zsh liga o bracketed paste (ESC[200~ ... ESC[201~ = 12 bytes), então a colagem chega envelopada.
            #expect(bytes[.userPaste] == UInt64("echo pasted-ok".utf8.count + 12))
            #expect(bytes[.key] == 0)
        }
    }

    @Test func osc52ReadFromTheProgramIsNeverAnswered() async throws {
        try await withRig { rig in
            try await eventually("prompt") { screen(rig).contains("% ") }
            let typed = "printf '\\033]52;c;?\\007'; echo done-52\r"
            type(typed, into: rig)
            try await eventually("marker") { screen(rig).contains("done-52") }
            try await Task.sleep(for: .milliseconds(300))
            let bytes = try await originBytes(rig)
            #expect(bytes[.key] == UInt64(typed.utf8.count))
            #expect(bytes[.terminalReply] == 0, "nenhuma resposta ao OSC 52 de leitura")
        }
    }

    @Test func deviceAttributesAreAnsweredExactlyOnceByTheUI() async throws {
        let script = "printf '\\033[c'; sleep 1; printf '\\033[c'; sleep 30"
        try await withRig(argv: ["/bin/sh", "-c", script], env: [:]) { rig in
            try await eventually("first reply") { (try? await originBytes(rig)[.terminalReply]) ?? 0 > 0 }
            let one = try await originBytes(rig)[.terminalReply]
            try await eventually("second reply") { (try? await originBytes(rig)[.terminalReply]) ?? 0 > one }
            try await Task.sleep(for: .milliseconds(300))
            // Um respondente só (AR-105): o headless do daemon calou-se com cliente anexado.
            #expect(try await originBytes(rig)[.terminalReply] == one * 2)
            #expect(try await originBytes(rig)[.key] == 0)
        }
    }

    @Test func reattachReplayDoesNotAnswerOldQueries() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let created = try await client.create(makeCreate(["/bin/sh", "-c", "printf '\\033[c'; printf 'ready\\n'; sleep 30"]))
        // Deixa o daemon (headless) responder e guardar a consulta no ring antes de qualquer UI anexar.
        try await Task.sleep(for: .milliseconds(400))
        let host = TerminalHostView(terminalID: "it-2")
        let window = makeWindow(hosting: host)
        _ = window
        let binding = TerminalSessionBinding(client: client, sessionID: created.session.sessionID, host: host)
        try await binding.start()
        try await eventually("replayed output") { String(decoding: host.surface.getBufferAsData(kind: .active), as: UTF8.self).contains("ready") }
        try await Task.sleep(for: .milliseconds(300))
        let sessions = try await client.list()
        let counts = sessions.first { $0.sessionID == created.session.sessionID }?.inputBytesByOrigin ?? InputByteCounts()
        // A UI não responde à consulta antiga que veio no replay; só o headless respondeu, quando estava sozinho.
        let headless = counts[.terminalReply]
        try await Task.sleep(for: .milliseconds(300))
        let again = try await client.list().first { $0.sessionID == created.session.sessionID }?.inputBytesByOrigin[.terminalReply] ?? 0
        #expect(again == headless)
        binding.stop()
        await client.stop()
        await harness.stop()
    }

    @Test func backlogOverTheLimitForcesASnapshot() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient(maxBacklogBytes: 64 << 10)
        try await client.start()
        let created = try await client.create(makeCreate(["/bin/sh", "-c", "head -c 4000000 /dev/zero | tr '\\0' 'x'; sleep 30"]))
        let attachment = try await client.attach(sessionID: created.session.sessionID, cols: 100, rows: 30)
        // Ninguém consome: o backlog passa de 64 KiB e o cliente pede um snapshot novo.
        var snapshots = 0
        var sawResync = false
        let deadline = ContinuousClock.now + .seconds(10)
        for await update in attachment.updates {
            switch update {
            case .snapshot: snapshots += 1
            case .event(.resyncRequired): sawResync = true
            default: break
            }
            if snapshots >= 2 || ContinuousClock.now > deadline { break }
        }
        #expect(sawResync)
        #expect(snapshots >= 2)
        await client.stop()
        await harness.stop()
    }
}
