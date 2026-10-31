import Foundation
import Synchronization
import Testing
@testable import RackyPlatform

@Suite struct PerfTests {
    final class Box: Sendable {
        private let items = Mutex<[MetricSample]>([])
        func add(_ s: MetricSample) { items.withLock { $0.append(s) } }
        var all: [MetricSample] { items.withLock { $0 } }
    }

    @Test func intervalRecordsOneMetricWithDurationAndTags() async throws {
        let recorder = MetricRecorder()
        let box = Box()
        recorder.install { box.add($0) }
        let interval = Perf.begin(.attach, tags: ["mode": "snapshot"], recorder: recorder)
        try await Task.sleep(for: .milliseconds(20))
        let ms = interval.end(tags: ["result": "ok"])
        interval.end()  // segunda chamada não grava de novo
        #expect(ms >= 15)
        let sample = try #require(box.all.first)
        #expect(box.all.count == 1 && sample.name == "attach.replay" && sample.unit == "ms")
        #expect(sample.tags == ["mode": "snapshot", "result": "ok"] && sample.value >= 15)
    }

    @Test func measureWrapsAThrowingBody() async {
        let recorder = MetricRecorder()
        let box = Box()
        recorder.install { box.add($0) }
        struct Boom: Error {}
        _ = try? await Perf.measure(.launch, recorder: recorder) { throw Boom() }
        #expect(box.all.map(\.name) == ["launch.agent"])
    }

    @Test func samplesBeforeTheSinkExistAreKeptAndDelivered() {
        let recorder = MetricRecorder()
        recorder.record("boot.first_window", milliseconds: 321)
        let box = Box()
        recorder.install { box.add($0) }
        #expect(box.all.map(\.name) == ["boot.first_window"] && box.all.first?.value == 321)
        recorder.record("x", milliseconds: 1)
        #expect(box.all.count == 2)
    }

    @Test func everyPointHasAStableName() {
        #expect(Set(PerfPoint.allCases.map(\.rawValue)) == [
            "boot.first_window", "launch.agent", "attach.replay", "terminal.first_byte", "terminal.resize", "computer.provision", "vnc.connect",
        ])
    }
}
