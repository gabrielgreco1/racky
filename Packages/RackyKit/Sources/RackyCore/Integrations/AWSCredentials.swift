import Foundation

/// Credenciais da AWS de uma conexão: chaves fixas ou temporárias (com token de sessão e validade).
public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}

/// Falhas ao obter credenciais do AWS CLI (perfil). A descrição já diz o que o usuário faz.
public enum AWSCredentialsFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidProfile
    case cliMissing
    case sessionExpired(profile: String)
    case cli(String)
    case unexpectedOutput

    public var description: String {
        switch self {
        case .invalidProfile: "The AWS CLI profile name is not valid."
        case .cliMissing: "The AWS CLI was not found. Install it (brew install awscli), then run aws sso login --profile <name> in a terminal."
        case .sessionExpired(let profile): "The AWS session for \"\(profile)\" is missing or expired. Run aws sso login --profile \(profile) in a terminal, then try again."
        case .cli(let why): "The AWS CLI could not give credentials: \(why)"
        case .unexpectedOutput: "The AWS CLI answered something Racky does not understand. Update the AWS CLI (version 2.9 or newer)."
        }
    }
}

/// Resultado de rodar o `aws` (trocável nos testes).
public struct AWSCLIResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public init(status: Int32, stdout: Data, stderr: String) { self.status = status; self.stdout = stdout; self.stderr = stderr }
}

/// Credenciais de um perfil do AWS CLI: roda `aws configure export-credentials --profile <nome> --format process` (funciona com perfis
/// SSO depois de `aws sso login`) e renova quando vencem. O Racky não lê `~/.aws`: quem lê é o CLI.
public actor AWSProfileCredentials {
    public typealias Runner = @Sendable (_ arguments: [String]) async throws -> AWSCLIResult

    public let profile: String
    private let runner: Runner
    private let now: @Sendable () -> Date
    private var cached: AWSCredentials?

    public init(profile: String, runner: Runner? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = profile
        self.runner = runner ?? { try await AWSProfileCredentials.runAWS($0) }
        self.now = now
    }

    /// Credenciais válidas por mais de um minuto (as em cache, ou novas do CLI).
    public func credentials() async throws -> AWSCredentials {
        if let cached, cached.expiration.map({ $0.timeIntervalSince(now()) > 60 }) ?? true { return cached }
        let fresh = try await Self.export(profile: profile, runner: runner)
        cached = fresh
        return fresh
    }

    /// Descarta o cache (depois de um "expirou" do S3).
    public func invalidate() { cached = nil }

    // MARK: CLI

    static func validName(_ profile: String) -> Bool {
        !profile.isEmpty && profile.count <= 128 && !profile.hasPrefix("-")
            && profile.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    public static func export(profile: String, runner: Runner) async throws -> AWSCredentials {
        guard validName(profile) else { throw AWSCredentialsFailure.invalidProfile }
        let result: AWSCLIResult
        do {
            result = try await runner(["configure", "export-credentials", "--profile", profile, "--format", "process"])
        } catch let failure as AWSCredentialsFailure {
            throw failure
        } catch {
            throw AWSCredentialsFailure.cli(error.localizedDescription)
        }
        guard result.status == 0 else {
            let text = result.stderr.lowercased()
            if ["sso", "expired", "token", "login", "credentials"].contains(where: text.contains) { throw AWSCredentialsFailure.sessionExpired(profile: profile) }
            let line = result.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"
            throw AWSCredentialsFailure.cli(String(line.prefix(200)))
        }
        return try parse(result.stdout)
    }

    /// O JSON do formato `process`: `{"Version":1,"AccessKeyId":…,"SecretAccessKey":…,"SessionToken":…,"Expiration":"…"}`.
    public static func parse(_ data: Data) throws -> AWSCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["AccessKeyId"] as? String, !key.isEmpty, let secret = json["SecretAccessKey"] as? String, !secret.isEmpty
        else { throw AWSCredentialsFailure.unexpectedOutput }
        var expiration: Date?
        if let text = json["Expiration"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiration = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return AWSCredentials(accessKeyID: key, secretAccessKey: secret, sessionToken: json["SessionToken"] as? String, expiration: expiration)
    }

    /// Onde o `aws` pode estar: o PATH do app (que no Finder é curto) mais os lugares do Homebrew.
    public static func locateAWS(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        var dirs = (path ?? "").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(extra) { dirs.append(extra) }
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("aws") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Roda o `aws` de verdade (fora da thread principal, com limite de 30 s).
    static func runAWS(_ arguments: [String]) async throws -> AWSCLIResult {
        guard let executable = locateAWS() else { throw AWSCredentialsFailure.cliMissing }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = ((env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
                env["AWS_PAGER"] = ""
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(throwing: AWSCredentialsFailure.cli(error.localizedDescription)); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
                // Os dois pipes são lidos ao mesmo tempo para nenhum encher e travar o CLI.
                let errBox = LockedData()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errBox.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: AWSCLIResult(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errBox.get(), as: UTF8.self)))
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
