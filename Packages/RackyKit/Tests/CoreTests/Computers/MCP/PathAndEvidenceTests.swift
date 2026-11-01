import RackyDocker
import Darwin
import Foundation
import Testing

@testable import RackyCore

@Suite struct PathGuardTests {
    func withRoot(_ body: (URL, URL) throws -> Void) throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let outside = temp.root.appendingPathComponent("outside", isDirectory: true)
        let work = temp.root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("TOP-SECRET".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try body(work, outside)
    }

    @Test func normalizesInsideTheRoot() throws {
        #expect(try PathGuard.components("a/b") == ["a", "b"])
        #expect(try PathGuard.components("/work/a/b") == ["a", "b"])
        #expect(try PathGuard.components("./a/../a/b/./c") == ["a", "b", "c"])
        #expect(try PathGuard.components("/work") == [])
        #expect(try PathGuard.boxPath("x/y") == "/work/x/y")
        #expect(try PathGuard.boxPath("/work") == "/work")
    }

    @Test func rejectsEscapesAbsolutePathsAndNul() {
        for bad in ["../x", "a/../../x", "/etc/passwd", "/work/../etc", "/workshop/x", "/", "", "a\0b", "../../../../.ssh/id_rsa"] {
            #expect(throws: ToolError.self, "\(bad.debugDescription)") { _ = try PathGuard.components(bad) }
            do { _ = try PathGuard.components(bad) } catch let error as ToolError { #expect(error.code == .pathRejected, "\(bad.debugDescription) -> \(error.code)") } catch {}
        }
    }

    @Test func symlinkToAFileOutsideIsRejectedAndNeverRead() throws {
        try withRoot { work, outside in
            try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("a"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
            // CA-207: `ln -s /etc/passwd /work/a` e `ln -s ../../../../.ssh/id_rsa /work/b`
            try FileManager.default.createSymbolicLink(atPath: work.appendingPathComponent("b").path, withDestinationPath: "../../../../.ssh/id_rsa")
            for name in ["a", "b", "/work/a"] {
                do { _ = try PathGuard.read(root: work, name); Issue.record("read followed a symlink: \(name)") } catch let error as ToolError {
                    #expect(error.code == .pathRejected, "\(name)")
                }
            }
            #expect(!PathGuard.exists(root: work, "a"))
            #expect(throws: ToolError.self) { try PathGuard.rejectSymlinks(root: work, ["a"]) }
        }
    }

    @Test func symlinkedDirectoryIsRejectedForReadAndWrite() throws {
        try withRoot { work, outside in
            try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: outside)
            do { _ = try PathGuard.read(root: work, "link/secret.txt"); Issue.record("read through a symlinked directory") } catch let error as ToolError {
                #expect(error.code == .pathRejected)
            }
            do { try PathGuard.write(root: work, "link/pwn.txt", Data("x".utf8)); Issue.record("write through a symlinked directory") } catch let error as ToolError {
                #expect(error.code == .pathRejected)
            }
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwn.txt").path))
        }
    }

    @Test func writeThroughAFileSymlinkDoesNotTouchTheTarget() throws {
        try withRoot { work, outside in
            let target = outside.appendingPathComponent("secret.txt")
            try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("shot.png"), withDestinationURL: target)
            do { try PathGuard.write(root: work, "shot.png", Data("OVERWRITTEN".utf8)); Issue.record("write followed a symlink") } catch let error as ToolError {
                #expect(error.code == .pathRejected)
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "TOP-SECRET")
        }
    }

