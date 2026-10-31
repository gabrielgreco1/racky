import Foundation
import Testing

@testable import RackyProtocol

@Suite struct BackpressureTests {
    private func output(_ session: SessionID, seq: UInt64, size: Int) -> Frame {
        .output(OutputFrame(sessionID: session, seq: seq, bytes: Data(count: size)))
    }

    private func pop(_ queue: inout OutboundQueue) throws -> Frame {
        guard let frame = queue.dequeue() else { throw FrameError.emptyFrame }
        return frame
    }

    private func isResync(_ frame: Frame, for session: SessionID) -> Bool {
        if case .control(.event(let event)) = frame, event.sessionID == session, event.payload == .resyncRequired { return true }
        return false
    }

    @Test func queueUnderLimitAcceptsAndPreservesOrder() throws {
        var queue = OutboundQueue(limitBytes: 1000)
        let frames = (0 ..< 5).map { output(sid1, seq: UInt64($0) * 100, size: 100) }
        for frame in frames { #expect(try queue.enqueue(frame) == .queued) }
        #expect(queue.count == 5 && queue.pendingBytes == 5 * (5 + 24 + 100))
        for frame in frames { #expect(queue.dequeue() == frame) }
        #expect(queue.isEmpty && queue.pendingBytes == 0 && queue.dequeue() == nil)
    }

    @Test func defaultLimitIsTwoMiB() {
        #expect(OutboundQueue().limitBytes == 2 * 1024 * 1024)
    }

    @Test func overflowDropsQueuedOutputAndEmitsResyncRequired() throws {
        var queue = OutboundQueue(limitBytes: 400)
        #expect(try queue.enqueue(output(sid1, seq: 0, size: 100)) == .queued)
        #expect(try queue.enqueue(output(sid2, seq: 0, size: 100)) == .queued)
        let result = try queue.enqueue(output(sid1, seq: 100, size: 200))
        #expect(result == .overflow(resyncSessions: [sid1, sid2]))
        #expect(queue.isAwaitingResync(sid1) && queue.isAwaitingResync(sid2))
        // Só sobram os dois resyncRequired.
        let first = try pop(&queue)
        let second = try pop(&queue)
        #expect(isResync(first, for: sid1) && isResync(second, for: sid2))
        #expect(queue.isEmpty)
    }

    @Test func sessionNeverBlocksOnASlowClient() throws {
        // `enqueue` nunca espera nem lança por estouro: 10 MiB empurrados para uma fila de 2 MiB que ninguém drena.
        var queue = OutboundQueue()
        var overflows = 0
        var seq: UInt64 = 0
        for _ in 0 ..< 160 {
            let frame = output(sid1, seq: seq, size: 64 << 10)
            seq += UInt64(64 << 10)
            if case .overflow = try queue.enqueue(frame) { overflows += 1 }
        }
        #expect(overflows == 1)  // depois do estouro, a sessão aguarda resync e o resto é descartado
        #expect(queue.pendingBytes < 1024)
    }

    @Test func outputIsDiscardedWhileAwaitingResyncThenResumesAfterReattach() throws {
        var queue = OutboundQueue(limitBytes: 200)
        _ = try queue.enqueue(output(sid1, seq: 0, size: 100))
        #expect(try queue.enqueue(output(sid1, seq: 100, size: 150)) == .overflow(resyncSessions: [sid1]))
        #expect(try queue.enqueue(output(sid1, seq: 250, size: 10)) == .discarded)
        // Outra sessão não é afetada.
        #expect(try queue.enqueue(output(sid2, seq: 0, size: 10)) == .queued)
        queue.didResync(sid1)
        #expect(!queue.isAwaitingResync(sid1))
        #expect(try queue.enqueue(output(sid1, seq: 4096, size: 10)) == .queued)
    }

    @Test func controlFramesAreNeverDropped() throws {
        var queue = OutboundQueue(limitBytes: 300)
        let reply = Frame.control(.reply(.ok(id: 1, .empty)))
        let event = Frame.control(.event(DaemonEvent(sessionID: sid1, payload: .title(TitleEvent(text: "t")))))
        #expect(try queue.enqueue(reply) == .queued)
        #expect(try queue.enqueue(output(sid1, seq: 0, size: 100)) == .queued)
        #expect(try queue.enqueue(event) == .queued)
        #expect(try queue.enqueue(output(sid1, seq: 100, size: 500)) == .overflow(resyncSessions: [sid1]))
        var drained: [Frame] = []
        while let frame = queue.dequeue() { drained.append(frame) }
        #expect(drained.count == 3)
        #expect(drained[0] == reply && drained[1] == event && isResync(drained[2], for: sid1))
    }

    @Test func controlFramesAreAcceptedEvenAboveTheLimit() throws {
        var queue = OutboundQueue(limitBytes: 10)
        let reply = Frame.control(.reply(.ok(id: 1, .empty)))
        #expect(try queue.enqueue(reply) == .queued)
        #expect(try queue.enqueue(output(sid1, seq: 0, size: 1)) == .overflow(resyncSessions: [sid1]))
    }

    @Test func removeOutputForgetsPendingFramesAndResyncState() throws {
        var queue = OutboundQueue(limitBytes: 1000)
        _ = try queue.enqueue(output(sid1, seq: 0, size: 10))
        _ = try queue.enqueue(output(sid2, seq: 0, size: 10))
        queue.removeOutput(for: sid1)
        #expect(queue.count == 1)
        guard case .output(let remaining) = try pop(&queue) else {
            Issue.record("expected output")
            return
        }
        #expect(remaining.sessionID == sid2 && queue.pendingBytes == 0)

        var overflowing = OutboundQueue(limitBytes: 50)
        _ = try overflowing.enqueue(output(sid1, seq: 0, size: 100))
        #expect(overflowing.isAwaitingResync(sid1))
        overflowing.removeOutput(for: sid1)
        #expect(!overflowing.isAwaitingResync(sid1))
    }

    @Test func pendingBytesAccountingStaysExactAcrossOverflow() throws {
        var queue = OutboundQueue(limitBytes: 500)
        _ = try queue.enqueue(output(sid1, seq: 0, size: 200))
        _ = try queue.enqueue(output(sid1, seq: 200, size: 400))  // estouro
        var total = 0
        var drained = 0
        while let frame = queue.dequeue() {
            total += try FrameCodec.wireSize(of: frame)
            drained += 1
        }
        #expect(drained == 1 && total > 0 && queue.pendingBytes == 0)
    }

    @Test func oversizedFrameIsRejectedNotQueued() {
        var queue = OutboundQueue()
        let tooBig = Frame.output(OutputFrame(sessionID: sid1, seq: 0, bytes: Data(count: ProtocolLimits.maxFrameLength)))
        #expect(throws: FrameError.self) { try queue.enqueue(tooBig) }
        #expect(queue.isEmpty)
    }
}

@Suite struct CommandValidationTests {
    private func bad(_ command: DaemonCommand) -> DaemonError? {
        do {
            try command.validate()
            return nil
        } catch {
            return error
        }
    }

    @Test func validCommandsPass() {
        #expect(bad(.create(makeCreate())) == nil)
        #expect(bad(.list) == nil)
        #expect(bad(.signal(SignalRequest(sessionID: sid1, signal: 31, target: .group))) == nil)
        #expect(bad(.resize(ResizeRequest(sessionID: sid1, cols: 1, rows: 1))) == nil)
    }

    @Test func createRejectsBadFields() {
        var request = makeCreate()
        request.argv = []
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.argv = [""]
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.cwd = ""
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.cols = 0
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.rows = 0
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.ringBytes = 100
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.ringBytes = 33 << 20
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.env = ["A=B": "x"]
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.env = ["": "x"]
        #expect(bad(.create(request))?.code == .badRequest)
        request = makeCreate()
        request.term = ""
        #expect(bad(.create(request))?.code == .badRequest)
    }

    @Test func resizeAttachSignalSubscribeTextSnapshotRejectBadFields() {
        #expect(bad(.resize(ResizeRequest(sessionID: sid1, cols: 0, rows: 10))) != nil)
        #expect(bad(.attach(AttachRequest(sessionID: sid1, cols: 10, rows: 0, mode: .snapshot))) != nil)
        #expect(bad(.signal(SignalRequest(sessionID: sid1, signal: 0, target: .group))) != nil)
        #expect(bad(.signal(SignalRequest(sessionID: sid1, signal: 32, target: .group))) != nil)
        #expect(bad(.subscribe(SubscribeRequest(scope: .all, events: []))) != nil)
        #expect(bad(.textSnapshot(TextSnapshotRequest(sessionID: sid1, lines: 0))) != nil)
        #expect(bad(.textSnapshot(TextSnapshotRequest(sessionID: sid1, lines: TextSnapshotRequest.maxLines + 1))) != nil)
    }
}
