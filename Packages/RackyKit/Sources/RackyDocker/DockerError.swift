import Foundation

/// Erros tipados do cliente da Engine API (08 AR-114, 07 CS-104/CS-106).
public enum DockerError: Error, Sendable, Equatable {
    /// Nenhum runtime Docker utilizável (socket ausente, recusado ou `_ping` falhou). Mapeia para `docker_unavailable` (CS-104).
    case runtimeUnavailable(String)
    /// Falha de transporte no socket (I/O, EOF no meio de uma resposta).
    case transport(String)
    /// Resposta que não segue HTTP/1.1 ou JSON esperado.
    case malformedResponse(String)
    /// 400/500 e demais status de erro sem tipo próprio.
    case api(status: Int, message: String)
    /// 404: container, imagem, rede, volume ou exec inexistente.
    case notFound(String)
    /// 409: nome em uso, container não está rodando, rede em uso.
    case conflict(String)
    /// A operação passou do prazo. O recurso criado, se existir, é reconciliado por `DockerClient.createContainer` (CS-106).
    case timeout(operation: String)
    /// A tarefa foi cancelada pelo chamador.
    case cancelled
    /// `pull` terminou com erro no stream de progresso.
    case imagePullFailed(String)
    /// `build` terminou com erro no stream de saída.
    case imageBuildFailed(String)
    /// Contexto de build inválido (tar, caminho longo demais, diretório ausente).
    case invalidBuildContext(String)
    /// O daemon não fez o upgrade da conexão para o stream do exec.
    case execNotHijacked(status: Int)
    /// `signalGroup`/`terminate` num exec criado sem `killableGroup`.
    case execNotKillable
    /// A imagem esperada não existe e nenhum caminho (digest, build local) foi configurado.
    case imageUnavailable(String)

    /// Prazo estourado ou cancelamento: operações que criam recursos reconciliam nesse caso (CS-106).
    public var isInterruption: Bool {
        switch self {
        case .timeout, .cancelled: true
        default: false
        }
    }

    public var isNotFound: Bool { if case .notFound = self { true } else { false } }
    public var isConflict: Bool { if case .conflict = self { true } else { false } }
    /// Docker parado ou ausente (CS-104).
    public var isRuntimeUnavailable: Bool { if case .runtimeUnavailable = self { true } else { false } }

    /// Razão curta para o pai em `boxes_reserve` quando o Docker não responde (`docker_unavailable`).
    public var reserveReason: String? { isRuntimeUnavailable ? "docker_unavailable" : nil }

    static func from(status: Int, body: Data, context: String) -> DockerError {
        let message = Self.message(from: body) ?? "HTTP \(status)"
        switch status {
        case 404: return .notFound("\(context): \(message)")
        case 409: return .conflict("\(context): \(message)")
        default: return .api(status: status, message: "\(context): \(message)")
        }
    }

    static func message(from body: Data) -> String? {
        struct Payload: Decodable { let message: String }
        if let payload = try? JSONDecoder().decode(Payload.self, from: body) { return payload.message }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
