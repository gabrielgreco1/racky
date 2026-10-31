import Foundation
import Testing

@testable import RackyDocker

/// Tar de teste com controle total do cabeçalho (tipo, link, nome longo, pax), para os casos hostis.
enum RawTar {
    struct Entry {
        var name: String
        var type: Character = "0"
        var data = Data()
        var link = ""
        var mode = 0o644
    }

    static func block(_ entry: Entry, size: Int? = nil) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ offset: Int, _ length: Int) { for (i, b) in text.utf8.prefix(length).enumerated() { block[offset + i] = b } }
        func octal(_ value: Int, _ length: Int) -> String {
            let digits = String(value, radix: 8)
            return String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        }
        put(entry.name, 0, 100)
        put(octal(entry.mode, 8), 100, 7)
        put(octal(0, 8), 108, 7)
        put(octal(0, 8), 116, 7)
        put(octal(size ?? entry.data.count, 12), 124, 11)
        put(octal(1_700_000_000, 12), 136, 11)
        for i in 148 ..< 156 { block[i] = 0x20 }
        block[156] = entry.type.asciiValue!
        put(entry.link, 157, 100)
        put("ustar", 257, 5)
        put("00", 263, 2)
        put(octal(block.reduce(0) { $0 + Int($1) }, 7), 148, 6)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }

    static func make(_ entries: [Entry]) -> Data {
        var out = Data()
        for entry in entries {
            out.append(block(entry))
            out.append(entry.data)
            let pad = (512 - entry.data.count % 512) % 512
            if pad > 0 { out.append(Data(count: pad)) }
        }
        out.append(Data(count: 1024))
        return out
    }

    /// Registro pax `"<len> path=<valor>\n"` com o tamanho que inclui o próprio número.
    static func paxPath(_ path: String) -> Data {
        let body = " path=\(path)\n"
        var length = body.utf8.count + 1
        while String(length).utf8.count + body.utf8.count != length { length = String(length).utf8.count + body.utf8.count }
        return Data("\(length)\(body)".utf8)
    }
}

@Suite("BK-12 - extração segura de tar vindo do host remoto")
struct TarExtractorTests {
    private func temp() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("tx-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func extract(_ tar: Data, into dir: URL, chunk: Int? = nil, maxBytes: Int64 = 1 << 30) throws -> TarExtractionReport {
        var extractor = TarExtractor(destination: dir, maxBytes: maxBytes)
        if let chunk {
            for start in stride(from: 0, to: tar.count, by: chunk) { try extractor.feed(tar[start ..< min(start + chunk, tar.count)]) }
        } else {
            try extractor.feed(tar)
        }
        return try extractor.finish()
    }

