import Foundation
import ServiceManagement

/// Estado do registro do LaunchAgent (espelha `SMAppService.Status`, sem depender do framework nos testes).
public enum BackgroundAgentStatus: Sendable, Equatable {
    case notRegistered
    /// O `SMAppService` devolve `notFound` também antes do primeiro `register()` (S-01): só é "ausente de verdade" se o plist não está no bundle.
    case notFound
    case enabled
    /// O registro existe mas o usuário ainda não permitiu o item em Ajustes do Sistema › Itens de Início.
    case requiresApproval
}

public protocol BackgroundAgentService: Sendable {
    var status: BackgroundAgentStatus { get }
    func register() throws
    func unregister() throws
    /// Abre Ajustes do Sistema › Geral › Itens de Início. Só por ação explícita do usuário (botão "Allow in Login Items").
    func openLoginItemsSettings()
}

/// `SMAppService.agent(plistName:)` com o plist embutido em `Contents/Library/LaunchAgents/`.
public struct SMBackgroundAgentService: BackgroundAgentService {
    private let plistName: String

    public init(plistName: String) {
        self.plistName = plistName
    }

    private var service: SMAppService { SMAppService.agent(plistName: plistName) }

    public var status: BackgroundAgentStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
    public func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
