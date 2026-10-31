import Foundation
import Synchronization
import Testing

@testable import RackyTerminalCore

@Suite struct RingBufferTests {
    @Test func linearThenWraps() {
        var ring = RingBuffer(capacity: 8)
        ring.append(Array("abcd".utf8))
        #expect(ring.startSeq == 0 && ring.endSeq == 4)
        #expect(String(decoding: ring.read(from: 0, to: 4), as: UTF8.self) == "abcd")
        ring.append(Array("efghij".utf8))
        #expect(ring.endSeq == 10 && ring.startSeq == 2)
        #expect(String(decoding: ring.read(from: 2, to: 10), as: UTF8.self) == "cdefghij")
        #expect(String(decoding: ring.read(from: 0, to: 5), as: UTF8.self) == "cde")  // ajustado ao que existe
    }

    @Test func chunkLargerThanCapacityKeepsTail() {
        var ring = RingBuffer(capacity: 4)
        ring.append(Array("0123456789".utf8))
        #expect(ring.endSeq == 10 && ring.startSeq == 6)
        #expect(String(decoding: ring.read(from: 6, to: 10), as: UTF8.self) == "6789")
        ring.append(Array("ab".utf8))
        #expect(String(decoding: ring.read(from: 8, to: 12), as: UTF8.self) == "89ab")
    }

    @Test func randomizedAgainstModel() {
        var ring = RingBuffer(capacity: 37)
        var model: [UInt8] = []
        for _ in 0 ..< 500 {
            let chunk = (0 ..< Int.random(in: 1 ... 90)).map { _ in UInt8.random(in: 0 ... 255) }
            ring.append(chunk)
            model.append(contentsOf: chunk)
            #expect(ring.read(from: ring.startSeq, to: ring.endSeq) == Array(model.suffix(37)))
            #expect(ring.endSeq == UInt64(model.count))
        }
    }
}

@Suite struct VTTrackerTests {
    private func run(_ chunks: [String]) -> (tracker: VTTracker, cuts: [CutEvent], events: [TrackerEvent]) {
        var tracker = VTTracker()
        var seq: UInt64 = 0
        for chunk in chunks {
            let bytes = Array(chunk.utf8)
            tracker.feed(bytes, startSeq: seq)
            seq += UInt64(bytes.count)
        }
        let cuts = tracker.takeCuts()
        let events = tracker.takeEvents()
        return (tracker, cuts, events)
    }

    @Test func altScreenEntryIsACutAndSetsModes() {
        let result = run(["abc\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?2004h"])
        #expect(result.cuts.map(\.seq) == [3])
        #expect(result.tracker.state.isAlt)
        #expect(result.tracker.state.dec[25] == false)
        #expect(result.tracker.state.mouse && result.tracker.state.bracketedPaste)
        #expect(result.events.contains(.altScreen(true)))
    }

    @Test func sequenceSplitAcrossChunksStillCuts() {
        let result = run(["xx\u{1b}", "[", "?10", "49", "h"])
        #expect(result.cuts.map(\.seq) == [2])
        #expect(result.tracker.state.isAlt)
    }

    @Test func escInsideCSIRestartsTheSequence() {
        let result = run(["\u{1b}[12\u{1b}[2J"])
        #expect(result.cuts.map(\.seq) == [4])
    }

    @Test func clearAndResetAreCuts() {
        let result = run(["a\u{1b}[2Jb\u{1b}[3Jc\u{1b}c"])
        #expect(result.cuts.map(\.seq) == [1, 6, 11])
        #expect(result.tracker.state == ModeState())
    }

    @Test func cutRecordsTheStateBeforeTheSequence() {
        let result = run(["\u{1b}[?2004h", "\u{1b}[?1049h"])
        let cut = result.cuts.first
        #expect(cut?.before.bracketedPaste == true)
        #expect(cut?.before.isAlt == false)
    }

    @Test func titleCwdPromptBellEvents() {
        let result = run(["\u{1b}]0;my title\u{07}", "\u{1b}]7;file://host/Users/me/a%20b\u{1b}\\", "\u{1b}]133;A\u{07}\u{1b}]133;D;7\u{07}", "\u{07}"])
        #expect(result.events.contains(.title("my title")))
        #expect(result.events.contains(.cwd("/Users/me/a b")))
        #expect(result.events.contains(.prompt(phase: "A", exitStatus: nil)))
        #expect(result.events.contains(.prompt(phase: "D", exitStatus: 7)))
        #expect(result.events.contains(.bell))
        #expect(result.tracker.state.title == Array("my title".utf8))
    }

