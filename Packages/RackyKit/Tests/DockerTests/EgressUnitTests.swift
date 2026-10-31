import RackyProtocol
import CryptoKit
import Foundation
import Testing

@testable import RackyDocker

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("abx-egress-unit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("T3-02 - config do egress, segredos em arquivo e integridade do reqlog", .tags(.integration))
struct EgressUnitTests {
    private func json(_ config: EgressConfigFile) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: try config.jsonData()) as? [String: Any])
    }

    @Test func directConfigHasNoUpstream() throws {
        let root = try json(EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: ["172.30.0.0/24"], internalSubnet: "172.18.0.0/16"))
        #expect(root["via"] as? String == "direct" && root["upstream"] == nil)
        #expect(root["internal_subnet"] as? String == "172.18.0.0/16" && root["allow_cidrs"] as? [String] == ["172.30.0.0/24"])
        #expect(root["proxy_port"] as? Int == 3128 && root["admin_port"] as? Int == 8790)
    }

    @Test func genericProxyUsesUsernameAndSecretAsPassword() throws {
        let profile = ProxyProfile(name: "corp", scheme: .socks5, host: "10.1.2.3", port: 1080, username: "alice",
                                   geo: ProxyGeo(country: "br", mode: .suffix, template: "-cc-{cc}"))
        let root = try json(EgressConfigFile.make(profile: profile, secret: "s3cr3t-pass"))
        let up = try #require(root["upstream"] as? [String: Any])
        #expect(up["scheme"] as? String == "socks5" && up["host"] as? String == "10.1.2.3" && up["port"] as? Int == 1080)
        #expect(up["username"] as? String == "alice" && up["password"] as? String == "s3cr3t-pass")
        let geo = try #require(up["geo"] as? [String: Any])
        #expect(geo["country"] as? String == "br" && geo["template"] as? String == "-cc-{cc}")
        #expect(root["via"] as? String == "corp")
    }

    @Test func zytePresetPutsTheKeyInTheUsernameWithEmptyPassword() throws {
        let profile = ProxyProfile.zytePreset(name: "zyte", secretID: "proxy-x")
        let up = try #require(json(EgressConfigFile.make(profile: profile, secret: "ZYTEKEY123"))["upstream"] as? [String: Any])
        #expect(up["host"] as? String == "proxy.zyte.com" && up["port"] as? Int == 8011 && up["scheme"] as? String == "http")
        #expect(up["username"] as? String == "ZYTEKEY123" && up["password"] as? String == "")
    }

    @Test func agentEnvironmentPointsAtTheLocalProxyAndHoldsNoSecrets() {
        let env = ComputerProvisioner.agentEnvironment()
        #expect(env.contains("HTTP_PROXY=http://127.0.0.1:3128") && env.contains("HTTPS_PROXY=http://127.0.0.1:3128") && env.contains("ALL_PROXY=http://127.0.0.1:3128"))
        #expect(env.contains { $0.hasPrefix("NO_PROXY=") && $0.contains("localhost") })
        #expect(env.allSatisfy { !$0.lowercased().contains("token") && !$0.lowercased().contains("pass") })
    }

    @Test func singleContainerSpecIsHardenedAndPublishesOnlyTheControlPort() throws {
        let labels = ComputerLabels(owner: "o", computerID: "abcdef12-3456-7890-abcd-ef1234567890", computerName: "n", isTest: true)
        let request = ComputerProvisionRequest(
            labels: labels, image: "racky-computer:ctx-x", display: .headless, token: "T0KEN", config: EgressConfigFile(internalSubnet: ""),
            secrets: BoxSecretFiles(root: URL(fileURLWithPath: "/tmp/x")), runDirectory: URL(fileURLWithPath: "/tmp/run"))
        let spec = ComputerProvisioner.containerSpec(request, work: URL(fileURLWithPath: "/tmp/run/work"), logs: URL(fileURLWithPath: "/tmp/run/logs"),
                                                     taskSecrets: URL(fileURLWithPath: "/tmp/s"), volume: "ab-prof-x")
        #expect(spec.name == "ab-abcdef12" && spec.labels[RackyLabel.role] == "computer" && spec.network?.network == "bridge")
        #expect(spec.hardening == .standard && spec.user == nil)
        #expect(spec.capAdd.sorted() == ["KILL", "NET_ADMIN", "SETGID", "SETPCAP", "SETUID"])
        #expect(spec.publishedPorts == [PublishedPort(containerPort: "8790/tcp", hostIP: "127.0.0.1", hostPort: "")])
        #expect(spec.tmpfs["/run/racky"]?.contains("uid=10003") == true && spec.tmpfs["/run/racky"]?.contains("mode=0700") == true)
        #expect(spec.binds.contains("/tmp/run/logs:/run/racky/logs") && spec.binds.contains("/tmp/s:/run/abx-secrets:ro"))
        #expect(!String(describing: spec.body()).contains("T0KEN") && spec.environment.allSatisfy { !$0.contains("T0KEN") })
        #expect(request.display.computerMemory < (3 << 30) + (1 << 30) + (128 << 20), "menos que a soma antiga dos três containers")
    }

    // MARK: segredos em arquivo

    @Test func secretFilesAre0400In0700AndReplaceAtomically() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let files = BoxSecretFiles(root: root)
        let id = UUID().uuidString.lowercased()
        let token = try files.write(Data("one".utf8), named: "token", computerID: id, role: .egress)
        try files.write(Data("{}".utf8), named: "egress.json", computerID: id, role: .egress)
        #expect(try files.permissionViolations(computerID: id).isEmpty)
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        #expect(mode(token) == 0o400 && mode(token.deletingLastPathComponent()) == 0o700 && mode(token.deletingLastPathComponent().deletingLastPathComponent()) == 0o700)
        try files.write(Data("two".utf8), named: "token", computerID: id, role: .egress)  // troca por rename
        #expect(try String(contentsOf: token, encoding: .utf8) == "two" && mode(token) == 0o400)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: token.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
        // permissão frouxa é detectada
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: token.path)
        #expect(try files.permissionViolations(computerID: id).map { URL(fileURLWithPath: $0).lastPathComponent } == ["token"])
        try files.removeAll(computerID: id)
        #expect(!FileManager.default.fileExists(atPath: try files.computerDirectory(id).path))
        try files.removeAll(computerID: id)  // idempotente
    }

    @Test func secretFilesRejectPathTricks() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let files = BoxSecretFiles(root: root)
        for bad in ["../etc", "a/b", "", "..", "x y"] {
            #expect(throws: BoxSecretFilesError.self) { try files.computerDirectory(bad) }
        }
        for bad in ["../x", "a/b", ".hidden", "", ".."] {
            #expect(throws: BoxSecretFilesError.self) { try files.write(Data(), named: bad, computerID: "ok", role: .egress) }
        }
    }

    // MARK: integridade do reqlog

    private func chain(_ count: Int, tamperAt: Int? = nil) -> String {
        var previous = ReqlogIntegrity.genesis
        var lines: [String] = []
        for index in 0..<count {
            let line = "{\"id\":\"\(index)\",\"prev_sha256\":\"\(previous)\",\"url\":\"http://x/\(index)\"}"
            previous = SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
            lines.append(line)
        }
        if let tamperAt { lines[tamperAt] = lines[tamperAt].replacingOccurrences(of: "http://x/", with: "http://evil/") }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func reqlogIntegrityVerifiesAndLocatesTampering() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("requests.jsonl")
        #expect(try ReqlogIntegrity.verify(file: file) == .ok(lines: 0), "sem arquivo: nada a verificar")
        try chain(6).write(to: file, atomically: true, encoding: .utf8)
        let ok = try ReqlogIntegrity.verify(file: file)
        #expect(ok == .ok(lines: 6) && ok.message == "Log integrity: OK")
        try chain(6, tamperAt: 2).write(to: file, atomically: true, encoding: .utf8)
        let bad = try ReqlogIntegrity.verify(file: file)
        #expect(bad == .tampered(line: 4) && bad.message == "Tampered at line 4")  // a linha 3 mudou: a 4 deixa de encaixar
        var lines = chain(6).split(separator: "\n").map(String.init)
        lines.remove(at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(try ReqlogIntegrity.verify(file: file) == .tampered(line: 2), "linha apagada")
    }

    @Test func buildContextHashIgnoresPythonBytecode() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("FROM scratch\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        let before = try BuildContext.contentHash(of: root)
        let cache = root.appendingPathComponent("pkg/__pycache__", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appendingPathComponent("m.cpython-313.pyc"))
        try Data("x".utf8).write(to: root.appendingPathComponent("stray.pyc"))
        #expect(try BuildContext.contentHash(of: root) == before)
    }

    @Test func shippedComputerContextIsPinnedByDigestAndHasNoPackageManagerPins() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) { root.deleteLastPathComponent() }
        let dockerfile = try String(contentsOf: root.appendingPathComponent("runtime/computer/Dockerfile"), encoding: .utf8)
        let from = try #require(dockerfile.split(separator: "\n").first { $0.hasPrefix("FROM ") })
        #expect(from.contains("@sha256:") && from.split(separator: ":").last?.count == 64, "base fixada por digest: \(from)")
        #expect(dockerfile.contains("useradd --uid 10001") && dockerfile.contains("--uid 10003") && dockerfile.contains("HEALTHCHECK") && dockerfile.contains("iptables"))
        #expect(!dockerfile.contains("apt-get install -y --no-install-recommends xvfb=") && !dockerfile.contains("=1."), "sem pins de versão de apt")
        let manifest = try String(contentsOf: root.appendingPathComponent("runtime/images.json"), encoding: .utf8)
        #expect(manifest.contains("\"racky-computer\"") && !manifest.contains("racky-egress") && !manifest.contains("racky-box") && manifest.contains(String(from.dropFirst(5))))
    }

    // MARK: testes unitários do egress (Python) rodam junto da suíte Swift

    @Test func pythonEgressUnitSuitePasses() throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { return }  // sem Python no Mac: a suíte roda no CI Linux (08 §8)
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/tests").path) { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", "-m", "unittest", "discover", "-s", "tests"]
        process.currentDirectoryURL = root.appendingPathComponent("runtime/computer")
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "unittest do egress falhou:\n\(text.suffix(2000))")
        #expect(text.contains("OK"))
    }
}
