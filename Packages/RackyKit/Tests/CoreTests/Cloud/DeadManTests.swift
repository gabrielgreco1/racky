import Foundation
import Testing

@testable import RackyCore

/// A chave morta é o que impede a VM esquecida de cobrar para sempre (estudo 6.1). Aqui o SCRIPT que vai para a VM roda de verdade
/// (bash, `RACKY_DRY_RUN=1`: nunca chama `shutdown`) e é comparado com a decisão pura em Swift.
@Suite("BK-12 - chave morta (política, script e cloud-init)", .tags(.integration))
struct DeadManTests {
    private let policy = DeadManPolicy(heartbeatInterval: .seconds(60), missedLimit: 20, bootGrace: .seconds(900), maxLifetime: .seconds(8 * 3600), idleShutdown: .seconds(900))
    private let boot = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: Double) -> Date { boot.addingTimeInterval(seconds) }

    @Test func leaseIsIntervalTimesMissedLimit() {
        #expect(policy.leaseTimeout == .seconds(1200))
        #expect(DeadManPolicy(heartbeatInterval: .seconds(30), missedLimit: 0).missedLimit == 1, "pelo menos 1 heartbeat")
    }

    @Test func decisionsFollowTheRules() {
        // heartbeat em dia -> segue
        #expect(policy.decision(now: at(600), booted: boot, lastHeartbeat: at(590), idleSince: nil, computers: 2) == .keep)
        // 20 heartbeats perdidos -> lease vencido
        #expect(policy.decision(now: at(2000), booted: boot, lastHeartbeat: at(700), idleSince: nil, computers: 2) == .shutdown(reason: .leaseExpired))
        #expect(policy.decision(now: at(1899), booted: boot, lastHeartbeat: at(700), idleSince: nil, computers: 2) == .keep)
        // nunca conectou: só a carência de boot
        #expect(policy.decision(now: at(899), booted: boot, lastHeartbeat: nil, idleSince: nil, computers: 0) == .keep)
        #expect(policy.decision(now: at(900), booted: boot, lastHeartbeat: nil, idleSince: nil, computers: 0) == .shutdown(reason: .bootGraceExpired))
        // vida máxima vale mesmo com heartbeat perfeito
        #expect(policy.decision(now: at(8 * 3600), booted: boot, lastHeartbeat: at(8 * 3600), idleSince: nil, computers: 5) == .shutdown(reason: .maxLifetime))
        // ocioso (sem computadores) por 15 min
        #expect(policy.decision(now: at(1000), booted: boot, lastHeartbeat: at(990), idleSince: at(100), computers: 0) == .shutdown(reason: .idle))
        #expect(policy.decision(now: at(1000), booted: boot, lastHeartbeat: at(990), idleSince: at(101), computers: 0) == .keep)
        // heartbeat "do futuro" não estende o lease
        #expect(policy.decision(now: at(5000), booted: boot, lastHeartbeat: at(900_000), idleSince: nil, computers: 1) == .keep)
    }

    // MARK: Script de verdade

    private struct Scenario {
        var now: Double
        var heartbeat: Double?
        var computers: Int
        var idleSince: Double?
    }

    private func runScript(_ scenario: Scenario, script: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("dm-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "\(Int(boot.timeIntervalSince1970))\n".write(to: dir.appendingPathComponent("boot"), atomically: true, encoding: .utf8)
        if let heartbeat = scenario.heartbeat { try "\(Int(boot.timeIntervalSince1970 + heartbeat))\n".write(to: dir.appendingPathComponent("heartbeat"), atomically: true, encoding: .utf8) }
        if let idle = scenario.idleSince { try "\(Int(boot.timeIntervalSince1970 + idle))\n".write(to: dir.appendingPathComponent("idle-since"), atomically: true, encoding: .utf8) }
        let file = dir.appendingPathComponent("deadman.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        process.environment = [
            "PATH": "/usr/bin:/bin", "RACKY_DRY_RUN": "1", "RACKY_ONCE": "1", "RACKY_STATE_DIR": dir.path,
            "RACKY_NOW": String(Int(boot.timeIntervalSince1970 + scenario.now)), "RACKY_COMPUTERS": String(scenario.computers),
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theGeneratedScriptDecidesLikeTheSwiftPolicy() throws {
        let script = DeadManScript.render(policy)
        let scenarios: [Scenario] = [
            .init(now: 600, heartbeat: 590, computers: 2, idleSince: nil),
            .init(now: 2000, heartbeat: 700, computers: 2, idleSince: nil),
            .init(now: 1899, heartbeat: 700, computers: 2, idleSince: nil),
            .init(now: 899, heartbeat: nil, computers: 0, idleSince: nil),
            .init(now: 900, heartbeat: nil, computers: 0, idleSince: nil),
            .init(now: 8 * 3600, heartbeat: 8 * 3600, computers: 5, idleSince: nil),
            .init(now: 1000, heartbeat: 990, computers: 0, idleSince: 100),
            .init(now: 1000, heartbeat: 990, computers: 0, idleSince: 101),
            .init(now: 5000, heartbeat: 900_000, computers: 1, idleSince: nil),
            .init(now: 1000, heartbeat: 990, computers: 0, idleSince: nil),  // ocioso desde o boot
            .init(now: 899, heartbeat: 890, computers: 0, idleSince: nil),
        ]
        for scenario in scenarios {
            let expected = policy.decision(
                now: at(scenario.now), booted: boot, lastHeartbeat: scenario.heartbeat.map(at), idleSince: scenario.idleSince.map(at) ?? (scenario.computers == 0 ? boot : nil),
                computers: scenario.computers)
            let got = try runScript(scenario, script: script)
            switch expected {
            case .keep: #expect(got == "keep", "cenário \(scenario): esperado keep, script disse \(got)")
            case .shutdown(let reason): #expect(got == "shutdown:\(reason.rawValue)", "cenário \(scenario): esperado \(reason), script disse \(got)")
            }
        }
    }

    @Test func scriptIsValidBashAndNeverTouchesTheCloudAPI() throws {
        let script = DeadManScript.render(policy)
        #expect(script.hasPrefix("#!/bin/bash\n"))
        for forbidden in ["aws ", "curl", "wget", "169.254", "AWS_"] { #expect(!script.contains(forbidden), "a chave morta não usa credencial nem rede: \(forbidden)") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dm-syntax-\(UInt32.random(in: 0 ... 0xFFFFFF)).sh")
        try script.write(to: dir, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", dir.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        // shellcheck, se estiver instalado (não é requisito do ambiente).
        if let shellcheck = ["/opt/homebrew/bin/shellcheck", "/usr/local/bin/shellcheck"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: shellcheck)
            check.arguments = ["-s", "bash", dir.path]
            try check.run()
            check.waitUntilExit()
            #expect(check.terminationStatus == 0, "shellcheck reprovou o script da chave morta")
        }
    }

    @Test func heartbeatCommandIsAtomicAndUsesTheVMClock() {
        #expect(DeadManPolicy.heartbeatCommand == "date +%s > /var/lib/racky/heartbeat.tmp && mv -f /var/lib/racky/heartbeat.tmp /var/lib/racky/heartbeat")
    }

    // MARK: cloud-init

    private func cloudInit() -> String {
        CloudInit.userData(policy: policy, authorizedKey: CloudFixture.access.authorizedKey, hostKey: CloudFixture.access.hostKey)
    }

    @Test func cloudInitIsValidYAMLWithTheScriptEmbeddedVerbatim() throws {
        let text = cloudInit()
        #expect(text.hasPrefix("#cloud-config\n"))
        for needle in ["ssh_pwauth: false", "disable_root: true", "lock_passwd: true", "AllowUsers racky", "PasswordAuthentication no", "AllowAgentForwarding no",
                       "racky-deadman.service", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEFVVEhPUklaRURBVVRIT1JJWkVEQVVUSE9SSVpFRA racky"] {
            #expect(text.contains(needle), "falta \(needle)")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ruby") else { return }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ci-\(UInt32.random(in: 0 ... 0xFFFFFF)).yaml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            "-ryaml", "-e",
            "d = YAML.load_file(ARGV[0]); f = d['write_files'].find { |w| w['path'] == '/usr/local/bin/racky-deadman' }; print f['content']; $stderr.print d['ssh_keys']['ed25519_private']",
            file.path,
        ]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let embedded = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let privateKey = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "YAML inválido")
        #expect(embedded.trimmingCharacters(in: .whitespacesAndNewlines) == DeadManScript.render(policy).trimmingCharacters(in: .whitespacesAndNewlines), "o script chegou à VM igual ao testado")
        #expect(privateKey.trimmingCharacters(in: .whitespacesAndNewlines) == CloudFixture.access.hostKey.privateKey)
    }

    /// O cloud-init de referência fica no repositório (`runtime/cloud/`), com chaves de mentira, para revisão e para o spike da Fase 0.
    @Test func referenceCloudInitInTheRepoMatchesTheGenerator() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("runtime/cloud/racky-host.cloud-init.yaml")
        let header = "# Referência gerada por CloudInit.userData com chaves de mentira (BK-12). Regerar: RACKY_UPDATE_GOLDEN=1 swift test --filter DeadManTests\n"
        let expected = header + cloudInit() + "\n"
        if ProcessInfo.processInfo.environment["RACKY_UPDATE_GOLDEN"] == "1" {
            try expected.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == expected, "regere com RACKY_UPDATE_GOLDEN=1")
    }
}
