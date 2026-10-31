import Foundation
import Testing

@testable import RackyProtocol

@Suite struct HandshakeTests {
    private func server(
        version: ProtocolVersion = .current, capabilities: [Capability] = Capability.initialSet
    ) -> ServerHandshake {
        ServerHandshake(version: version, capabilities: capabilities, daemon: daemonInfo)
    }

    private func hello(
        id: RequestID = 1, version: ProtocolVersion = .current, capabilities: [Capability] = Capability.initialSet
    ) -> ControlMessage {
        .request(DaemonRequest(id: id, command: .hello(HelloRequest(protocolVersion: version, client: clientInfo(), capabilities: capabilities))))
    }

    private func established(_ outcome: ServerHandshake.Outcome) -> (DaemonReply, NegotiatedSession)? {
        if case .established(let reply, let session) = outcome { return (reply, session) }
        return nil
    }

    private func rejection(_ outcome: ServerHandshake.Outcome) -> DaemonError? {
        if case .rejected(.error(_, let error)) = outcome { return error }
        return nil
    }

    // MARK: Servidor

    @Test func sameVersionNegotiatesFullCapabilities() throws {
        var handshake = server()
        let (reply, session) = try #require(established(handshake.receive(hello(), sessions: 7)))
        #expect(session.version == .current)
        #expect(session.capabilities == Capability.initialSet)
        guard case .helloAck(let id, let ack) = reply else {
            Issue.record("expected helloAck")
            return
        }
        #expect(id == 1 && ack.sessions == 7 && ack.protocolVersion == .current && ack.daemon == daemonInfo)
        #expect(handshake.state == .established(session))
    }

