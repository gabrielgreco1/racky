import RackyCore
import RackyProtocol
import Foundation

/// Página Computers › onde rodar (BK-12, P27): local ou nuvem própria, provedor, região, tetos e links. Tudo salva na hora (03 §14.1).
extension SettingsModel {
    var cloudProvider: CloudProviderInfo { CloudProviderCatalog.provider(settings.computers.cloud.provider) ?? CloudProviderCatalog.aws }

    func registerCloudActions(in registry: ActionRegistry) throws {
        try registry.register(.computersRunOn) { [unowned self] arg in
            guard let raw = arg.value, let target = AppSettings.ComputerRunTarget(rawValue: raw) else {
                throw ActionError.failed(.computersRunOn, message: "expected local or cloud")
            }
            change("Where computers run") { $0.computers.runOn = target }
            return target.rawValue
        }
        try registry.register(.computersWhereToggle) { [unowned self] _ in
            computersWhereOpen.toggle()
            return computersWhereOpen ? "open" : "closed"
        }
        try registry.register(.computersCloudProvider) { [unowned self] arg in
            guard let id = arg.value, let provider = CloudProviderCatalog.provider(id) else {
                throw ActionError.failed(.computersCloudProvider, message: "unknown provider")
            }
            guard provider.available else {
                throw ActionError.failed(.computersCloudProvider, message: String(localized: "\(provider.name) is coming soon.", bundle: .module))
            }
            change("Cloud provider") { settings in
                settings.computers.cloud.provider = provider.id
                if !provider.regions.contains(where: { $0.id == settings.computers.cloud.region }), let first = provider.regions.first {
                    settings.computers.cloud.region = first.id
                }
            }
            return provider.id
        }
        try registry.register(.computersCloudRegion) { [unowned self] arg in
            guard let id = arg.value, cloudProvider.regions.contains(where: { $0.id == id }) else {
                throw ActionError.failed(.computersCloudRegion, message: "unknown region")
            }
            change("Cloud region") { $0.computers.cloud.region = id }
            return id
        }
        try registry.register(.computersCloudLimits) { [unowned self] arg in
            guard let raw = arg.value, let update = Self.limitUpdate(raw, current: settings.computers.cloud) else {
                throw ActionError.failed(.computersCloudLimits, message: "expected daily=<n>, monthly=<n>, max=<n> or daily+/daily-…")
            }
            change("Cloud limits") { $0.computers.cloud = update }
            let c = settings.computers.cloud
            return "daily=\(c.dailyCapUSD) monthly=\(c.monthlyCapUSD) max=\(c.maxComputers)"
        }
        try registry.register(
            .computersCloudConnect,
            enablement: { [unowned self] in
                // Em `signingIn` o botão segue ativo: clicar de novo cancela o `aws login` em andamento.
                if cloudConnection == .checking { return .disabled(reason: String(localized: "Waiting for your browser sign-in…", bundle: .module)) }
                return .enabled
            }
        ) { [unowned self] _ in
            guard let cloudConnect else { throw ActionError.failed(.computersCloudConnect, message: "cloud isn't wired") }
            if cloudConnection == .signingIn {
                cancelCloudLogin()
                return cloudConnection.summary
            }
            await cloudConnect()
            if case .failed(let message) = cloudConnection { throw ActionError.failed(.computersCloudConnect, message: message) }
            return cloudConnection.summary
        }
        try registry.register(
            .computersCloudSave,
            enablement: { [unowned self] in
                cloudConnection.isConnected ? .enabled : .disabled(reason: String(localized: "Connect your AWS account first.", bundle: .module))
            }
        ) { [unowned self] _ in
            guard cloudConnection.isConnected else {
                throw ActionError.failed(.computersCloudSave, message: String(localized: "Connect your AWS account first.", bundle: .module))
            }
            change("Cloud computers on") { $0.computers.cloud.confirmed = true }
            cloudEditing = false
            return "saved"
        }
        try registry.register(.computersCloudEdit) { [unowned self] _ in
            cloudEditing = true
            return "editing"
        }
        try registry.register(.computersCloudCancel) { [unowned self] _ in
            cloudEditing = false
            if !settings.computers.cloud.confirmed { change("Where computers run") { $0.computers.runOn = .local } }
            return settings.computers.runOn.rawValue
        }
        try registry.register(.computersCloudStopHost) { [unowned self] arg in
            guard let id = arg.value, let cloudStopHost else { throw ActionError.failed(.computersCloudStopHost, message: "expected a host id") }
            do { try await cloudStopHost(id) } catch {
                throw ActionError.failed(.computersCloudStopHost, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            return id
        }
        try registry.register(.computersCloudOpenLink) { [unowned self] arg in
            guard let raw = arg.value, let link = cloudProvider.links.first(where: { $0.kind.rawValue == raw }) else {
                throw ActionError.failed(.computersCloudOpenLink, message: "expected console, pricing or setup")
            }
            openURL(link.url)
            return link.url.absoluteString
        }
    }

    /// `daily=12`, `monthly=80`, `max=4` (valor exato) ou `daily+`/`max-` (um passo). Fora do intervalo fica no limite.
    static func limitUpdate(_ raw: String, current: AppSettings.Cloud) -> AppSettings.Cloud? {
        var cloud = current
        let key: String
        let value: (Int, Int) -> Int  // (atual, passo) -> novo
        if let eq = raw.firstIndex(of: "=") {
            key = String(raw[..<eq])
            guard let n = Int(raw[raw.index(after: eq)...]) else { return nil }
            value = { _, _ in n }
        } else if raw.hasSuffix("+") || raw.hasSuffix("-") {
            key = String(raw.dropLast())
            let sign = raw.hasSuffix("+") ? 1 : -1
            value = { now, step in now + sign * step }
        } else {
            return nil
        }
        switch key {
        case "daily": cloud.dailyCapUSD = value(cloud.dailyCapUSD, step(cloud.dailyCapUSD)).clamped(AppSettings.Cloud.dailyCapRange)
        case "monthly": cloud.monthlyCapUSD = value(cloud.monthlyCapUSD, monthlyStep(cloud.monthlyCapUSD)).clamped(AppSettings.Cloud.monthlyCapRange)
        case "max": cloud.maxComputers = value(cloud.maxComputers, 1).clamped(AppSettings.Cloud.maxComputersRange)
        default: return nil
        }
        return cloud
    }

    /// Passo do teto: 1 até 10, 5 até 50, 10 depois (um clique sempre muda algo que importa).
    private static func step(_ value: Int) -> Int { value < 10 ? 1 : value < 50 ? 5 : 10 }
    /// Mensal: 5 até 50, 10 até 200, 50 depois.
    private static func monthlyStep(_ value: Int) -> Int { value <= 50 ? 5 : value <= 200 ? 10 : 50 }
}

private extension Int {
    func clamped(_ range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// Sessão da conta na nuvem (o `aws login` do perfil do app).
enum CloudConnectionState: Equatable, Sendable {
    case unknown
    case checking
    /// Navegador aberto esperando o usuário confirmar.
    case signingIn
    case connected(account: String)
    case signedOut
    case missingCLI
    case failed(String)

    var isConnected: Bool { if case .connected = self { true } else { false } }

    var summary: String {
        switch self {
        case .unknown: "unknown"
        case .checking: "checking"
        case .signingIn: "signing-in"
        case .connected(let account): "connected \(account)"
        case .signedOut: "signed-out"
        case .missingCLI: "missing-cli"
        case .failed(let message): "failed: \(message)"
        }
    }
}