    @Test func readsAndWritesRegularFilesCreatingFolders() throws {
        try withRoot { work, _ in
            let written = try PathGuard.write(root: work, "/work/shots/deep/a.png", Data("PNG".utf8))
            #expect(written == "/work/shots/deep/a.png")
            #expect(try PathGuard.read(root: work, "shots/deep/a.png") == Data("PNG".utf8))
            #expect(try PathGuard.read(root: work, "/work/shots/./deep/../deep/a.png") == Data("PNG".utf8))
            #expect(PathGuard.exists(root: work, "shots/deep/a.png"))
            #expect(!PathGuard.exists(root: work, "nope"))
            #expect(throws: ToolError.self) { _ = try PathGuard.read(root: work, "shots") }  // diretório não é arquivo
            do { _ = try PathGuard.read(root: work, "missing.txt") } catch let error as ToolError { #expect(error.code == .notFound) }
            #expect(throws: ToolError.self) { _ = try PathGuard.read(root: work, "shots/deep/a.png", maxBytes: 1) }
        }
    }

    @Test func rootThatIsItselfBehindASymlinkStillWorks() throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let real = temp.root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = temp.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try PathGuard.write(root: link, "a.txt", Data("ok".utf8))
        #expect(try PathGuard.read(root: link, "a.txt") == Data("ok".utf8))
    }
}

@Suite struct ResultValidatorTests {
    let a = "01ARZ3NDEKTSV4RRFFQ69G5FAV", b = "01BX5ZZKBKACTAV9WEVGEMMVRZ"

    func validator(requests: [String: String] = [:], files: Set<String> = []) -> ResultValidator {
        ResultValidator(requests: requests) { files.contains($0) }
    }

    @Test func threeFieldsGetThreeStatuses() throws {
        // CA-203: um cita request real, um id inventado, um sem citação
        let result: JSON = ["price": 10, "owner": "ACME", "count": 3]
        let evidence = ["/price": [a], "/owner": [b]]
        let out = try validator(requests: [a: "observed"]).validate(result: result, evidence: evidence)
        let by = Dictionary(uniqueKeysWithValues: out.fields.map { ($0.pointer, $0) })
        #expect(by["/price"]?.status == .verified)
        #expect(by["/owner"]?.status == .citedMissing)
        #expect(by["/count"]?.status == .notVerified)
        #expect((out.verified, out.citedMissing, out.notVerified) == (1, 1, 1))
        #expect(by["/price"]?.citations.first?.trust == "observed")
        #expect(by["/price"]?.citations.first?.kind == .request)
        #expect(out.json["summary"]?["cited_missing"] == 1)
    }

    @Test func fileCitationsAndReportedTrust() throws {
        let out = try validator(requests: [a: "reported"], files: ["/work/data.csv"]).validate(
            result: ["rows": 2, "src": "x"], evidence: ["/rows": ["/work/data.csv"], "/src": [a, "/work/gone.csv"]])
        let by = Dictionary(uniqueKeysWithValues: out.fields.map { ($0.pointer, $0) })
        #expect(by["/rows"]?.status == .verified)
        #expect(by["/rows"]?.citations.first?.kind == .file)
        #expect(by["/src"]?.status == .citedMissing)  // uma das duas some: nada de "meio verificado"
        #expect(by["/src"]?.citations.first { $0.kind == .request }?.trust == "reported")
    }

    @Test func aPointerCoversItsDescendantsAndDeepPointersAreListed() throws {
        let result: JSON = ["items": [["id": 1, "price": 5], ["id": 2, "price": 6]], "total": 11]
        let out = try validator(requests: [a: "observed"]).validate(result: result, evidence: ["/items/0/price": [a], "/total": [a]])
        let by = Dictionary(uniqueKeysWithValues: out.fields.map { ($0.pointer, $0.status) })
        #expect(by["/items"] == .notVerified)  // só o filho citou
        #expect(by["/items/0/price"] == .verified)
        #expect(by["/total"] == .verified)
        let inherited = try validator(requests: [a: "observed"]).validate(result: result, evidence: ["/items": [a]])
        #expect(inherited.fields.first { $0.pointer == "/items" }?.status == .verified)
    }

    @Test func invalidPointersAreUsageErrors() throws {
        #expect(throws: ToolError.self) { _ = try validator().validate(result: ["a": 1], evidence: ["/nope": [a]]) }
        #expect(throws: ToolError.self) { _ = try validator().validate(result: ["a": 1], evidence: ["a": [a]]) }
        #expect(throws: ToolError.self) { _ = try validator().validate(result: [1, 2], evidence: [:]) }
        let escaped = try validator(requests: [a: "observed"]).validate(result: ["a/b": 1, "c~d": 2], evidence: ["/a~1b": [a]])
        #expect(escaped.fields.first { $0.pointer == "/a~1b" }?.status == .verified)
    }