    @Test func majorMismatchIsRejectedWithErrorCode() throws {
        var handshake = server()
        let outcome = handshake.receive(hello(version: ProtocolVersion(major: 2, minor: 0)), sessions: 0)
        let error = try #require(rejection(outcome))
        #expect(error.code == .protocolMajorMismatch)
        if case .rejected(let reply) = outcome { #expect(reply.id == 1) }
        #expect(handshake.state == .failed(error))
    }

    @Test func olderMajorFromClientIsRejectedToo() throws {
        var handshake = server(version: ProtocolVersion(major: 2, minor: 0))
        let error = try #require(rejection(handshake.receive(hello(version: ProtocolVersion(major: 1, minor: 5)), sessions: 0)))
        #expect(error.code == .protocolMajorMismatch)
    }

    @Test func capabilitiesAreTheIntersectionAndMinorIsTheMinimum() throws {
        // Daemon N-1 (minor 0, sem drainWhenIdle) × app com minor 2.
        var oldDaemon = server(version: ProtocolVersion(major: 1, minor: 0), capabilities: [.coldLog, .osc133, .textSnapshot, .inputOrigin])
        let (_, session) = try #require(established(oldDaemon.receive(
            hello(version: ProtocolVersion(major: 1, minor: 2), capabilities: Capability.initialSet + ["newerThing"]), sessions: 0)))
        #expect(session.version == ProtocolVersion(major: 1, minor: 0))
        #expect(session.capabilities == [.coldLog, .osc133, .textSnapshot, .inputOrigin])
        #expect(!session.supports(.drainWhenIdle))
        #expect(!session.supports("newerThing"))

        // Daemon minor 2 × app minor 0 com poucas capabilities.
        var newDaemon = server(version: ProtocolVersion(major: 1, minor: 2), capabilities: Capability.initialSet + ["extra"])
        let (reply, narrow) = try #require(established(newDaemon.receive(hello(version: ProtocolVersion(major: 1, minor: 0), capabilities: [.coldLog]), sessions: 1)))
        #expect(narrow.version == ProtocolVersion(major: 1, minor: 0))
        #expect(narrow.capabilities == [.coldLog])
        if case .helloAck(_, let ack) = reply {
            #expect(ack.protocolVersion == ProtocolVersion(major: 1, minor: 2))  // o daemon anuncia a própria versão
            #expect(ack.capabilities == [.coldLog])
        }
    }

    @Test func noCommonCapabilitiesStillEstablishes() throws {
        var handshake = server()
        let (_, session) = try #require(established(handshake.receive(hello(capabilities: []), sessions: 0)))
        #expect(session.capabilities.isEmpty)
    }

    @Test func firstMessageMustBeHello() throws {
        let nonHello: [ControlMessage] = [
            .request(DaemonRequest(id: 4, command: .ping)),
            .request(DaemonRequest(id: 5, command: .list)),
            .reply(.ok(id: 1, .empty)),
            .event(DaemonEvent(sessionID: sid1, payload: .bell)),
        ]
        for message in nonHello {
            var handshake = server()
            let error = try #require(rejection(handshake.receive(message, sessions: 0)))
            #expect(error.code == .badRequest)
            #expect(handshake.state == .failed(error))
        }
    }

    @Test func secondHelloAfterEstablishedIsRejected() throws {
        var handshake = server()
        _ = try #require(established(handshake.receive(hello(), sessions: 0)))
        let error = try #require(rejection(handshake.receive(hello(id: 2), sessions: 0)))
        #expect(error.code == .badRequest)
    }

    @Test func timeoutFailsTheHandshake() {
        var handshake = server()
        guard case .error(let id, let error) = handshake.timedOut() else {
            Issue.record("expected error")
            return
        }
        #expect(id == nil && error.code == .badRequest && error.message.contains("timeout"))
        #expect(handshake.state == .failed(error))
    }

    // MARK: Cliente

    private func client(
        version: ProtocolVersion = .current, accepted: [UInt16]? = nil, minimum: ProtocolVersion? = nil,
        capabilities: [Capability] = Capability.initialSet
    ) -> ClientHandshake {
        ClientHandshake(version: version, capabilities: capabilities, client: clientInfo(), acceptedMajors: accepted, minimumDaemonVersion: minimum)
    }

    private func ack(
        id: RequestID = 1, version: ProtocolVersion = .current, capabilities: [Capability] = Capability.initialSet
    ) -> ControlMessage {
        .reply(.helloAck(id: id, HelloAck(protocolVersion: version, daemon: daemonInfo, capabilities: capabilities, sessions: 3)))
    }

    @Test func clientAcceptsMatchingAck() throws {
        var handshake = client()
        let request = handshake.makeHello(id: 1)
        #expect(request.command.op == "hello")
        let result = try handshake.receive(ack())
        #expect(result.session.version == .current && result.sessions == 3 && !result.isCompatibilityMode)
        #expect(result.session.capabilities == Capability.initialSet)
    }

    @Test func clientIntersectsAckCapabilitiesWithItsOwn() throws {
        var handshake = client(capabilities: [.coldLog, .textSnapshot, "clientOnly"])
        _ = handshake.makeHello(id: 1)
        let result = try handshake.receive(ack(version: ProtocolVersion(major: 1, minor: 4), capabilities: [.textSnapshot, .coldLog, "daemonOnly"]))
        #expect(result.session.capabilities == [.coldLog, .textSnapshot])
        #expect(result.session.version == ProtocolVersion(major: 1, minor: 0))
    }

    @Test func clientRejectsDaemonOfAnotherMajor() throws {
        var handshake = client()
        _ = handshake.makeHello(id: 1)
        #expect(throws: HandshakeError.majorMismatch(local: [1], remote: 2)) {
            try handshake.receive(ack(version: ProtocolVersion(major: 2, minor: 0)))
        }
    }

    @Test func clientSurfacesDaemonErrorReply() throws {
        var handshake = client()
        _ = handshake.makeHello(id: 1)
        let error = DaemonError(.protocolMajorMismatch, "client protocol major 1, daemon major 2")
        #expect(throws: HandshakeError.rejectedByDaemon(error)) { try handshake.receive(.reply(.error(id: 1, error))) }
    }

    @Test func clientValidatesReplyIDAndKind() throws {
        var wrongID = client()
        _ = wrongID.makeHello(id: 5)
        #expect(throws: HandshakeError.idMismatch(expected: 5, got: 6)) { try wrongID.receive(ack(id: 6)) }

        var wrongKind = client()
        _ = wrongKind.makeHello(id: 1)
        #expect(throws: HandshakeError.unexpectedReply) { try wrongKind.receive(.reply(.ok(id: 1, .empty))) }

        var event = client()
        _ = event.makeHello(id: 1)
        #expect(throws: HandshakeError.unexpectedReply) { try event.receive(.event(DaemonEvent(sessionID: sid1, payload: .bell))) }

        var neverSentHello = client()
        #expect(throws: HandshakeError.unexpectedReply) { try neverSentHello.receive(ack()) }
    }

    @Test func clientFlagsDaemonOlderThanMinimum() throws {
        var handshake = client(minimum: ProtocolVersion(major: 1, minor: 2))
        _ = handshake.makeHello(id: 1)
        #expect(throws: HandshakeError.daemonTooOld(minimum: ProtocolVersion(major: 1, minor: 2), actual: ProtocolVersion(major: 1, minor: 1))) {
            try handshake.receive(ack(version: ProtocolVersion(major: 1, minor: 1)))
        }
        var fine = client(minimum: ProtocolVersion(major: 1, minor: 2))
        _ = fine.makeHello(id: 1)
        #expect(try fine.receive(ack(version: ProtocolVersion(major: 1, minor: 2))).session.version.major == 1)
    }

    // MARK: N × N-1 (AR-904)

    /// Simula a próxima major: "N" = major 2 (a daemon N fala só major 2); "N-1" = major 1.
    private let nVersion = ProtocolVersion(major: 2, minor: 0)
    private let nMinus1 = ProtocolVersion(major: 1, minor: 2)

    @Test func appNConnectsToDaemonNMinus1WithCompatibilityClient() throws {
        // O app N mantém um cliente de compatibilidade: anuncia major 1 no socket antigo.
        var legacyDaemon = server(version: nMinus1)
        var compat = ClientHandshake(
            version: ProtocolVersion(major: 1, minor: 0), capabilities: Capability.initialSet, client: clientInfo(),
            acceptedMajors: [1, 2])
        let request = compat.makeHello(id: 1)
        let (reply, session) = try #require(established(legacyDaemon.receive(.request(request), sessions: 3)))
        var evaluated = compat
        let result = try evaluated.receive(.reply(reply))
        #expect(session.version == ProtocolVersion(major: 1, minor: 0))
        #expect(result.sessions == 3)
        // Operações do subconjunto de compatibilidade passam no gate de capabilities.
        for command in [DaemonCommand.list, .detach(SessionTarget(sessionID: sid1)), .resize(ResizeRequest(sessionID: sid1, cols: 80, rows: 24)),
                        .kill(KillRequest(sessionID: sid1, mode: .graceful)), .attach(AttachRequest(sessionID: sid1, cols: 80, rows: 24, mode: .snapshot)),
                        .signal(SignalRequest(sessionID: sid1, signal: 2, target: .group))] {
            try session.validate(command)
        }
    }

    @Test func compatibilityResultIsFlaggedWhenDaemonMajorDiffersFromCurrent() throws {
        // `ProtocolVersion.current` é major 1: um ack de major 0 (hipotético N-1 de um build futuro) é modo de compatibilidade.
        var handshake = client(version: ProtocolVersion(major: 0, minor: 9), accepted: [0, 1])
        _ = handshake.makeHello(id: 1)
        let result = try handshake.receive(ack(version: ProtocolVersion(major: 0, minor: 9)))
        #expect(result.isCompatibilityMode)
    }

    @Test func daemonNRejectsClientNMinus1AndClientNRejectsDaemonNMinus1WithoutCompat() throws {
        var daemonN = server(version: nVersion)
        let error = try #require(rejection(daemonN.receive(hello(version: ProtocolVersion(major: 1, minor: 2)), sessions: 0)))
        #expect(error.code == .protocolMajorMismatch)

        var clientN = client(version: nVersion)
        _ = clientN.makeHello(id: 1)
        #expect(throws: HandshakeError.majorMismatch(local: [2], remote: 1)) { try clientN.receive(ack(version: nMinus1)) }
    }

    @Test func nMinus1FixturesNegotiateAgainstCurrentBuild() throws {
        // hello 1.0 mínimo contra o daemon atual.
        guard case .request(let oldHello) = try ControlCodec.decode(Fixtures.data("n-1", "hello-1.0-minimal")) else {
            Issue.record("expected request")
            return
        }
        var handshake = server(version: ProtocolVersion(major: 1, minor: 3))
        let (_, session) = try #require(established(handshake.receive(.request(oldHello), sessions: 0)))
        #expect(session.version == ProtocolVersion(major: 1, minor: 0))
        #expect(session.capabilities == [.coldLog])

        // helloAck 1.0 (sem drainWhenIdle) contra o cliente atual.
        var client = client(version: ProtocolVersion(major: 1, minor: 3))
        _ = client.makeHello(id: 1)
        guard case .reply = try ControlCodec.decode(Fixtures.data("n-1", "hello-ack-1.0-minimal")) else {
            Issue.record("expected reply")
            return
        }
        let result = try client.receive(ControlCodec.decode(Fixtures.data("n-1", "hello-ack-1.0-minimal")))
        #expect(result.session.version == ProtocolVersion(major: 1, minor: 0))
        #expect(!result.session.supports(.drainWhenIdle))
        #expect(result.session.supports(.textSnapshot))

        // helloAck 1.7 do futuro, com capability e campos desconhecidos.
        var older = self.client(version: .current)
        _ = older.makeHello(id: 1)
        let future = try older.receive(ControlCodec.decode(Fixtures.data("n-1", "hello-ack-1.7-future")))
        #expect(future.session.version == .current)
        #expect(!future.session.supports("futureThing"))  // desconhecida do cliente: fora da interseção
    }

    @Test func majorTwoHelloFixtureIsRejectedByMajorOneDaemon() throws {
        guard case .request(let request) = try ControlCodec.decode(Fixtures.data("n-1", "hello-major2")) else {
            Issue.record("expected request")
            return
        }
        var handshake = server()
        let error = try #require(rejection(handshake.receive(.request(request), sessions: 0)))
        #expect(error.code == .protocolMajorMismatch)
    }

    // MARK: Capabilities

    @Test func notNegotiatedCapabilityDisablesTheOperationWithNotCapable() throws {
        let narrow = NegotiatedSession(version: .current, capabilities: [.inputOrigin])
        #expect(throws: DaemonError.self) { try narrow.validate(.textSnapshot(TextSnapshotRequest(sessionID: sid1, lines: 10))) }
        do {
            try narrow.validate(.drainWhenIdle)
            Issue.record("expected notCapable")
        } catch {
            #expect(error.code == .notCapable)
        }
        do {
            try narrow.validate(.create(makeCreate(coldLog: true)))
            Issue.record("expected notCapable")
        } catch {
            #expect(error.code == .notCapable)
        }
        try narrow.validate(.create(makeCreate(coldLog: false)))
        try narrow.validate(.list)

        let full = NegotiatedSession(version: .current, capabilities: Capability.initialSet)
        try full.validate(.textSnapshot(TextSnapshotRequest(sessionID: sid1, lines: 10)))
        try full.validate(.drainWhenIdle)
        try full.validate(.create(makeCreate()))
    }

    @Test func capabilityIntersectionPreservesOrderAndDedupes() {
        #expect(Capability.intersection(["a", "b", "c", "b"], ["c", "b", "z"]) == ["b", "c"])
        #expect(Capability.intersection([], ["a"]).isEmpty)
        #expect(Capability.initialSet.map(\.rawValue) == ["coldLog", "osc133", "textSnapshot", "inputOrigin", "drainWhenIdle"])
    }

    @Test func protocolVersionOrdering() {
        #expect(ProtocolVersion(major: 1, minor: 9) < ProtocolVersion(major: 2, minor: 0))
        #expect(ProtocolVersion(major: 1, minor: 1) < ProtocolVersion(major: 1, minor: 2))
        #expect(ProtocolVersion.current == ProtocolVersion(major: 1, minor: 0))
        #expect(ProtocolVersion(major: 1, minor: 2).description == "1.2")
    }
}
