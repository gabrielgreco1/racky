import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyPlatform

/// Certificados de assinatura efêmeros em keychains temporários (receita de CI do S-03; 08 §8.4).
/// Não toca o keychain de login nem a lista de keychains do usuário: assina por nome com `--keychain <caminho>`.
final class EphemeralSigning: @unchecked Sendable {  // SAFETY: imutável depois do init.
    struct Identity {
        let name: String
        let keychain: String
        let sha1: String
    }

    let directory: URL
    let identityA: Identity
    let identityB: Identity

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/abs-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        identityA = try Self.makeIdentity(name: "Racky Test Signing A", in: directory)
        identityB = try Self.makeIdentity(name: "Racky Test Signing B", in: directory)
    }

    deinit {
        for identity in [identityA, identityB] { _ = try? Self.run("/usr/bin/security", ["delete-keychain", identity.keychain]) }
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw SigningError.failed(tool: tool, arguments: arguments, output: text) }
        return text
    }

    private static func makeIdentity(name: String, in directory: URL) throws -> Identity {
        let work = directory.appendingPathComponent(UUID().uuidString.prefix(8) + "")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let config = work.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(name)
        [ext]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning
        """.write(to: config, atomically: true, encoding: .utf8)
        let key = work.appendingPathComponent("key.pem").path
        let cert = work.appendingPathComponent("cert.pem").path
        let p12 = work.appendingPathComponent("id.p12").path
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", config.path, "-keyout", key, "-out", cert])
        let password = UUID().uuidString
        do {
            try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:\(password)", "-legacy"])
        } catch {
            try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:\(password)"])
        }
        let keychain = directory.appendingPathComponent("\(work.lastPathComponent).keychain-db").path
        try run("/usr/bin/security", ["create-keychain", "-p", password, keychain])
        try run("/usr/bin/security", ["set-keychain-settings", "-lut", "3600", keychain])
        try run("/usr/bin/security", ["unlock-keychain", "-p", password, keychain])
        try run("/usr/bin/security", ["import", p12, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"])
        try run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain])
        let der = try run("/usr/bin/openssl", ["x509", "-in", cert, "-noout", "-fingerprint", "-sha1"])
        let sha1 = der.split(separator: "=").last.map { $0.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        return Identity(name: name, keychain: keychain, sha1: sha1)
    }

    /// Copia `source` para `directory/<name>` e assina com `identity` (ou ad-hoc se `nil`).
    func signedCopy(of source: URL, as name: String, identifier: String, identity: Identity?) throws -> URL {
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        var arguments = ["--force", "--options", "runtime", "--identifier", identifier]
        if let identity {
            arguments += ["--sign", identity.name, "--keychain", identity.keychain]
        } else {
            arguments += ["--sign", "-"]
        }
        try Self.run("/usr/bin/codesign", arguments + [target.path])
        return target
    }
}

enum SigningError: Error { case failed(tool: String, arguments: [String], output: String) }

private func peerprobeBinary() -> URL { rackydBinary().deletingLastPathComponent().appendingPathComponent("peerprobe") }

/// Roda o `peerprobe` (cópia assinada) contra o socket e devolve a linha de desfecho.
private func probe(_ binary: URL, socket: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try EphemeralSigning.run(binary.path, [socket]).trimmingCharacters(in: .whitespacesAndNewlines) })
        }
    }
}

/// Handshake feito pelo próprio processo de teste (xctest); devolve o desfecho no formato do `peerprobe`.
private func handshakeFromTestProcess(socket: String) async throws -> String {
    let connection = try await UDSClient.connect(path: socket)
    let framed = FramedConnection(connection)
    defer { Task { await framed.close() } }
    var handshake = ClientHandshake(client: ClientInfo(kind: .app, build: "xctest"))
    try? await framed.send(.control(.request(handshake.makeHello(id: 1))))
    switch try await framed.receive() {
    case .control(.reply(.error(_, let error))): return "REJECTED \(error.code.rawValue)"
    case .some: return "ACCEPTED"
    case nil: return "CLOSED"
    }
}

/// T1-07: peer auth ponta a ponta com o `rackyd` real, assinado com certificado efêmero.
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1))) struct PeerAuthDaemonTests {
    @Test func signedDaemonAcceptsOnlyTheAppIdentity() async throws {
        let signing = try EphemeralSigning()
        let daemonBinary = try signing.signedCopy(of: rackydBinary(), as: "rackyd-signed", identifier: "app.racky.ptyd", identity: signing.identityA)
        let app = try signing.signedCopy(of: peerprobeBinary(), as: "probe-app", identifier: "app.racky.mac", identity: signing.identityA)
        let helper = try signing.signedCopy(of: peerprobeBinary(), as: "probe-cli", identifier: "app.racky.cli", identity: signing.identityA)
        let otherCertificate = try signing.signedCopy(of: peerprobeBinary(), as: "probe-other", identifier: "app.racky.mac", identity: signing.identityB)
        let adhoc = try signing.signedCopy(of: peerprobeBinary(), as: "probe-adhoc", identifier: "app.racky.mac", identity: nil)

        let harness = try DaemonHarness()
        try await harness.start(idleExit: 0, binary: daemonBinary)
        defer { harness.terminateNow() }

        // Aceito: identificador do app + mesma folha do daemon.
        #expect(try await probe(app, socket: harness.socketPath) == "ACCEPTED")
        // Recusados com erro tipado: outro identificador (o helper `racky`), outro certificado, ad-hoc.
        #expect(try await probe(helper, socket: harness.socketPath) == "REJECTED peerRejected")
        #expect(try await probe(otherCertificate, socket: harness.socketPath) == "REJECTED peerRejected")
        #expect(try await probe(adhoc, socket: harness.socketPath) == "REJECTED peerRejected")
        // O próprio processo de teste (xctest, assinado pela Apple) também é recusado.
        #expect(try await handshakeFromTestProcess(socket: harness.socketPath) == "REJECTED peerRejected")
        // O daemon continua de pé e aceitando o app depois das recusas.
        #expect(try await probe(app, socket: harness.socketPath) == "ACCEPTED")
    }

    @Test func adhocDevelopmentDaemonAcceptsSameUIDPeers() async throws {
        // `swift test` compila o rackyd em debug (RACKY_ALLOW_ADHOC_PEERS) e ele é ad-hoc: modo de desenvolvimento.
        let signing = try EphemeralSigning()
        let adhocDaemon = try signing.signedCopy(of: rackydBinary(), as: "rackyd-adhoc", identifier: "app.racky.ptyd", identity: nil)
        let adhocPeer = try signing.signedCopy(of: peerprobeBinary(), as: "probe-adhoc", identifier: "anything", identity: nil)
        let harness = try DaemonHarness()
        try await harness.start(idleExit: 0, binary: adhocDaemon)
        defer { harness.terminateNow() }
        #expect(try await probe(adhocPeer, socket: harness.socketPath) == "ACCEPTED")
        // E o próprio processo de teste (mesmo uid) também, como nos demais DaemonTests.
        #expect(try await handshakeFromTestProcess(socket: harness.socketPath) == "ACCEPTED")
    }
}
