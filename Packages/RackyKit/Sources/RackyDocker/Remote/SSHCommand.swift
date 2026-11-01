import RackyPlatform
import Foundation

public enum SSHConfigError: Error, Sendable, Equatable {
    case invalidField(String)
    case insecureFile(path: String, mode: Int)
    case missingFile(String)
}

/// Como falar com a VM por SSH. Sem agente, sem senha, sem `known_hosts` do usuário: a chave do host vem do provedor
/// (chave de host gerada pelo app e entregue por cloud-init) e o SSH recusa qualquer outra (`StrictHostKeyChecking=yes`).
public struct SSHEndpoint: Sendable, Equatable {
    public var user: String
    public var host: String
    public var port: Int
    /// Chave privada (0600) só deste host.
    public var identityFile: URL
    /// Arquivo no formato `known_hosts` com UMA linha (ver `KnownHosts`).
    public var knownHostsFile: URL
    public var remoteDockerSocket: String

    public init(user: String, host: String, port: Int = 22, identityFile: URL, knownHostsFile: URL, remoteDockerSocket: String = "/var/run/docker.sock") {
        self.user = user; self.host = host; self.port = port; self.identityFile = identityFile; self.knownHostsFile = knownHostsFile
        self.remoteDockerSocket = remoteDockerSocket
    }

    /// Recusa o que viraria opção do `ssh` (argv injection) ou quebraria o `user@host`.
    public func validate() throws {
        func ok(_ value: String, extra: String = "") -> Bool {
            !value.isEmpty && value.count <= 253 && !value.hasPrefix("-")
                && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_:".contains($0) || extra.contains($0)) }
        }
        guard ok(user) else { throw SSHConfigError.invalidField("user") }
        guard ok(host) else { throw SSHConfigError.invalidField("host") }
        guard (1 ... 65535).contains(port) else { throw SSHConfigError.invalidField("port") }
        guard remoteDockerSocket.hasPrefix("/"), !remoteDockerSocket.contains(":"), !remoteDockerSocket.contains(" ") else {
            throw SSHConfigError.invalidField("remoteDockerSocket")
        }
    }

    /// A chave só pode ser lida pelo dono; senão o `ssh` recusa (e nós também, antes de abrir qualquer conexão).
    public func validateFiles() throws {
        let fm = FileManager.default
        for file in [identityFile, knownHostsFile] where !fm.fileExists(atPath: file.path) { throw SSHConfigError.missingFile(file.path) }
        let mode = ((try? fm.attributesOfItem(atPath: identityFile.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
        guard mode & 0o077 == 0 else { throw SSHConfigError.insecureFile(path: identityFile.path, mode: mode) }
    }
}

/// Monta os `argv` do `/usr/bin/ssh` (puro, testável). Um processo mestre (`-M`) leva o encaminhamento do socket do Docker;
/// os `-L` de cada computador e o heartbeat entram pelo mesmo mestre (`-S`), sem nova autenticação.
public enum SSHCommand {
    public static let executable = "/usr/bin/ssh"

    static func common(_ endpoint: SSHEndpoint, control: String) -> [String] {
        [
            "-S", control,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(endpoint.knownHostsFile.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "LogLevel=ERROR",
            "-i", endpoint.identityFile.path,
            "-p", String(endpoint.port),
        ]
    }

    private static func destination(_ endpoint: SSHEndpoint) -> String { "\(endpoint.user)@\(endpoint.host)" }

    /// Mestre: sem comando remoto (`-N`), cai se um encaminhamento falhar, detecta rede morta em ~45 s.
    public static func master(_ endpoint: SSHEndpoint, localSocket: String, control: String) -> [String] {
        ["-N", "-M", "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=15",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "StreamLocalBindUnlink=yes", "-o", "StreamLocalBindMask=0177"]
            + common(endpoint, control: control)
            + ["-L", "\(localSocket):\(endpoint.remoteDockerSocket)", destination(endpoint)]
    }

    /// `ssh -O forward`: a porta publicada no loopback da VM aparece em `127.0.0.1:<localPort>` no Mac (só loopback).
    public static func forward(_ endpoint: SSHEndpoint, localPort: Int, remotePort: Int, control: String, cancel: Bool = false) -> [String] {
        ["-O", cancel ? "cancel" : "forward", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)"] + common(endpoint, control: control) + [destination(endpoint)]
    }

    /// `ssh -O check|exit`.
    public static func control(_ endpoint: SSHEndpoint, operation: String, control: String) -> [String] {
        ["-O", operation] + common(endpoint, control: control) + [destination(endpoint)]
    }

    /// Comando remoto fixo pelo mestre (heartbeat). `command` vem do app, nunca do agente.
    public static func remote(_ endpoint: SSHEndpoint, control: String, command: String) -> [String] {
        ["-o", "ConnectTimeout=10"] + common(endpoint, control: control) + [destination(endpoint), "--", command]
    }
}

/// Linha de `known_hosts` e chaves do host: o app gera a chave do host (ed25519) e a entrega por cloud-init, então sabe a pública antes
/// de a VM existir; nada de "trust on first use".
public enum KnownHosts {
    /// `host ssh-ed25519 AAAA...` (porta diferente de 22 vira `[host]:porta`). `publicKey` = `tipo base64` (sem comentário).
    public static func line(host: String, port: Int = 22, publicKey: String) throws -> String {
        let parts = publicKey.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("ssh-") || parts[0].hasPrefix("ecdsa-"), Data(base64Encoded: parts[1]) != nil else {
            throw SSHConfigError.invalidField("publicKey")
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "," || $0 == "*" || $0 == "?" || $0 == "!" || $0 == "|" }) else {
            throw SSHConfigError.invalidField("host")
        }
        return "\(port == 22 ? host : "[\(host)]:\(port)") \(parts[0]) \(parts[1])\n"
    }

    @discardableResult
    public static func write(host: String, port: Int = 22, publicKey: String, to file: URL) throws -> URL {
        try Data(try line(host: host, port: port, publicKey: publicKey).utf8).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
        return file
    }
}

/// Par de chaves ed25519 efêmero por host (`ssh-keygen`, local, sem rede). A pública vai no cloud-init (`authorized_keys` do usuário
/// `racky`); a privada fica 0600 numa pasta 0700 e é apagada com o host.
public enum SSHKeyPair {
    public struct Generated: Sendable, Equatable {
        public var privateKey: URL
        public var publicKey: String
    }

    public static func generate(in directory: URL, name: String = "id_ed25519", comment: String = "racky") async throws -> Generated {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        try? fm.removeItem(at: file)
        try? fm.removeItem(atPath: file.path + ".pub")
        let output = try await ProcessRunner.run(ProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", file.path], timeout: .seconds(20)))
        guard output.exitCode == 0, let pub = try? String(contentsOfFile: file.path + ".pub", encoding: .utf8) else {
            throw SSHConfigError.invalidField("ssh-keygen falhou")
        }
        chmod(file.path, 0o600)
        let fields = pub.split(separator: " ")
        guard fields.count >= 2 else { throw SSHConfigError.invalidField("chave pública") }
        return Generated(privateKey: file, publicKey: "\(fields[0]) \(fields[1])")
    }
}