    @Test func bellTerminatingAnOSCIsNotABell() {
        let result = run(["\u{1b}]0;t\u{07}"])
        #expect(!result.events.contains(.bell))
    }

    @Test func preambleRestoresModes() {
        var state = ModeState()
        state.dec = [1049: true, 2004: true, 25: false, 1000: true, 1006: true]
        state.keypadApp = true
        state.title = Array("hi".utf8)
        let text = String(decoding: state.preamble(cursor: (x: 4, y: 2)), as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}[?1049h"))
        for fragment in ["\u{1b}[?25l", "\u{1b}[?2004h", "\u{1b}[?1000h", "\u{1b}[?1006h", "\u{1b}=", "\u{1b}]0;hi\u{07}", "\u{1b}[3;5H"] {
            #expect(text.contains(fragment), "missing \(fragment.debugDescription)")
        }
    }

    @Test func modesEventOnlyOnChange() {
        let result = run(["\u{1b}[?2004h\u{1b}[?2004h"])
        #expect(result.events.filter { if case .modes = $0 { true } else { false } }.count == 1)
    }
}

@Suite struct ReplayIndexTests {
    @Test func prefersLatestCutThenOldestCheckpointThenRingStart() {
        var index = ReplayIndex()
        #expect(index.choose(ringStart: 0) == nil)
        index.recordCheckpoint(seq: 65536, state: ModeState())
        index.recordCheckpoint(seq: 131_072, state: ModeState())
        #expect(index.choose(ringStart: 0)?.seq == 65536)
        #expect(index.choose(ringStart: 70000)?.seq == 131_072)
        index.recordCut(CutEvent(seq: 140_000, before: ModeState()))
        #expect(index.choose(ringStart: 0)?.seq == 140_000)
        index.prune(ringStart: 150_000)
        #expect(index.choose(ringStart: 150_000) == nil)
    }

    @Test func checkpointsOnlyOutsideSequencesEvery64KiB() {
        let index = ReplayIndex()
        #expect(!index.wantsCheckpoint(at: 1000, parserIsNormal: true))
        #expect(index.wantsCheckpoint(at: 65536, parserIsNormal: true))
        #expect(!index.wantsCheckpoint(at: 65536, parserIsNormal: false))
    }
}

@Suite struct QueryReplyFilterTests {
    @Test func blocksOSCAndDCSRepliesButAllowsDeviceReports() {
        #expect(!QueryReplyFilter.allows(Array("\u{1b}]52;c;aGk=\u{1b}\\".utf8)))
        #expect(!QueryReplyFilter.allows(Array("\u{1b}]11;rgb:0000/0000/0000\u{07}".utf8)))
        #expect(!QueryReplyFilter.allows(Array("\u{1b}P1$r0m\u{1b}\\".utf8)))
        #expect(QueryReplyFilter.allows(Array("\u{1b}[?1;2c".utf8)))
        #expect(QueryReplyFilter.allows(Array("\u{1b}[0n".utf8)))
        #expect(QueryReplyFilter.allows(Array("\u{1b}[8;30;100t".utf8)))
    }
}

@Suite struct HeadlessEmulatorHostTests {
    @Test func textSnapshotAndCursorMarks() async {
        let host = HeadlessEmulatorHost(cols: 20, rows: 5, allowReplies: { true }, reply: { _ in }, onDrained: {})
        host.feed(Array("hello\r\nworld\r\n".utf8), marks: [EmulatorMark(offset: 7, key: 7)])
        await host.barrier()
        #expect(host.cursor(forKey: 7)?.y == 1)
        let text = await host.textSnapshot(lines: 10)
        #expect(text == "hello\nworld")
        host.pruneCursors(below: 100)
        #expect(host.cursor(forKey: 7) == nil)
    }

    @Test func repliesRespectPolicy() async {
        let replies = Mutex(0)
        let allow = Mutex(true)
        let host = HeadlessEmulatorHost(
            cols: 20, rows: 5, allowReplies: { allow.withLock { $0 } }, reply: { _ in replies.withLock { $0 += 1 } }, onDrained: {})
        host.feed(Array("\u{1b}[c\u{1b}]52;c;?\u{07}\u{1b}]11;?\u{07}".utf8), marks: [])
        await host.barrier()
        #expect(replies.withLock { $0 } == 1, "only DA1 is answered; OSC 52 read and OSC 11 query never")
        allow.withLock { $0 = false }
        host.feed(Array("\u{1b}[c".utf8), marks: [])
        await host.barrier()
        #expect(replies.withLock { $0 } == 1, "no reply while a client is attached")
    }
}
