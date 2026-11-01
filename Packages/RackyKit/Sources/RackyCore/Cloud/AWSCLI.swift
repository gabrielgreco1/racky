import RackyPlatform
import Foundation

/// Transporte da AWS: o `aws` CLI v2 do próprio usuário, com o perfil do `aws login` (credenciais de curta duração do navegador,
/// renovadas pelo CLI). O app nunca lê nem guarda chave: só roda `aws <serviço> <ação> --profile <perfil> --output json`.
/// Escolhido em vez do SDK ou de SigV4 próprio porque o `aws login` só existe no CLI e já cuida da renovação.
public struct AWSCLI: Sendable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        /// Nenhum `aws` instalado nos caminhos conhecidos.
        case missing
        /// Sem sessão (nunca entrou, expirou ou o perfil não existe): o usuário precisa do `aws login` de novo.
        case signedOut(String)
        case failed(command: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .missing: "The AWS command line tool isn't installed. Install it from aws.amazon.com/cli, then connect again."
            case .signedOut: "Your AWS sign-in expired. Click Connect AWS to sign in again."
            case .failed(let command, let message): "AWS \(command) failed: \(message)"
            }
        }
    }

    public typealias Runner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async throws -> ProcessOutput
    /// Só o `aws login`: ambiente e entrada extras (navegador pelo `open` do macOS, "y" para trocar a sessão do perfil).
    public typealias LoginRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async throws -> ProcessOutput

    public var profile: String
    public var executable: URL?
    private let runner: Runner
    private let loginRunner: LoginRunner

    /// Onde o instalador oficial, o Homebrew e o pacote da AWS põem o `aws` (o app aberto pelo Finder não tem o PATH do shell).
    public static let knownPaths = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", NSHomeDirectory() + "/.local/bin/aws", "/usr/bin/aws"]

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = knownPaths
        if let custom = environment["RACKY_AWS_CLI"], !custom.isEmpty { candidates.insert(custom, at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public init(profile: String, executable: URL? = AWSCLI.locate(), runner: Runner? = nil, loginRunner: LoginRunner? = nil) {
        self.profile = profile
        self.executable = executable
        self.loginRunner = loginRunner ?? { executable, arguments, timeout in
            // O Python do CLI abre o navegador por osascript, que falha em app aberto pelo Finder: `BROWSER` manda usar o `open`.
            // Num dia novo o console tem outra sessão e o CLI pergunta "overwrite? (y/n)": a resposta vai pela entrada.
            try await ProcessRunner.run(ProcessRequest(
                executable: executable, arguments: arguments,
                environment: ["AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off", "NO_COLOR": "1", "BROWSER": "/usr/bin/open"], timeout: timeout,
                stdin: Data("y\n".utf8)))
        }
        self.runner = runner ?? { executable, arguments, timeout in
            // Só o necessário: sem paginação interativa, sem cor, sem prompt de região.
            try await ProcessRunner.run(ProcessRequest(
                executable: executable, arguments: arguments,
                environment: ["AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off", "NO_COLOR": "1"], timeout: timeout, maxOutputBytes: 16 << 20))
        }
    }

    /// Erros do CLI que significam "entre de novo" (sessão do `aws login` vencida ou perfil sem credencial).
    static func isSignedOut(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["expiredtoken", "unable to locate credentials", "token has expired", "aws login", "invalidclienttokenid",
                "the config profile", "session has expired", "unrecognizedclient", "error loading sso token", "requestexpired"]
            .contains { text.contains($0) }
    }

    /// Roda e devolve o stdout. `region` nil = a do perfil.
    public func run(_ arguments: [String], region: String? = nil, timeout: Duration = .seconds(60)) async throws -> Data {
        guard let executable else { throw Failure.missing }
        var argv = arguments + ["--profile", profile, "--output", "json", "--no-cli-pager"]
        if let region { argv += ["--region", region] }
        let output = try await runner(executable, argv, timeout)
        guard output.exitCode == 0 else {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSignedOut(message) { throw Failure.signedOut(message) }
            throw Failure.failed(command: arguments.prefix(2).joined(separator: " "), message: String(message.suffix(600)))
        }
        return output.stdout
    }

    /// `run` + JSON decodificado (objeto vazio quando o comando não imprime nada).
    public func json(_ arguments: [String], region: String? = nil, timeout: Duration = .seconds(60)) async throws -> [String: Any] {
        let data = try await run(arguments, region: region, timeout: timeout)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.failed(command: arguments.prefix(2).joined(separator: " "), message: "unexpected output")
        }
        return object
    }

    /// Conta e papel da sessão atual (`sts get-caller-identity`).
    public func identity() async throws -> AWSIdentity {
        let object = try await json(["sts", "get-caller-identity"], timeout: .seconds(30))
        guard let account = object["Account"] as? String, let arn = object["Arn"] as? String else {
            throw Failure.failed(command: "sts get-caller-identity", message: "no account in the answer")
        }
        return AWSIdentity(account: account, arn: arn)
    }

    /// `aws login` (abre o navegador; o usuário confirma lá). A região é gravada no perfil antes, como o guia da AWS pede.
    public func login(region: String, timeout: Duration = .seconds(300)) async throws {
        guard let executable else { throw Failure.missing }
        _ = try await runner(executable, ["configure", "set", "region", region, "--profile", profile], .seconds(20))
        let output: ProcessOutput
        do {
            output = try await loginRunner(executable, ["login", "--region", region, "--profile", profile], timeout)
        } catch ProcessRunnerError.timedOut {
            throw Failure.failed(command: "login", message: "the browser sign-in wasn't confirmed in time. Click Connect AWS to try again.")
        }
        guard output.exitCode == 0 else {
            let text = (output.stderrString + "\n" + output.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(command: "login", message: String(text.suffix(400)))
        }
    }
}

public struct AWSIdentity: Sendable, Equatable {
    public var account: String
    public var arn: String
    public init(account: String, arn: String) { self.account = account; self.arn = arn }
}
