import Foundation
import Testing
@testable import RackyProtocol

@Suite struct LayoutTests {
    static func pane() -> Pane { Pane(content: .terminal(.v7())) }

    @Test func splitAndRemove() throws {
        let a = Self.pane(), b = Self.pane(), c = Self.pane()
        var layout = PaneLayout.leaf(a)
        layout = try #require(layout.splitting(paneID: a.id, axis: .horizontal, inserting: b))
        layout = try #require(layout.splitting(paneID: b.id, axis: .vertical, ratio: 0.3, inserting: c))
        #expect(layout.panes.map(\.id) == [a.id, b.id, c.id])
        #expect(layout.isValid)
        let removed = try #require(layout.removing(paneID: b.id))
        #expect(removed.panes.map(\.id) == [a.id, c.id])
        #expect(layout.removing(paneID: UUID()) == nil)
        #expect(PaneLayout.leaf(a).removing(paneID: a.id) == nil, "o último pane não pode ser removido")
    }

    @Test func terminalAppearsInAtMostOnePane() {
        let a = Self.pane()
        let dup = Pane(content: a.content)
        #expect(PaneLayout.leaf(a).splitting(paneID: a.id, axis: .horizontal, inserting: dup) == nil)
        let bad = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(dup))
        #expect(!bad.isValid)
    }

    @Test func ratioIsClampedAndValidated() throws {
        let a = Self.pane(), b = Self.pane()
        let l = try #require(PaneLayout.leaf(a).splitting(paneID: a.id, axis: .horizontal, ratio: 9, inserting: b))
        guard case .split(_, let r, _, _) = l else { Issue.record("expected split"); return }
        #expect(r == PaneLayout.maxRatio)
        let adjusted = l.settingRatio(splitWithFirstPane: a.id, ratio: -3)
        guard case .split(_, let r2, _, _) = adjusted else { Issue.record("expected split"); return }
        #expect(r2 == PaneLayout.minRatio)
        #expect(!PaneLayout.split(axis: .vertical, ratio: 1.5, first: .leaf(a), second: .leaf(b)).isValid)
    }

    @Test func codableRoundTrip() throws {
        let a = Self.pane(), b = Pane(content: .computerViewer(.v7()))
        let l = try #require(PaneLayout.leaf(a).splitting(paneID: a.id, axis: .vertical, ratio: 0.25, inserting: b))
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == l)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PaneLayout.self, from: Data(#"{"type":"nope"}"#.utf8))
        }
    }
}

@Suite struct DomainModelTests {
    @Test func uuidV7IsVersion7AndOrdered() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUID.v7(at: t0), b = UUID.v7(at: t0.addingTimeInterval(1))
        #expect(a.uuidString.dropFirst(14).first == "7")
        #expect(a.uuidString < b.uuidString)
        #expect(["8", "9", "A", "B"].contains(String(a.uuidString.dropFirst(19).first ?? " ")))
    }

    @Test func sessionStructuralRules() {
        let proj = UUID.v7(), wt = UUID.v7()
        #expect(Session(kind: .clean, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(!Session(kind: .clean, projectID: proj, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(Session(kind: .worktree, projectID: proj, worktreeID: wt, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(!Session(kind: .worktree, projectID: proj, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(Session(kind: .checkout, projectID: proj, worktreeID: wt, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(Session(kind: .folder, projectID: proj, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(!Session(kind: .folder, folderPath: "/x", title: "t").isStructurallyValid)
        #expect(!Session(kind: .folder, projectID: proj, worktreeID: wt, folderPath: "/x", title: "t").isStructurallyValid)
    }

    @Test func launchSpecAndTerminalCodable() throws {
        let spec = LaunchSpec(provider: .claude, model: "opus", permissionMode: "bypass", extraArgs: ["--x"],
                              envOverrides: ["A": "1"], initialPrompt: "hi", nativeSessionID: "abc")
        let t = Terminal(tabID: .v7(), provider: .claude, title: "c", cwd: "/", launchSpec: spec,
                         resolvedArgv: ResolvedArgv(executable: ["claude"], identity: ["--session-id", "abc"], prompt: ["hi"]))
        let back = try JSONDecoder().decode(Terminal.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        #expect(t.resolvedArgv?.flattened == ["claude", "--session-id", "abc", "hi"])
    }
}
