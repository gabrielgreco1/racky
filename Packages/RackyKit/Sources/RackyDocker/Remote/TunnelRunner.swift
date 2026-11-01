import RackyPlatform
import Darwin
import Foundation

public struct TunnelCommandResult: Sendable, Equatable {
    public var status: Int32
    public var stderr: String
    public init(status: Int32, stderr: String = "") { self.status = status; self.stderr = stderr }
}

/// Processo de longa vida (o mestre do `ssh`).
public protocol TunnelProcess: Sendable {
    func terminate()
    /// Retorna quando o processo sai (com o código).
    func waitUntilExit() async -> Int32
}

/// Quem de fato executa o `ssh`. Injetado: em produção `ProcessTunnelRunner`; nos testes um proxy local de socket (sem sshd).
public protocol TunnelRunner: Sendable {
    func launch(_ arguments: [String]) async throws -> any TunnelProcess
    func run(_ arguments: [String], timeout: Duration) async throws -> TunnelCommandResult
}

/// `/usr/bin/ssh` como processo filho (via `RackyPlatform`: nada de `Process` solto no Docker). Ambiente mínimo, sem `SSH_AUTH_SOCK`.
public struct ProcessTunnelRunner: TunnelRunner {
    public var executable: String
    public init(executable: String = SSHCommand.executable) { self.executable = executable }

    static var environment: [String: String] { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "C"] }

    public func launch(_ arguments: [String]) async throws -> any TunnelProcess {
        SSHProcess(process: try ManagedProcess.launch(executable: URL(fileURLWithPath: executable), arguments: arguments, environment: Self.environment))
    }

    public func run(_ arguments: [String], timeout: Duration) async throws -> TunnelCommandResult {
        do {
            let output = try await ProcessRunner.run(ProcessRequest(
                executable: URL(fileURLWithPath: executable), arguments: arguments, environment: ["SSH_AUTH_SOCK": ""], timeout: timeout, maxOutputBytes: 64 << 10))
            return TunnelCommandResult(status: output.exitCode, stderr: String(output.stderrString.suffix(4096)))
        } catch ProcessRunnerError.timedOut {
            return TunnelCommandResult(status: 255, stderr: "ssh: tempo esgotado")
        }
    }
}

struct SSHProcess: TunnelProcess {
    let process: ManagedProcess
    func terminate() { process.terminate() }
    func waitUntilExit() async -> Int32 { await process.waitUntilExit() }
}

/// Porta TCP livre no loopback (bind em 0 e leitura). Há uma janela de corrida entre fechar e o `ssh` reabrir; o `ssh -O forward`
/// falha alto se alguém tomou a porta e quem chama tenta outra.
func freeLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SSHConfigError.invalidField("socket") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { throw SSHConfigError.invalidField("bind") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    guard got == 0 else { throw SSHConfigError.invalidField("getsockname") }
    return Int(UInt16(bigEndian: address.sin_port))
}
