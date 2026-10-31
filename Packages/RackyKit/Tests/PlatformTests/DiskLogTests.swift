import Foundation
import Testing
@testable import RackyPlatform

@Suite struct DiskLogTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("abdisklog-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writesJSONLRedactedBeforeTouchingDisk() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiskLog(.init(directory: dir, process: "app"))
        log.write(level: .error, subsystem: "app.racky", category: "docker", message: "failed ghp_abcdefghijklmnopqrstuvwxyz0123 in /Users/me/proj")
        log.flush()
        let text = try String(contentsOf: dir.appendingPathComponent("app.jsonl"), encoding: .utf8)
        #expect(!text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123") && !text.contains("/Users/me"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["level"] as? String == "error" && object["category"] as? String == "docker" && object["process"] as? String == "app")
        #expect((object["msg"] as? String)?.contains("~/proj") == true)
    }

    @Test func rotatesAtTheLimitKeepingFiveFiles() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiskLog(.init(directory: dir, process: "ptyd", maxBytes: 600, maxFiles: 5))
        for i in 0 ..< 200 { log.write(level: .info, subsystem: "app.racky.ptyd", category: "session", message: "line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["ptyd.1.jsonl", "ptyd.2.jsonl", "ptyd.3.jsonl", "ptyd.4.jsonl", "ptyd.jsonl"])
        for url in log.files {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size <= 600 + 200, "\(url.lastPathComponent) passou do limite: \(size)")
        }
        // o mais novo está no arquivo ativo
        let active = try String(contentsOf: dir.appendingPathComponent("ptyd.jsonl"), encoding: .utf8)
        #expect(active.contains("line 199"))
    }

    @Test func facadeWritesThroughTheInstalledLog() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiskLog(.init(directory: dir, process: "app"))
        DiskLog.install(log)
        defer { DiskLog.install(nil) }
        LogFacade(.app, category: "launch").error("boom Bearer abcdef0123456789")
        log.flush()
        let text = try String(contentsOf: dir.appendingPathComponent("app.jsonl"), encoding: .utf8)
        #expect(text.contains("boom") && !text.contains("abcdef0123456789") && text.contains("\"category\":\"launch\""))
    }
}
