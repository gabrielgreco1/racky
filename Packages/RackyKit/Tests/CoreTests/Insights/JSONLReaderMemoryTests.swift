import Darwin
import Foundation
import Testing
@testable import RackyCore

/// (Integração: a pegada é do processo todo, então roda sozinha em série.)
/// T2-11: a varredura dos transcripts (GBs no Mac do dono) não pode acumular objetos autoreleased até o fim da `Task`.
/// Sem o pool por bloco em `JSONLReader`, ler 80 MB de JSON deixava centenas de MB de pegada; com ele, o crescimento é limitado.
@Suite(.tags(.integration)) struct JSONLReaderMemoryTests {
    private func footprint() -> UInt64 {
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return info.ri_phys_footprint
    }

    @Test func readingLargeFilesDoesNotGrowTheFootprintUnbounded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abjsonl-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = #"{"type":"assistant","sessionId":"abc","timestamp":"2026-10-20T10:00:00.000Z","message":{"id":"m","model":"claude","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300},"content":[{"type":"text","text":"\#(String(repeating: "x", count: 180))"}]}}"# + "\n"
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data(String(repeating: line, count: 4000).utf8)
        for _ in 0 ..< 80 { try handle.write(contentsOf: block) }  // ~80 MB
        try handle.close()

        let before = footprint()
        var lines = 0
        let cursor = JSONLReader.readLines(path: url.path, cursor: nil, chunkBytes: 1 << 20) { raw in
            if JSONLReader.object(raw) != nil { lines += 1 }
        }
        let growthMiB = Double(Int64(footprint()) - Int64(before)) / 1_048_576
        #expect(lines == 320_000 && cursor?.offset == cursor?.size)
        #expect(growthMiB < 80, "pegada cresceu \(Int(growthMiB)) MiB lendo 80 MB de JSONL")
    }
}
