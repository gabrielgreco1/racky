import Foundation

// Agente do Racky (backlog 25). Mora em `~/Racky/agents/<nome>/`; o Racky gera a versão de cada CLI na hora de lançar e nunca
// escreve em `~/.claude`, `~/.codex` nem `~/.config/opencode`. Nenhum valor de variável do cofre aparece aqui: só o nome do segredo.

/// Computador pronto do agente: tela, memória, proxy/país e pacotes.
public struct AgentComputerPreset: Codable, Sendable, Equatable {
    public var screen: Bool
    public var memoryMB: Int
    public var proxyCountry: String?
    public var proxyRegion: String?
    public var packages: [String]

    public init(screen: Bool = false, memoryMB: Int = 2048, proxyCountry: String? = nil, proxyRegion: String? = nil, packages: [String] = []) {
        self.screen = screen; self.memoryMB = memoryMB; self.proxyCountry = proxyCountry; self.proxyRegion = proxyRegion; self.packages = packages
    }
}

/// Variável do cofre que entra no env do computador do agente (nunca no prompt).
public struct AgentVariable: Codable, Sendable, Equatable, Identifiable {
    public var envName: String
    public var secretName: String
    public var id: String { envName }
    public init(envName: String, secretName: String) { self.envName = envName; self.secretName = secretName }
}

/// Site logado: o item do cofre guarda cookies e storage cifrados; carregado no computador antes de o agente começar.
public struct AgentSite: Codable, Sendable, Equatable, Identifiable {
    public var host: String
    public var secretName: String
    public var savedAt: Date?
    public var expiresAt: Date?
    public var id: String { host }
    public init(host: String, secretName: String, savedAt: Date? = nil, expiresAt: Date? = nil) {
        self.host = host; self.secretName = secretName; self.savedAt = savedAt; self.expiresAt = expiresAt
    }
    /// Sessão vencida vira pedido no Inbox.
    public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

public enum AgentAvatarKind: String, Codable, Sendable { case generated, photo }

public struct AgentAvatar: Codable, Sendable, Equatable {
    public var kind: AgentAvatarKind
    /// Variação do avatar gerado; "Regerar" soma 1.
    public var variant: Int
    /// Nome do arquivo da foto dentro da pasta do agente (`photo.png`).
    public var photoFile: String?
    public init(kind: AgentAvatarKind = .generated, variant: Int = 0, photoFile: String? = nil) {
        self.kind = kind; self.variant = variant; self.photoFile = photoFile
    }
}

public struct AgentDefinition: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var instructions: String
    public var model: String?
    public var tools: [String]
    public var skills: [String]
    /// Jeito de falar, usado nos resumos e no diário.
    public var tone: String
    public var avatar: AgentAvatar
    public var computer: AgentComputerPreset?
    public var variables: [AgentVariable]
    public var sites: [AgentSite]
    public var createdAt: Date
    public var updatedAt: Date
    public var id: String { name }

    public init(
        name: String, description: String = "", instructions: String = "", model: String? = nil, tools: [String] = [], skills: [String] = [],
        tone: String = "", avatar: AgentAvatar = AgentAvatar(), computer: AgentComputerPreset? = nil, variables: [AgentVariable] = [],
        sites: [AgentSite] = [], createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.name = name; self.description = description; self.instructions = instructions; self.model = model; self.tools = tools
        self.skills = skills; self.tone = tone; self.avatar = avatar; self.computer = computer; self.variables = variables
        self.sites = sites; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Nome seguro como nome de pasta e de arquivo (sem separador, sem `..`).
    public static func isValidName(_ name: String) -> Bool {
        name.count <= 64 && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil && !name.contains("..")
    }
}

/// Anexo fixo: o agente o recebe em toda tarefa.
public enum AgentAttachmentKind: String, Codable, Sendable, CaseIterable { case session, computer, dataset, spreadsheet, file }

public struct AgentAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: AgentAttachmentKind
    public var title: String
    /// Id da sessão/computer/dataset, ou caminho do arquivo/planilha.
    public var reference: String
    public init(id: UUID = UUID(), kind: AgentAttachmentKind, title: String, reference: String) {
        self.id = id; self.kind = kind; self.title = title; self.reference = reference
    }
}

public struct AgentAttachmentManifest: Codable, Sendable, Equatable {
    public var attachments: [AgentAttachment]
    public init(attachments: [AgentAttachment] = []) { self.attachments = attachments }

    public mutating func add(_ attachment: AgentAttachment) {
        if let i = attachments.firstIndex(where: { $0.kind == attachment.kind && $0.reference == attachment.reference }) {
            attachments[i] = attachment
        } else {
            attachments.append(attachment)
        }
    }
    public mutating func remove(id: UUID) { attachments.removeAll { $0.id == id } }

    /// Trecho do prompt com os anexos da tarefa. Arquivos e planilhas que sumiram são marcados, não omitidos.
    public func promptSection(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        guard !attachments.isEmpty else { return "" }
        var lines = ["Fixed attachments for every task:"]
        for a in attachments {
            let missing = (a.kind == .file || a.kind == .spreadsheet) && !fileExists(a.reference)
            lines.append("- \(a.kind.rawValue): \(a.title) (\(a.reference))\(missing ? " [file missing]" : "")")
        }
        return lines.joined(separator: "\n")
    }
}
