import RackyPlatform
import RackyProtocol
import Darwin
import Foundation

/// Cliente de teste do peer auth (T1-07): conecta no socket do daemon, tenta o `hello` e imprime o desfecho numa linha
/// (`ACCEPTED`, `REJECTED <code>` ou `CLOSED`). Não é produto: os testes o copiam e o assinam com identidades diferentes.
/// Uso: `peerprobe <socket>`.
@main
struct PeerProbe {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: peerprobe <socket>\n".utf8))
            Darwin.exit(64)
        }
        let outcome: String
        do {
            let connection = try await UDSClient.connect(path: CommandLine.arguments[1])
            let framed = FramedConnection(connection)
            var handshake = ClientHandshake(client: ClientInfo(kind: .app, build: "peerprobe"))
            // O daemon recusado pode fechar antes do `hello` chegar: ignora a falha de escrita e lê a resposta.
            try? await framed.send(.control(.request(handshake.makeHello(id: 1))))
            switch try await framed.receive() {
            case .control(.reply(.error(_, let error))): outcome = "REJECTED \(error.code.rawValue)"
            case .some: outcome = "ACCEPTED"
            case nil: outcome = "CLOSED"
            }
            await framed.close()
        } catch {
            outcome = "ERROR \(error)"
        }
        FileHandle.standardOutput.write(Data((outcome + "\n").utf8))
    }
}