    @Test func handwrittenResultFindsIdsByPattern() throws {
        // `box_collect` roda o validador sobre um result.json escrito à mão (audit/08 N8)
        let json = #"{"price": "10 (see request \#(a))", "ghost": ["\#(b)"], "plain": "nothing here", "lower": "01arz3ndektsv4rrffq69g5fav"}"#
        let out = try validator(requests: [a: "observed"]).validateHandwritten(resultData: Data(json.utf8))
        let by = Dictionary(uniqueKeysWithValues: out.fields.map { ($0.pointer, $0.status) })
        #expect(by["/price"] == .verified)
        #expect(by["/ghost"] == .citedMissing)
        #expect(by["/plain"] == .notVerified)
        #expect(by["/lower"] == .notVerified)
        #expect(throws: ToolError.self) { _ = try validator().validateHandwritten(resultData: Data("not json".utf8)) }
    }

    @Test func requestIDShape() {
        #expect(ResultValidator.looksLikeRequestID(a))
        #expect(!ResultValidator.looksLikeRequestID("short"))
        #expect(!ResultValidator.looksLikeRequestID(a + "X"))
        #expect(!ResultValidator.looksLikeRequestID("/work/data.csv"))
        #expect(ULID.generate().count == 26 && ResultValidator.looksLikeRequestID(ULID.generate()))
        #expect(ULID.generate(nowMs: 1) < ULID.generate(nowMs: 2_000_000_000_000))
    }

    @Test func indexReadsIdAndTrustFromTheRequestLog() throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let file = temp.root.appendingPathComponent("requests.jsonl")
        try (JSON.object(["id": .string(a), "trust": "observed"]).text + "\n" + JSON.object(["id": .string(b), "trust": "reported"]).text + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(ResultValidator.index(requestsFile: file) == [a: "observed", b: "reported"])
    }
}

@Suite struct ChainedLogTests {
    @Test func appendChainsAndVerifiesLikeTheEgressLog() async throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let log = ChainedLog(file: temp.root.appendingPathComponent("journal.jsonl"))
        for i in 1...5 { try await log.append(["kind": "NOTE", "text": .string("line \(i)")]) }
        #expect(await log.lineCount == 5)
        #expect(try ReqlogIntegrity.verify(file: log.file) == .ok(lines: 5))
        #expect(await log.integrity() == .ok(lines: 5))
        let entries = await log.entries()
        #expect(entries.map { $0["n"]?.int } == [1, 2, 3, 4, 5])
        #expect(entries[0]["prev_sha256"]?.string == ReqlogIntegrity.genesis)
        #expect(entries[0]["ts"]?.double != nil)
    }

    @Test func reopeningContinuesTheChain() async throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let file = temp.root.appendingPathComponent("commands.jsonl")
        let first = ChainedLog(file: file)
        try await first.append(["x": 1])
        try await first.append(["x": 2])
        let second = ChainedLog(file: file)
        try await second.append(["x": 3])
        #expect(try ReqlogIntegrity.verify(file: file) == .ok(lines: 3))
        #expect(await second.lineCount == 3)
    }

    @Test func tamperingIsDetectedWithTheLineNumber() async throws {
        let temp = try TempRun()
        defer { temp.remove() }
        let log = ChainedLog(file: temp.root.appendingPathComponent("journal.jsonl"))
        for i in 1...4 { try await log.append(["text": .string("entry \(i)")]) }
        var text = try String(contentsOf: log.file, encoding: .utf8)
        text = text.replacingOccurrences(of: "entry 2", with: "entry X")  // o agente (ou alguém) reescreve a linha 2
        try text.write(to: log.file, atomically: true, encoding: .utf8)
        #expect(try ReqlogIntegrity.verify(file: log.file) == .tampered(line: 3))
        #expect(ReqlogIntegrity.tampered(line: 3).message == "Tampered at line 3")
    }
}
