import RackyCore
import RackyProtocol
import Foundation
import Testing

/// Reattach (06 §1.5, S-04): cliente morto, cliente novo, mesma tela. Avaliação em duas etapas:
/// (a) o replay antes do redraw reproduz a tela de quem ficou conectado; (b) depois do redraw `cols-1`/`cols`
/// o cliente novo iguala o observador que recebeu os mesmos bytes.
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(3))) struct ReattachTests {
    struct Outcome {
        var before: String
        var replayOnly: String
        var observer: String
        var afterRedraw: String
        var daemonText: String
        var replicaText: String
        var replayInfo: String
    }

    private let esc = "\u{1b}"

    /// Roda um ciclo completo e devolve as telas para comparação.
    private func cycle(
        _ harness: DaemonHarness, argv: [String], startup: Duration, script: [(Duration, String)], ringBytes: Int = 4 << 20, cols: UInt16 = 100,
        rows: UInt16 = 30
    ) async throws -> Outcome {
        let clientA = harness.makeClient()
        try await clientA.start()
        let create = makeCreate(argv, cols: cols, rows: rows, ringBytes: ringBytes)
        _ = try await clientA.create(create)
        let replicaA = Replica(cols: Int(cols), rows: Int(rows))
        await replicaA.run(try await clientA.attach(sessionID: create.sessionID, cols: cols, rows: rows))

        let clientO = harness.makeClient()
        try await clientO.start()
        let replicaO = Replica(cols: Int(cols), rows: Int(rows))
        await replicaO.run(try await clientO.attach(sessionID: create.sessionID, cols: cols, rows: rows))

        try await Task.sleep(for: startup)
        await replicaA.waitQuiet(.milliseconds(500))
        for (delay, text) in script {
            try await Task.sleep(for: delay)
            try await clientA.sendInput(sessionID: create.sessionID, origin: .key, bytes: data(text))
        }
        await replicaA.waitQuiet(.milliseconds(500))
        await replicaO.waitQuiet(.milliseconds(300))
        let before = await replicaA.screen()
        let daemonText = try await clientA.textSnapshot(sessionID: create.sessionID, lines: 5000)
        let replicaText = await replicaA.bufferText(lines: 5000)

        // Mata o cliente A (a sessão continua no daemon).
        await replicaA.stop()
        await clientA.stop()
        try await Task.sleep(for: .milliseconds(200))

        let clientB = harness.makeClient()
        try await clientB.start()
        let replicaB = Replica(cols: Int(cols), rows: Int(rows))
        await replicaB.run(try await clientB.attach(sessionID: create.sessionID, cols: cols, rows: rows))
        await replicaB.waitQuiet(.milliseconds(700))
        await replicaO.waitQuiet(.milliseconds(300))
        let replayOnly = await replicaB.replayScreen ?? "<none>"
        let replayInfo = await replicaB.replayDescription
        let afterRedraw = await replicaB.screen()
        let observer = await replicaO.screen()

        try? await clientB.kill(sessionID: create.sessionID, mode: .force)
        await replicaB.stop()
        await replicaO.stop()
        await clientB.stop()
        await clientO.stop()
        return Outcome(
            before: before, replayOnly: replayOnly, observer: observer, afterRedraw: afterRedraw, daemonText: daemonText,
            replicaText: replicaText, replayInfo: replayInfo)
    }

    private func check(_ name: String, repetitions: Int, argv: [String], startup: Duration, script: [(Duration, String)], ringBytes: Int = 4 << 20, markers: [String] = [])
        async throws
    {
        let harness = try DaemonHarness()
        try await harness.start()
        defer { harness.terminateNow() }
        var failures: [String] = []
        for repetition in 1 ... repetitions {
            let outcome = try await cycle(harness, argv: argv, startup: startup, script: script, ringBytes: ringBytes)
            if outcome.before != outcome.replayOnly { failures.append("rep \(repetition) replay-only differs (\(outcome.replayInfo))\nA:\n\(outcome.before)\nB:\n\(outcome.replayOnly)") }
            if outcome.observer != outcome.afterRedraw { failures.append("rep \(repetition) after-redraw differs\nO:\n\(outcome.observer)\nB:\n\(outcome.afterRedraw)") }
            for marker in markers where !outcome.replayOnly.contains(marker) { failures.append("rep \(repetition): marker \(marker.debugDescription) missing in\n\(outcome.replayOnly)") }
            if outcome.daemonText != outcome.replicaText { failures.append("rep \(repetition) daemon textSnapshot differs from the client emulator") }
        }
        #expect(failures.isEmpty, "\(name): \(failures.count) failure(s) in \(repetitions) repetitions\n\(failures.prefix(2).joined(separator: "\n---\n"))")
    }

    @Test func vim20() async throws {
        let dir = "/tmp/abd-vim-\(UInt32.random(in: 0 ... 0xFFFFFF))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "seed\n".write(toFile: "\(dir)/v.txt", atomically: true, encoding: .utf8)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/vim") else { return }
        try await check(
            "vim", repetitions: 20, argv: ["/usr/bin/vim", "-u", "NONE", "-n", "\(dir)/v.txt"], startup: .milliseconds(900),
            script: [(.milliseconds(200), "ihello from test\rsecond line\(esc)"), (.milliseconds(300), ":set number\r"), (.milliseconds(300), "ggOtop\(esc)")], markers: ["hello from test", "second line", "alt=true", "top"])
    }

    @Test func miniTUI20() async throws {
        let program =
            "stty -echo; printf '\\033]0;mini tui\\007\\033[?1049h\\033[?2004h\\033[?1000h\\033[?25l\\033[2J\\033[3;5HMINI TUI READY\\033[5;5Hcount: 0'; n=0; "
            + "while IFS= read -r line; do n=$((n+1)); printf '\\033[7;5Hgot %s (%d)\\033[K\\033[5;5Hcount: %d' \"$line\" $n $n; done"
        try await check(
            "miniTUI", repetitions: 20, argv: ["/bin/sh", "-c", program], startup: .milliseconds(300),
            script: [(.milliseconds(100), "one\n"), (.milliseconds(100), "two\n"), (.milliseconds(100), "three\n")], markers: ["MINI TUI READY", "count: 3", "got three", "alt=true", "bp=true", "appCursor=false"])
    }

    @Test func shellWithBracketedPaste20() async throws {
        try await check(
            "zsh", repetitions: 20, argv: ["/bin/zsh", "-f", "-i"], startup: .milliseconds(600),
            script: [(.milliseconds(100), "echo hello-test\r"), (.milliseconds(200), "ls /etc | head -3\r"), (.milliseconds(200), "partial command")], markers: ["hello-test", "partial command"])
    }

    /// S-04: alt-screen com muito mais saída que o ring e sem `2J`: o corte sai do ring e o checkpoint de 64 KiB resolve.
    @Test func altScreenOverflowUsesCheckpoint() async throws {
        let program =
            "printf '\(esc)[?1049h\(esc)[?25l\(esc)[?1000h'; yes \"$(printf '\(esc)[H\(esc)[31mrow of alt content\(esc)[0m')\" | head -c 3000000; printf '\(esc)[3;5HFINAL MARKER'; exec sleep 600"
        let harness = try DaemonHarness()
        try await harness.start()
        defer { harness.terminateNow() }
        var failures: [String] = []
        for repetition in 1 ... 5 {
            let outcome = try await cycle(harness, argv: ["/bin/sh", "-c", program], startup: .seconds(3), script: [], ringBytes: 1 << 20)
            if !outcome.replayInfo.contains("checkpoint") { failures.append("rep \(repetition): expected a checkpoint replay, got \(outcome.replayInfo)") }
            if !outcome.replayOnly.contains("alt=true") || outcome.replayOnly.contains("mouse=off") {
                failures.append("rep \(repetition): replay lost alt-screen/mouse\n\(outcome.replayOnly)")
            }
            if !outcome.replayOnly.contains("FINAL MARKER") { failures.append("rep \(repetition): FINAL MARKER missing") }
            if outcome.before != outcome.replayOnly { failures.append("rep \(repetition): replay differs from the connected client\nA:\n\(outcome.before)\nB:\n\(outcome.replayOnly)") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(2).joined(separator: "\n---\n"))")
    }
}
