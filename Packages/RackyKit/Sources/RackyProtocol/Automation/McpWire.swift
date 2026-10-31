import Foundation

/// Segundo frame de uma conexão do serviço `mcp` de `app.sock` (o primeiro é o `AppSockHello`): quem é o filho.
///
/// O helper `racky mcp --child <id> --capability <token>` abre UMA conexão por requisição JSON-RPC (assim chamadas longas,
/// como `help_wait`, não bloqueiam as outras do mesmo filho). A identidade vem da configuração por filho do `mcpServers`
/// inline (S-08), nunca de argumento de ferramenta; `capability` é o token de lançamento, que não aparece em schema algum.
/// O frame seguinte é a mensagem JSON-RPC crua; a resposta é o frame JSON-RPC (ou nenhum, para notificações).
public struct McpIdentity: Codable, Sendable, Equatable {
    public var child: String
    public var capability: String

    public init(child: String, capability: String) {
        self.child = child
        self.capability = capability
    }
}
