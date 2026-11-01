import Foundation

@testable import RackyProtocol

enum Fixtures {
    static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Arquivos `.json` (ou `.hex`) de um subdiretório, ordenados por nome.
    static func files(_ directory: String, ext: String = "json") throws -> [URL] {
        let url = root.appendingPathComponent(directory, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func data(_ directory: String, _ name: String, ext: String = "json") throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(directory).appendingPathComponent("\(name).\(ext)"))
    }

    static func hexData(_ name: String) throws -> Data {
        let text = try String(contentsOf: root.appendingPathComponent("frames/\(name).hex"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hexDecode(text)
    }
}

func hexDecode(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index ..< next], radix: 16)!)
        index = next
    }
    return data
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func jsonObject(_ data: Data) throws -> NSObject {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
}

let sid1 = SessionID(string: "11111111-2222-4333-8444-555555555555")!
let sid2 = SessionID(string: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
let t0 = Date(timeIntervalSince1970: 1_792_238_400.0)  // milissegundos inteiros: round-trip exato
let t1 = Date(timeIntervalSince1970: 1_792_238_405.25)

func makeCreate(id: SessionID = sid1, coldLog: Bool = true) -> CreateRequest {
    CreateRequest(
        sessionID: id, argv: ["/bin/zsh", "-l"], cwd: "/Users/dev/project", env: ["HOME": "/Users/dev", "PATH": "/usr/bin"],
        cols: 120, rows: 40, term: "xterm-256color", ringBytes: 4 << 20, coldLog: coldLog, label: "claude",
        owner: SessionOwner(terminalID: "T-1", runID: "R-1"))
}

func makeSummary(_ id: SessionID = sid1) -> SessionSummary {
    var counts = InputByteCounts()
    counts.add(12, origin: .key)
    counts.add(4, origin: .terminalReply)
    return SessionSummary(
        sessionID: id, pid: 812, pgid: 812, argv0: "/bin/zsh", cwd: "/Users/dev/project", state: .running, startedAt: t0,
        lastOutputAt: t1, title: "zsh", endSeq: 4096, inputBytesByOrigin: counts)
}

let daemonInfo = DaemonInfo(build: "1.0 (41)", pid: 812, startedAt: t0, binary: "/Applications/Racky.app/Contents/MacOS/rackyd")

func clientInfo() -> ClientInfo { ClientInfo(kind: .app, build: "1.0 (42)") }

/// Uma amostra de cada requisição, resposta e evento do protocolo.
func allSampleMessages() -> [ControlMessage] {
    let requests: [DaemonCommand] = [
        .hello(HelloRequest(client: clientInfo(), capabilities: Capability.initialSet)),
        .create(makeCreate()),
        .create(CreateRequest(sessionID: sid2, argv: ["/bin/sh"], cwd: "/tmp", env: [:], cols: 80, rows: 24, coldLog: false, owner: SessionOwner(terminalID: "T", runID: "R"))),
        .list,
        .attach(AttachRequest(sessionID: sid1, cols: 120, rows: 40, mode: .snapshot)),
        .attach(AttachRequest(sessionID: sid1, cols: 120, rows: 40, mode: .sinceSeq(UInt64.max))),
        .detach(SessionTarget(sessionID: sid1)),
        .resize(ResizeRequest(sessionID: sid1, cols: 100, rows: 30)),
        .signal(SignalRequest(sessionID: sid1, signal: 2, target: .foreground)),
        .signal(SignalRequest(sessionID: sid1, signal: 15, target: .group)),
        .kill(KillRequest(sessionID: sid1, mode: .graceful)),
        .kill(KillRequest(sessionID: sid1, mode: .force)),
        .subscribe(SubscribeRequest(scope: .sessions([sid1, sid2]), events: EventKind.allCases)),
        .subscribe(SubscribeRequest(scope: .all, events: [.exit])),
        .textSnapshot(TextSnapshotRequest(sessionID: sid1, lines: 50)),
        .forget(SessionTarget(sessionID: sid1)),
        .drainWhenIdle,
        .shutdown,
        .ping,
    ]
    var messages: [ControlMessage] = requests.enumerated().map { .request(DaemonRequest(id: RequestID(rawValue: UInt64($0.offset + 1)), command: $0.element)) }

    let exited = SessionSummary(sessionID: sid2, argv0: "/bin/sh", cwd: "/tmp", state: .exited, startedAt: t0, exit: ExitInfo(signal: 9, at: t1), endSeq: 10)
    let replies: [DaemonReply] = [
        .helloAck(id: 1, HelloAck(protocolVersion: ProtocolVersion(major: 1, minor: 2), daemon: daemonInfo, capabilities: Capability.initialSet, sessions: 7)),
        .ok(id: 7, .empty),
        .ok(id: 2, .created(CreateResult(session: makeSummary(), spawned: true))),
        .ok(id: 2, .created(CreateResult(session: makeSummary(), spawned: false))),
        .ok(id: 4, .list(ListResult(sessions: [makeSummary(), exited]))),
        .ok(id: 4, .list(ListResult(sessions: []))),
        .ok(id: 17, .pong(PongInfo(at: t1, activeSessions: 3, uptimeMillis: 86_400_000))),
        .ok(id: 14, .textSnapshot(TextSnapshotResult(text: "$ vim\n~\n", lines: 2))),
        .attachSnapshot(id: 5, AttachSnapshot(sessionID: sid1, startSeq: 2048, endSeq: 4096, modesPreamble: Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68]))),
        .attachSnapshot(id: 6, AttachSnapshot(sessionID: sid1, startSeq: 100, endSeq: 200, modesPreamble: Data(), resumed: true)),
        .error(id: nil, DaemonError(.frameTooLarge, "too big")),
        .error(id: 2, DaemonError(.spawnFailed, "execve failed", errnoValue: 2, path: "/nonexistent")),
    ] + DaemonErrorCode.allCases.map { DaemonReply.error(id: 9, DaemonError($0, "msg \($0.rawValue)")) }
    messages += replies.map { .reply($0) }

    let payloads: [EventPayload] = [
        .exit(ExitInfo(code: 0, at: t1)), .exit(ExitInfo(signal: 9, at: t1)), .title(TitleEvent(text: "vim — main.swift")),
        .cwd(CwdEvent(path: "/Users/dev")), .bell, .prompt(PromptEvent(phase: .d, exitStatus: 1)), .prompt(PromptEvent(phase: .a)),
        .altScreen(AltScreenEvent(on: true)), .modes(ModesEvent(bracketedPaste: true, appCursor: false, mouse: true)),
        .idle(IdleEvent(since: t0)), .stillAlive, .resyncRequired, .sessionGone,
    ]
    messages += payloads.map { .event(DaemonEvent(sessionID: sid1, payload: $0)) }
    return messages
}
