import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Estados do pane (T1-16) com o `rackyd` real e CLI falso (`/bin/sh -c ...`): ignição só depois de 300 ms, running no
/// primeiro byte, exited com código, "Couldn't start" (spawn e saída precoce) e Restart/Retry reconstruindo o argv.
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct LaunchStatesIntegrationTests {
    private final class Rig {
        let harness: DaemonHarness
        let runtime: TerminalRuntime
        let model: WorkspaceModel
        let area: PaneAreaView
        let window: NSWindow
        let session = Session(kind: .clean, folderPath: NSTemporaryDirectory(), title: "it")

        let binDirectory: URL

        init(path extra: String? = nil) async throws {
            binDirectory = URL(fileURLWithPath: "/tmp/abbin-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            harness = try DaemonHarness()
            try await harness.start()
            runtime = TerminalRuntime(
                configuration: .init(
                    daemonHome: harness.home, daemonExecutable: rackydBinary(), stopDaemonOnQuit: false, appSocketPath: "/tmp/none.sock",
                    loginEnvironment: { [dir = binDirectory.path] in ["PATH": "\(dir):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"] }),
                registry: nil, elements: nil)
            model = WorkspaceModel(runtime: runtime)
            area = PaneAreaView(model: model, registry: nil, elements: nil, router: nil)
            window = OffscreenAppKit.makeWindow(size: NSSize(width: 1000, height: 600), styleMask: [.borderless])
            window.isReleasedWhenClosed = false
            window.contentView = area
            area.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            let s = session
            model.sessionLookup = { _ in s }
        }

        /// CLI falso `claude`/`codex`/`opencode` no PATH do env de login.
        func installFakeCLI(_ name: String, script: String) throws {
            let url = binDirectory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func launch(_ argv: [String], provider: TerminalProvider = .custom) -> UUID {
            let tabID = UUID.v7(), termID = UUID.v7()
            let spec = LaunchSpec(provider: provider, customArgv: provider == .custom ? argv : nil, initialPrompt: provider == .custom ? nil : "hi")
            let terminal = Terminal(id: termID, tabID: tabID, provider: provider, title: "t", cwd: NSTemporaryDirectory(), launchSpec: spec)
            let tab = Tab(id: tabID, sessionID: session.id, title: "t", layout: .leaf(Pane(content: .terminal(termID))), focusedTerminalID: termID)
            model.ingest(StoreSnapshot(sessions: [session], tabs: [tab], terminals: [terminal]))
            model.setSession(session.id)
            area.layoutSubtreeIfNeeded()
            return termID
        }

        func finish() async {
            window.close()
            await runtime.client.stop()
            await harness.stop()
        }
    }

    @Test func slowStartShowsIgnitionWithRealStepsThenRunningOnFirstByte() async throws {
        let rig = try await Rig()
        let id = rig.launch(["/bin/sh", "-c", "sleep 3; echo hello; exec cat"])
        try await eventually("ignition visible", timeout: .seconds(30)) { rig.model.ignitionVisible.contains(id) }
        guard case .starting = rig.model.paneState(id) else { Issue.record("must stay starting until the first byte"); return await rig.finish() }
        try await eventually("cli.exec row running", timeout: .seconds(30)) {
            rig.model.launchTimelines[id]?.rows.first(where: { $0.key == .cliExec })?.status == .running
        }
        #expect(rig.model.launchTimelines[id]?.rows.first(where: { $0.key == .launchConfig })?.status == .done)
        try await eventually("running after first byte", timeout: .seconds(30)) { rig.model.paneState(id) == .running }
        #expect(rig.model.launchTimelines[id]?.hasSeenFirstOutput == true)
        #expect(rig.model.launchTimelines[id]?.rows.first(where: { $0.key == .cliExec })?.status == .done)
        await rig.finish()
    }

    @Test func fakeClaudeThatPrintsAndExitsEndsExitedAndCapturesTheID() async throws {
        let rig = try await Rig()
        try rig.installFakeCLI("claude", script: "sleep 1; echo OK")
        let id = rig.launch([], provider: .claude)
        try await eventually("exited", timeout: .seconds(15)) { if case .exited(0, nil) = rig.model.paneState(id) { true } else { false } }
        #expect(rig.model.terminal(id)?.nativeConversationID != nil, "o UUID de --session-id fica no terminal")
        #expect(rig.model.terminal(id)?.state == .exited)
        await rig.finish()
    }

    @Test func fastStartSkipsTheIgnition() async throws {
        let rig = try await Rig()
        let clock = ContinuousClock()
        let start = clock.now
        let id = rig.launch(["/bin/sh", "-c", "echo hi; exec cat"])
        try await eventually("running", timeout: .seconds(30)) { rig.model.paneState(id) == .running }
        // Sob carga a máquina pode passar de 300 ms legitimamente; só vale a regra se o byte veio antes do limite.
        if clock.now - start < .milliseconds(250) { #expect(!rig.model.ignitionVisible.contains(id), "primeiro byte antes de 300 ms: M-506, sem placeholder") }
        await rig.finish()
    }

    @Test func exitWithCodeAfterOutputIsExitedAndRestartRebuildsTheLaunch() async throws {
        let rig = try await Rig()
        let id = rig.launch(["/bin/sh", "-c", "echo hi; exit 2"])
        try await eventually("exited", timeout: .seconds(30)) { if case .exited(2, nil) = rig.model.paneState(id) { true } else { false } }
        #expect(rig.model.terminal(id)?.state == .exited)
        let first = rig.model.terminal(id)?.currentRunID
        rig.model.restart(id)
        try await eventually("exited again", timeout: .seconds(30)) {
            if case .exited(2, nil) = rig.model.paneState(id), let run = rig.model.terminal(id)?.currentRunID { run != first } else { false }
        }
        await rig.finish()
    }

    @Test func earlyExitWithoutOutputIsCouldntStart() async throws {
        let rig = try await Rig()
        let id = rig.launch(["/bin/sh", "-c", "exit 3"])
        try await eventually("failed", timeout: .seconds(30)) { if case .failed = rig.model.paneState(id) { true } else { false } }
        if case .failed(let detail) = rig.model.paneState(id) { #expect(detail.contains("exited with code 3")) }
        #expect(rig.model.terminal(id)?.state == .failedToStart)
        await rig.finish()
    }

    @Test func spawnFailureIsCouldntStartAndRetryTriesAgain() async throws {
        let rig = try await Rig()
        let id = rig.launch(["/definitely/not/here/tool"])
        try await eventually("failed", timeout: .seconds(30)) { if case .failed = rig.model.paneState(id) { true } else { false } }
        if case .failed(let detail) = rig.model.paneState(id) { #expect(detail.contains("/definitely/not/here/tool")) }
        rig.model.restart(id)  // Try Again
        try await eventually("failed again after a fresh attempt", timeout: .seconds(30)) {
            if case .failed = rig.model.paneState(id), rig.model.launchTimelines[id]?.runID != nil { true } else { false }
        }
        await rig.finish()
    }

    @Test func cancelDuringIgnitionRemovesThePane() async throws {
        let rig = try await Rig()
        let id = rig.launch(["/bin/sh", "-c", "sleep 30"])
        try await eventually("ignition visible", timeout: .seconds(30)) { rig.model.ignitionVisible.contains(id) }
        rig.model.cancelLaunch(id)
        try await eventually("pane gone", timeout: .seconds(30)) { rig.model.terminal(id) == nil }
        await rig.finish()
    }
}
