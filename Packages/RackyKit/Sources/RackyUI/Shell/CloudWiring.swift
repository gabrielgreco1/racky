import RackyCore
import RackyDocker
import RackyProtocol
import Foundation

// BK-12 no app: a nuvem do próprio usuário (AWS pelo `aws` CLI e o perfil do `aws login`). Monta o `CloudStack`, liga o Connect AWS,
// mantém a tela com os hosts vivos e o gasto, e encerra tudo ao sair (nenhuma VM fica cobrando à espera da chave morta).
extension AppEnvironment {
    /// `nil` em testes com Docker (`RACKY_TEST_RUN`) ou sem como guardar as chaves: aí `runOn == .cloud` falha com a mensagem de indisponível.
    func makeCloudStack(root: URL, config: AppComputerProvisioning.Config) async -> CloudStack? {
        guard environmentVariables["RACKY_TEST_RUN"] == nil else { return nil }
        let cloudRoot = root.appendingPathComponent("cloud", isDirectory: true)
        guard let keys = try? await CloudKeys.load(in: cloudRoot.appendingPathComponent("keys", isDirectory: true)) else { return nil }
        let settings = settings
        let current = settings.settings.computers.cloud
        let cli = AWSCLI(profile: current.awsProfile)
        let secrets = BoxSecretFiles(root: config.secretsRoot)
        let owner = config.owner
        let stack = CloudStack(
            cli: cli, owner: CloudKeys.installOwner(in: cloudRoot, base: owner), root: cloudRoot, keys: keys, runtimeRoot: config.runtimeRoot,
            caps: Self.caps(current),
            settings: { await MainActor.run { (settings.settings.computers.cloud.region, settings.settings.computers.cloud.maxComputers) } },
            // O reaper olha todas as regiões do catálogo: um host esquecido em outra região também é achado e encerrado.
            regions: { CloudProviderCatalog.aws.regions.map(\.id) },
            acceptedAUP: { _, version in await MainActor.run { settings.settings.computers.cloud.acceptedAUP == version } },
            progress: { _, step in
                Task { @MainActor in
                    settings.cloudProgress = switch step {
                    case .waitingForSSH: String(localized: "Starting a computer in AWS…", bundle: .module)
                    case .buildingImage(let step, let total):
                        total > 0 ? String(localized: "Preparing the computer image in AWS… \(step) of \(total)", bundle: .module)
                            : String(localized: "Preparing the computer image in AWS…", bundle: .module)
                    case .ready: nil
                    }
                }
            },
            make: { access in
                DockerComputerProvisioning(
                    client: access.client, image: (access as? ImagedHostAccess)?.imageTag ?? "", secrets: secrets, owner: owner,
                    network: config.network, resolver: config.resolver, host: access)
            })
        settings.cloudConnect = { [weak settings] in await settings?.connectCloud(cli: cli, stack: stack) }
        settings.cloudStopHost = { [weak settings] id in
            try await stack.stopHost(id)
            settings?.cloudSnapshot = await stack.snapshot()
        }
        settings.cloudShutdown = { await stack.shutdown() }
        // Já conectou antes: confere a sessão em silêncio e, valendo, liga o supervisor (readota, heartbeat e reaper por tag).
        if current.acceptedAUP != nil {
            Task { @MainActor [weak settings] in await settings?.checkCloud(cli: cli, stack: stack) }
        }
        // A tela lê o livro-caixa e os hosts vivos; os tetos mudados em Settings valem na hora.
        Task { @MainActor [weak settings] in
            while let settings {
                settings.cloudSnapshot = await stack.snapshot()
                await stack.updateCaps(Self.caps(settings.settings.computers.cloud))
                try? await Task.sleep(for: .seconds(10))
            }
        }
        return stack
    }

    nonisolated static func caps(_ cloud: AppSettings.Cloud) -> SpendCaps {
        SpendCaps(dailyUSD: Double(cloud.dailyCapUSD), monthlyUSD: Double(cloud.monthlyCapUSD))
    }
}

extension SettingsModel {
    /// Connect AWS: com sessão válida só confirma; sem sessão abre o `aws login` no navegador e espera o usuário.
    func connectCloud(cli: AWSCLI, stack: CloudStack) async {
        guard cli.executable != nil else { cloudConnection = .missingCLI; return }
        cloudConnection = .checking
        if let identity = try? await cli.identity() {
            await connected(identity, stack: stack)
            return
        }
        cloudConnection = .signingIn
        let region = settings.computers.cloud.region
        let login = Task { try await cli.login(region: region) }
        cloudLoginTask = login
        defer { cloudLoginTask = nil }
        do {
            try await login.value
            await connected(try await cli.identity(), stack: stack)
        } catch {
            if login.isCancelled { cloudConnection = .signedOut; return }  // o usuário cancelou o login
            cloudConnection = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Cancela o `aws login` em andamento (o runner mata o processo filho ao cancelar a Task).
    func cancelCloudLogin() { cloudLoginTask?.cancel() }

    /// Abertura do app: só lê a sessão (nunca abre o navegador sozinho).
    func checkCloud(cli: AWSCLI, stack: CloudStack) async {
        guard cli.executable != nil else { cloudConnection = .missingCLI; return }
        cloudConnection = .checking
        if let identity = try? await cli.identity() { await connected(identity, stack: stack) } else { cloudConnection = .signedOut }
    }

    private func connected(_ identity: AWSIdentity, stack: CloudStack) async {
        cloudConnection = .connected(account: identity.account)
        // Conectar é aceitar o uso aceitável da AWS (a linha aparece ao lado do botão).
        if let version = try? await AWSProvider(cli: stack.cli).acceptableUsePolicy().version, settings.computers.cloud.acceptedAUP != version {
            change("Cloud account") { $0.computers.cloud.acceptedAUP = version }
        }
        await stack.start()
        cloudSnapshot = await stack.snapshot()
    }
}
