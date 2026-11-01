import Foundation
import Testing

@testable import RackyDocker

@Suite struct HTTPCodecTests {
    @Test func headParserSplitsHeadAndRestAcrossFeeds() throws {
        var parser = HTTPHeadParser()
        #expect(try parser.feed(Data("HTTP/1.1 200 OK\r\nContent-Ty".utf8)) == nil)
        let result = try #require(try parser.feed(Data("pe: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)))
        #expect(result.head.status == 200)
        #expect(result.head.contentType == "application/json")
        #expect(result.head.contentLength == 2)
        #expect(result.rest == Data("{}".utf8))
    }

    @Test func headParserRejectsGarbageStatusLine() {
        var parser = HTTPHeadParser()
        #expect(throws: DockerError.self) { try parser.feed(Data("NOPE\r\n\r\n".utf8)) }
    }

    @Test func upgradeStatusIsParsed() throws {
        var parser = HTTPHeadParser()
        let result = try #require(try parser.feed(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nXYZ".utf8)))
        #expect(result.head.status == 101)
        #expect(result.rest == Data("XYZ".utf8))
    }

    @Test func requestHeadEscapesQueryAndAddsUpgradeOrClose() {
        let request = HTTPRequest(method: "GET", path: "/v1.43/events", query: [
            .init(name: "filters", value: #"{"label":["a=b c","x&y"]}"#), .init(name: "since", value: "10"),
        ])
        let head = String(decoding: request.head(bodyLength: nil, upgrade: false), as: UTF8.self)
        #expect(head.hasPrefix("GET /v1.43/events?filters=%7B%22label%22%3A%5B%22a%3Db%20c%22%2C%22x%26y%22%5D%7D&since=10 HTTP/1.1\r\n"))
        #expect(head.contains("Host: docker\r\n"))
        #expect(head.contains("Connection: close\r\n"))
        let up = String(decoding: HTTPRequest(method: "POST", path: "/exec/1/start").head(bodyLength: 2, upgrade: true), as: UTF8.self)
        #expect(up.contains("Connection: Upgrade\r\n") && up.contains("Upgrade: tcp\r\n") && up.contains("Content-Length: 2\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    @Test func chunkedDecoderHandlesSplitsAndHexSizes() throws {
        let wire = "5\r\nhello\r\nA;ext=1\r\n0123456789\r\n0\r\n\r\n"
        let bytes = Array(wire.utf8)
        // Alimenta byte a byte: o pior fatiamento possível.
        var decoder = ChunkedDecoder()
        var out = Data()
        for byte in bytes { out.append(try decoder.feed(Data([byte]))) }
        #expect(String(decoding: out, as: UTF8.self) == "hello0123456789")
        #expect(decoder.isFinished)
    }

    @Test func chunkedDecoderRejectsBadSize() {
        var decoder = ChunkedDecoder()
        #expect(throws: DockerError.self) { try decoder.feed(Data("zz\r\n".utf8)) }
    }

    @Test func lineSplitterKeepsPartialLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        let rest = splitter.feed(Data(":2}\n\n".utf8))
        #expect(rest.count == 1 && String(decoding: rest[0], as: UTF8.self) == "{\"b\":2}")
        #expect(splitter.flush() == nil)
    }

    @Test func demuxerSplitsStdoutAndStderrAcrossReads() throws {
        let wire = Reply.mux(1, "out-1\n") + Reply.mux(2, "err-1\n") + Reply.mux(1, "out-2\n")
        var demuxer = MultiplexDemuxer()
        var frames: [DockerStreamFrame] = []
        for slice in stride(from: 0, to: wire.count, by: 3).map({ Data(wire[$0 ..< min($0 + 3, wire.count)]) }) {
            frames += try demuxer.feed(slice)
        }
        #expect(frames.map(\.kind) == [.stdout, .stderr, .stdout])
        #expect(frames.map { String(decoding: $0.data, as: UTF8.self) } == ["out-1\n", "err-1\n", "out-2\n"])
        #expect(!demuxer.hasPartialFrame)
    }

    @Test func demuxerRejectsInvalidHeader() {
        var demuxer = MultiplexDemuxer()
        #expect(throws: DockerError.self) { try demuxer.feed(Data([9, 0, 0, 0, 0, 0, 0, 1, 0x41])) }
    }

    @Test func demuxerHandlesZeroLengthFrame() throws {
        var demuxer = MultiplexDemuxer()
        let frames = try demuxer.feed(Reply.mux(1, ""))
        #expect(frames.count == 1 && frames[0].data.isEmpty)
    }
}

@Suite struct ErrorMappingTests {
    @Test func realErrorBodiesMapToTypedErrors() throws {
        let notFound = DockerError.from(status: 404, body: try Fixtures.data("error-404.json"), context: "container inspect")
        #expect(notFound == .notFound("container inspect: No such container: nao-existe"))
        let conflict = DockerError.from(status: 409, body: try Fixtures.data("error-409.json"), context: "container create")
        #expect(conflict.isConflict)
        #expect(DockerError.from(status: 500, body: Data("boom".utf8), context: "x") == .api(status: 500, message: "x: boom"))
    }

    @Test func runtimeUnavailableMapsToReserveReason() {
        #expect(DockerError.runtimeUnavailable("x").reserveReason == "docker_unavailable")
        #expect(DockerError.timeout(operation: "x").reserveReason == nil)
        #expect(DockerError.timeout(operation: "x").isInterruption && DockerError.cancelled.isInterruption)
    }
}
