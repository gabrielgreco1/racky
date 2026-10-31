import Darwin
import Foundation
import Testing

@testable import RackyPlatform

/// T1-07 / S-03: credenciais do peer, derivação da política e decisão (uid, requisito, modo ad-hoc).
/// O peer real aqui é o próprio processo de teste (xctest), assinado pela Apple: serve de "processo de teste" do S-03.
@Suite struct PeerAuthTests {
    /// Conecta um cliente e devolve o lado aceito (com `peer`) mais o cliente (mantido vivo).
    private func connectedPair() async throws -> (accepted: UDSConnection, client: UDSConnection, dir: TempSocketDir, listener: UDSListener) {
        let dir = try TempSocketDir()
        let listener = try await UDSListener.listen(path: dir.socketPath)
        let client = try await UDSClient.connect(path: dir.socketPath)
        var iterator = listener.connections.makeAsyncIterator()
        let accepted = try #require(await iterator.next())
        return (accepted, client, dir, listener)
    }

    @Test func credentialsCarryUidPidAndAuditToken() async throws {
        let pair = try await connectedPair()
        defer { pair.client.close(); pair.accepted.close(); pair.listener.close() }
        let peer = try #require(pair.accepted.peer)
        #expect(peer.uid == geteuid())
        #expect(peer.pid == getpid())
        #expect(peer.auditToken?.count == MemoryLayout<audit_token_t>.size)
        #expect(pair.client.peer == nil)
    }

    @Test func sameUIDIsAcceptedInAdhocDevelopmentMode() async throws {
        let pair = try await connectedPair()
        defer { pair.client.close(); pair.accepted.close(); pair.listener.close() }
        let decision = PeerAuthenticator(policy: .adhocDevelopment).authenticate(pair.accepted.peer)
        #expect(decision == .accepted)
    }

    @Test func differentUIDIsRejectedInEveryMode() async throws {
        let pair = try await connectedPair()
        defer { pair.client.close(); pair.accepted.close(); pair.listener.close() }
        // Simula "peer de outro usuário": o daemon espera um uid diferente do (real) do peer.
        let other = geteuid() &+ 1
        for policy in [PeerAuthPolicy.adhocDevelopment, .signed(requirement: "anchor apple generic or identifier \"x\"")] {
            let decision = PeerAuthenticator(policy: policy, expectedUID: other).authenticate(pair.accepted.peer)
            guard case .rejected(let rejection) = decision else {
                Issue.record("expected rejection for \(policy.modeName)")
                continue
            }
            #expect(rejection.kind == .uidMismatch)
        }
    }

    @Test func missingCredentialsAreRejected() {
        let decision = PeerAuthenticator(policy: .adhocDevelopment).authenticate(nil)
        #expect(decision == .rejected(PeerRejection(.noCredentials)))
    }

    @Test func denyAllRejectsEvenTheSameUID() async throws {
        let pair = try await connectedPair()
        defer { pair.client.close(); pair.accepted.close(); pair.listener.close() }
        let decision = PeerAuthenticator(policy: .denyAll(reason: "test")).authenticate(pair.accepted.peer)
        guard case .rejected(let rejection) = decision else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.kind == .policyDenied)
    }

    @Test func signedPolicyRejectsPeerWithoutAuditToken() {
        let peer = PeerCredentials(uid: geteuid(), gid: getegid(), pid: getpid(), auditToken: nil)
        let decision = PeerAuthenticator(policy: .signed(requirement: "identifier \"x\"")).authenticate(peer)
        #expect(decision == .rejected(PeerRejection(.noAuditToken)))
    }

    @Test func signedPolicyRejectsMalformedRequirement() async throws {
        let pair = try await connectedPair()
        defer { pair.client.close(); pair.accepted.close(); pair.listener.close() }
        let decision = PeerAuthenticator(policy: .signed(requirement: "this is (not a requirement")).authenticate(pair.accepted.peer)
        guard case .rejected(let rejection) = decision else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.kind == .requirementInvalid)
    }

    @Test func testRunnerProcessFailsTheAppRequirementAndPassesItsOwn() async throws {
        let pair = try await connectedPair()
        defer { pair.client.close(); pair.accepted.close(); pair.listener.close() }
        // (c) do S-03: o processo do `swift test` (xctest, assinado pela Apple) não é o app.
        let app = PeerAuthPolicy.requirement(clientIdentifier: PeerAuthPolicy.appIdentifier, leafSHA1: String(repeating: "ab", count: 20))
        let refused = PeerAuthenticator(policy: .signed(requirement: app)).authenticate(pair.accepted.peer)
        guard case .rejected(let rejection) = refused else {
            Issue.record("the test runner must not satisfy the app requirement")
            return
        }
        #expect(rejection.kind == .requirementNotSatisfied)
        // E o mesmo caminho aceita quando o requisito descreve o próprio processo (prova que a checagem funciona).
        let own = try #require(CodeIdentity.ofCurrentProcess()?.identifier)
        let accepted = PeerAuthenticator(policy: .signed(requirement: "identifier \"\(own)\"")).authenticate(pair.accepted.peer)
        #expect(accepted == .accepted)
    }

    // MARK: Derivação da política

    @Test func signedDaemonGetsRequirementBoundToItsOwnLeaf() {
        let leaf = String(repeating: "AB", count: 20)
        let daemon = CodeIdentity(identifier: "app.racky.ptyd", isAdhoc: false, leafSHA1: leaf)
        let policy = PeerAuthPolicy.resolve(daemon: daemon, allowAdhocDevelopment: true)  // a flag não enfraquece daemon assinado
        #expect(policy == .signed(requirement: "identifier \"app.racky.mac\" and certificate leaf = H\"\(leaf.lowercased())\""))
    }

    @Test func adhocDaemonNeedsTheExplicitBuildOptIn() {
        let daemon = CodeIdentity(identifier: "app.racky.ptyd", isAdhoc: true, leafSHA1: nil)
        #expect(PeerAuthPolicy.resolve(daemon: daemon, allowAdhocDevelopment: true) == .adhocDevelopment)
        guard case .denyAll = PeerAuthPolicy.resolve(daemon: daemon, allowAdhocDevelopment: false) else {
            Issue.record("ad-hoc daemon without the build flag must deny everyone")
            return
        }
    }

    @Test func unreadableOwnSignatureDeniesEveryone() {
        guard case .denyAll = PeerAuthPolicy.resolve(daemon: nil, allowAdhocDevelopment: true) else {
            Issue.record("expected denyAll")
            return
        }
    }

    @Test func currentProcessIdentityIsReadable() {
        let identity = CodeIdentity.ofCurrentProcess()
        #expect(identity?.identifier != nil)
    }
}
