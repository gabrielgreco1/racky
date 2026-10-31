import Foundation
import Testing
@testable import RackyCore

@Suite struct CrashMonitorTests {
    private func dirs() throws -> (run: URL, reports: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abcrash-\(UUID().uuidString)", isDirectory: true)
        let run = root.appendingPathComponent("run"), reports = root.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        return (run, reports, { try? FileManager.default.removeItem(at: root) })
    }

    private func monitor(_ d: (run: URL, reports: URL, cleanup: () -> Void), alive: Set<Int32> = [], now: Date = Date()) -> CrashMonitor {
        CrashMonitor(runDirectory: d.run, reportsDirectory: d.reports, isAlive: { alive.contains($0) }, now: { now })
    }

    @Test func firstBootAndCleanExitReportNothing() throws {
        let d = try dirs(); defer { d.cleanup() }
        #expect(monitor(d).begin(build: "1", pid: 100) == nil)
        monitor(d).endCleanly()
        #expect(!FileManager.default.fileExists(atPath: d.run.appendingPathComponent("app.alive").path))
        #expect(monitor(d).begin(build: "2", pid: 101) == nil)
        #expect(monitor(d).lastCrash() == nil)
    }

    @Test func leftoverSentinelWithDeadPidIsAnUnexpectedExitReportedOnce() throws {
        let d = try dirs(); defer { d.cleanup() }
        let started = Date(timeIntervalSinceNow: -3600)
        _ = monitor(d, now: started).begin(build: "1.0 (7)", pid: 100)
        let report = d.reports.appendingPathComponent("Racky-2026-10-20-120000.ips")
        let body = #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at /Users/me/secret"},"termination":{"indicator":"Segmentation fault: 11"}}"#
        try ("{\"app_name\":\"Racky\"}\n" + body).write(to: report, atomically: true, encoding: .utf8)
        try "{}".write(to: d.reports.appendingPathComponent("Safari-2026.ips"), atomically: true, encoding: .utf8)

        let found = try #require(monitor(d).begin(build: "1.0 (8)", pid: 200))
        #expect(found.sentinel.pid == 100 && found.sentinel.build == "1.0 (7)" && !found.surfaced)
        #expect(found.reports.map(\.fileName) == ["Racky-2026-10-20-120000.ips"])
        let details = found.details
        #expect(details.contains("Racky quit unexpectedly.") && details.contains("EXC_BAD_ACCESS") && details.contains("SIGSEGV"))
        #expect(!details.contains("/Users/me"), "detalhes redigidos")

        // o aviso aparece uma vez: o boot seguinte (saída limpa antes) não repete, e `markSurfaced` fica gravado
        monitor(d).markSurfaced()
        #expect(monitor(d).lastCrash()?.surfaced == true)
        monitor(d).endCleanly()
        #expect(monitor(d).begin(build: "1.0 (8)", pid: 201) == nil)
        monitor(d).dismiss()
        #expect(monitor(d).lastCrash() == nil)
    }

    @Test func aliveOtherProcessIsNotACrash() throws {
        let d = try dirs(); defer { d.cleanup() }
        _ = monitor(d).begin(build: "1", pid: 100)
        #expect(monitor(d, alive: [100]).begin(build: "1", pid: 200) == nil)
    }

    @Test func oldReportsAreIgnored() throws {
        let d = try dirs(); defer { d.cleanup() }
        let old = d.reports.appendingPathComponent("rackyd-old.ips")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: old.path)
        _ = monitor(d).begin(build: "1", pid: 100)
        let found = try #require(monitor(d).begin(build: "1", pid: 200))
        #expect(found.reports.isEmpty && found.details.contains("No system crash report was found."))
    }

    @Test func realProcessIsAliveProbe() {
        #expect(CrashMonitor.processIsAlive(getpid()))
        #expect(!CrashMonitor.processIsAlive(0))
    }
}