    @Test func extractsFilesAndDirectoriesFromDockerStyleArchive() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = RawTar.make([
            .init(name: "./", type: "5", mode: 0o755),
            .init(name: "./a.txt", data: Data("alpha".utf8)),
            .init(name: "./sub/", type: "5", mode: 0o755),
            .init(name: "./sub/b.bin", data: Data(repeating: 7, count: 1500), mode: 0o755),
            .init(name: "empty", data: Data()),
        ])
        let report = try extract(tar, into: dir)
        #expect(report.files == 3 && report.directories >= 1 && report.skipped.isEmpty && report.bytes == 1505)
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "alpha")
        #expect(try Data(contentsOf: dir.appendingPathComponent("sub/b.bin")).count == 1500)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("empty").path))
    }

    @Test func feedingOneByteAtATimeGivesTheSameResult() throws {
        let tar = RawTar.make([.init(name: "x/y.txt", data: Data("1234567890".utf8)), .init(name: "z", data: Data(repeating: 9, count: 600))])
        let whole = try temp(), bytes = try temp()
        defer { try? FileManager.default.removeItem(at: whole); try? FileManager.default.removeItem(at: bytes) }
        _ = try extract(tar, into: whole)
        _ = try extract(tar, into: bytes, chunk: 1)
        #expect(try Data(contentsOf: whole.appendingPathComponent("z")) == Data(contentsOf: bytes.appendingPathComponent("z")))
        #expect(try String(contentsOf: bytes.appendingPathComponent("x/y.txt"), encoding: .utf8) == "1234567890")
    }

    @Test func neverWritesOutsideTheDestination() throws {
        let parent = try temp()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tar = RawTar.make([
            .init(name: "../escaped.txt", data: Data("x".utf8)),
            .init(name: "a/../../escaped2.txt", data: Data("x".utf8)),
            .init(name: "/abs/inside.txt", data: Data("ok".utf8)),
            .init(name: "link-out", type: "2", link: "../../etc"),
            .init(name: "link-abs", type: "2", link: "/etc/passwd"),
            .init(name: "link-in", type: "2", link: "abs/inside.txt"),
            .init(name: "hard", type: "1", link: "abs/inside.txt"),
            .init(name: "dev", type: "3"),
            .init(name: "fifo", type: "6"),
        ])
        let report = try extract(tar, into: dir)
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped2.txt").path))
        #expect(try String(contentsOf: dir.appendingPathComponent("abs/inside.txt"), encoding: .utf8) == "ok", "caminho absoluto vira relativo ao destino")
        #expect(report.symlinks == 1 && (try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("link-in").path)) == "abs/inside.txt")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("link-out").path))
        #expect(Set(report.skipped) == ["../escaped.txt", "a/../../escaped2.txt", "link-out", "link-abs", "hard", "dev", "fifo"])
    }

    @Test func fileCannotBeWrittenThroughAnEarlierSymlinkToAnotherDirectory() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // `sub -> inner` é válido (dentro); `sub/f` cai em `inner/f`, também dentro. `esc -> ..` não pode nem ser criado.
        let tar = RawTar.make([
            .init(name: "inner/", type: "5", mode: 0o755), .init(name: "sub", type: "2", link: "inner"),
            .init(name: "esc", type: "2", link: ".."), .init(name: "esc/pwn.txt", data: Data("no".utf8)),
        ])
        let report = try extract(tar, into: dir)
        #expect(report.skipped.contains("esc"))
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("pwn.txt").path))
    }

    @Test func stripsSetuidAndKeepsOwnerAccess() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try extract(RawTar.make([.init(name: "suid", data: Data("x".utf8), mode: 0o4755), .init(name: "locked", data: Data("x".utf8), mode: 0o000)]), into: dir)
        func mode(_ name: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        #expect(mode("suid") == 0o755)
        #expect(mode("locked") & 0o600 == 0o600)
        let mtime = try #require(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("suid").path)[.modificationDate] as? Date)
        #expect(Int(mtime.timeIntervalSince1970) == 1_700_000_000)
    }

    @Test func understandsPaxAndGnuLongNames() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = (0 ..< 12).map { _ in "segmento-bem-longo" }.joined(separator: "/") + "/arquivo.txt"
        #expect(long.utf8.count > 100)
        let pax = RawTar.paxPath(long)
        let gnu = Data((long + "\u{0}").utf8)
        let tar = RawTar.make([
            .init(name: "PaxHeader", type: "x", data: pax), .init(name: "short", data: Data("via-pax".utf8)),
            .init(name: "././@LongLink", type: "L", data: gnu), .init(name: "truncated-name", data: Data("via-gnu".utf8)),
        ])
        let report = try extract(tar, into: dir)
        #expect(report.files == 2)
        #expect(try String(contentsOf: dir.appendingPathComponent(long), encoding: .utf8) == "via-gnu", "o segundo reescreve o mesmo caminho")
    }

    @Test func truncatedTarAndSizeLimitAreErrors() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = RawTar.make([.init(name: "big", data: Data(repeating: 1, count: 4096))])
        #expect(throws: TarExtractionError.self) { _ = try extract(Data(tar.prefix(1000)), into: dir) }
        #expect(throws: TarExtractionError.tooLarge(limit: 1000)) { _ = try extract(tar, into: dir, maxBytes: 1000) }
    }

    @Test func overwritesExistingFilesOnRepeatedPull() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old".utf8).write(to: dir.appendingPathComponent("f"))
        _ = try extract(RawTar.make([.init(name: "f", data: Data("new".utf8))]), into: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8) == "new")
    }

    @Test func writerRoundTripsThroughExtractorWithOwnerAndMode() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = try TarArchive.create(entries: [TarEntry(path: "TOKEN", data: Data("s3cret".utf8), mode: 0o400, uid: 10001, gid: 10001)])
        // uid/gid no cabeçalho (octal nos offsets 108 e 116)
        #expect(String(decoding: tar[108 ..< 115], as: UTF8.self) == "0023421" && tar[156] == UInt8(ascii: "0"))
        _ = try extract(tar, into: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("TOKEN"), encoding: .utf8) == "s3cret")
    }
}
