import RackyCore
import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import RackyVZ
import AppKit
import Foundation
import Synchronization

/// Guarda o orquestrador de computadores (F12) para o lançamento do Claude achá-lo: o `TerminalRuntime` nasce antes do Store.
nonisolated final class OrchestratorHolder: Sendable {
    private let box = Mutex<ComputerOrchestrator?>(nil)
    nonisolated var value: ComputerOrchestrator? { box.withLock { $0 } }
    nonisolated func set(_ orchestrator: ComputerOrchestrator) { box.withLock { $0 = orchestrator } }
}

/// F12/F13: a fiação que a T3-04 deixou fora do app. Orquestrador (hub, scheduler, MCP, porta Ask/Full), `app.sock` com o serviço `mcp`,
/// linhas dos computadores na sidebar, progresso das imagens, "Open Docker" e o sweep dos computadores reservados e esquecidos.
extension AppEnvironment {
    /// Cria o orquestrador depois que o Store abriu. Sem o helper `racky` (nem bundle nem `RACKY_HELPER`) não há como o Claude
    /// falar com o app, então nada é injetado e "Subagent computers" fica inerte.
    /// Label `racky.owner` dos containers. Um `RACKY_HOME` isolado (testes, e2e, dev) ganha um owner próprio, derivado do home:
    /// a adoção e o GC de uma instância nunca enxergam os computadores de outra (o app do dono segue com `racky`).
    nonisolated static func computerOwner(_ environment: [String: String]) -> String {
        guard let home = environment["RACKY_HOME"], !home.isEmpty else { return "racky" }
        return "racky-\(BackgroundAgentIdentity.testSuffix(forHome: home))"
    }

    /// Lote concluído: o item vai à fila de atenção do terminal pai (Inbox + notificação do macOS, uma vez); sem atenção ou sem terminal
    /// conhecido, vira um toast com o mesmo texto.
    func batchFinished(_ summary: BatchSummary) {
        Task { if let orchestrator = orchestratorHolder.value { computers.model.setBatches(await orchestrator.batches()) } }
        let contexts = sidebar.attentionContexts()
        let terminal = contexts.filter { $0.value.sessionID == summary.sessionID }.sorted { $0.key.uuidString < $1.key.uuidString }
            .first { $0.value.provider.supportsSubagentComputers }?.key
            ?? contexts.first { $0.value.sessionID == summary.sessionID }?.key
        if let attention, let sessionID = summary.sessionID, let terminal {
            attention.batchFinished(batchID: summary.name, title: summary.notificationTitle, body: summary.notificationBody, sessionID: sessionID, terminalID: terminal)
        } else {
            toasts.show(kind: .success, title: summary.notificationTitle, detail: summary.notificationBody)
        }
    }

    func startOrchestrator(store: RackyStore) async {
        guard flags.isEnabled(.slice3), orchestratorHolder.value == nil, let helper = Self.helperPath(environmentVariables) else { return }
        let root = StorePaths.default(environment: environmentVariables).root
        var config = AppComputerProvisioning.Config(
            runtimeRoot: RuntimeContextLocator.root(environment: environmentVariables, bundleURL: Bundle.main.bundleURL),
            secretsRoot: root.appendingPathComponent("computers", isDirectory: true), owner: Self.computerOwner(environmentVariables))
        // Testes e evidência (RACKY_TEST_RUN): tudo leva `racky.test=1` + `racky.test_run=<id>` e sai com o cleanup do teste.
        if let run = environmentVariables["RACKY_TEST_RUN"], !run.isEmpty {
            config.isTest = true
            config.owner = "test-\(run)"
            config.repositorySuffix = "-test-\(run)"
            config.extraLabels = [RackyLabel.test: "1", "racky.test_run": run]
            if let bridge = environmentVariables["RACKY_COMPUTER_BRIDGE"], !bridge.isEmpty { config.network = bridge }
            config.allowCIDRs = (environmentVariables["RACKY_ALLOW_CIDRS"] ?? "").split(separator: ",").map { String($0) }
        }
        // F29: `boxes_reserve(proxy:)` e `proxy_set` resolvem o nome para o ProxyProfile salvo (segredo no Vault, só para o egress).
        let proxyService = ProxyService(store: store, vault: SecretVault(store: store, keyring: VaultKeyring(backend: SystemKeychainBackend.system())))
        config.resolver = { name, country in
            guard let profile = try await store.proxy(named: name) else { throw ProxyServiceError.unknownProxy(name) }
            var resolved = try await proxyService.egressConfig(for: profile.id)
            if let country, var upstream = resolved.config.upstream { upstream.geoCountry = country; resolved.config.upstream = upstream }
            return resolved
        }
        // Runtime sem Docker (macOS 26+, Apple silicon, build com o entitlement de virtualização): VMs hospedadas neste processo. O
        // Settings › Computers › "Use Docker instead" força o Docker; testes com Docker (`RACKY_TEST_RUN`) ficam sempre no Docker.
        let settingsForRuntime = settings
        let nativeAllowed = environmentVariables["RACKY_TEST_RUN"] == nil && environmentVariables["RACKY_COMPUTER_RUNTIME"] != "docker"
        var nativeRuntime: VZRuntime?
        if nativeAllowed {
            var nativeConfig = VZRuntime.Config(
                appDataRoot: root, secretsRoot: config.secretsRoot, owner: config.owner, runtimeRoot: config.runtimeRoot,
                environment: environmentVariables)
            nativeConfig.allowCIDRs = config.allowCIDRs
            nativeConfig.resolver = config.resolver
            let runtime = VZRuntime(config: nativeConfig)
            nativeRuntime = runtime
            config.native = runtime
            config.forceDocker = { await MainActor.run { settingsForRuntime.settings.computers.forceDocker } }
            if runtime.unavailableReason == nil {
                // VMs e pastas de uma execução anterior já morreram com o processo: limpa antes de qualquer computador novo.
                Task { await runtime.startupSweep() }
            }
        }
        let runtimeInfo = ComputerRuntimeInfo(
            nativeAvailable: nativeRuntime != nil && nativeRuntime?.unavailableReason == nil,
            unavailableReason: nativeRuntime == nil ? nil : nativeRuntime?.unavailableReason.map { "\($0) Computers use Docker." })
        settings.runtimeInfo = runtimeInfo
        // Settings › General › Storage: imagens antigas do computador e cópias de runs substituídos.
        let settingsForStorage = settings
        config.removeOldImages = { await MainActor.run { settingsForStorage.settings.general.oldComputerImages == .delete } }
        let provisioning = AppComputerProvisioning(config: config)
        // BK-12: `runOn == .cloud` nunca cai no Mac. A AWS vai pelo `aws` CLI do usuário; sem a nuvem montada o pedido falha com mensagem clara.
        let settingsForRoute = settings
        let cloud = await makeCloudStack(root: root, config: config)
        await provisioning.setCloudRoute(CloudComputerRoute(
            place: { await MainActor.run { settingsForRoute.cloudActive ? .cloud : .local } },
            provisioning: cloud?.provisioning))
        let wait = environmentVariables["RACKY_ASK_WAIT_S"].flatMap(TimeInterval.init) ?? 45
        let orchestrator = ComputerOrchestrator(
            helperPath: helper, store: store, provisioning: provisioning, runsRoot: root.appendingPathComponent("computers/runs", isDirectory: true),
            waitSeconds: wait, proxies: StoreProxyDirectory(store: store))
        // Reinício do app com Claude e subagentes vivos: as identidades MCP voltam antes de qualquer chamada (só lê o Store).
        await orchestrator.restoreIdentities()
        orchestratorHolder.set(orchestrator)
        // Git de dentro dos computadores (Settings › Computers › Git from computers): o repositório do projeto da sessão, com o token do
        // `gh` do dono. O token só vai para o arquivo 0400 do egress; o gateway aplica a política (push só em feat/*, PR, leitura).
        let settingsForGit = settings
        await orchestrator.scheduler.setGitHubAccess { sessionID in
            guard await MainActor.run(body: { settingsForGit.settings.computers.githubAccess }), let sessionID,
                  let session = try? await store.session(id: sessionID), let projectID = session.projectID,
                  let project = try? await store.project(id: projectID), let remote = project.gitRemoteURL,
                  let repo = GitHubRemoteParser.parse(remote), repo.host == "github.com" else { return nil }
            guard let result = try? await GitHubProcessRunner().run(["auth", "token", "--hostname", "github.com"], in: nil, timeout: .seconds(10)),
                  result.succeeded else { return nil }
            let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : EgressGitHub(token: token, repos: ["\(repo.owner)/\(repo.name)"])
        }
        // O que sai do `work/` quando o computador termina: a escolha da sessão no card, senão o padrão de Settings › Storage.
        let leftoversCenter = orchestrator.approvals, leftoversParents = orchestrator.parents
        await orchestrator.scheduler.setLeftoversPolicy { parent in
            let info = await leftoversParents.info(parent)
            if let chosen = await leftoversCenter.leftovers(parentID: parent, sessionID: info?.sessionID) { return chosen }
            return await MainActor.run { settingsForStorage.settings.general.computerLeftovers }
        }
        // Workers de app (spec subagent-harness): `agent_spawn` abre o terminal do worker pelo workspace; o fim do terminal solta o computador.
        await orchestrator.setWorkerLauncher(WorkspaceWorkerLauncher.make(workspace: workspace, settings: settings, computers: computers.model))
        workspace.onWorkerTerminalEnded = { [weak orchestrator] child, code in
            Task { await orchestrator?.scheduler.workerExited(childID: child, exitCode: code) }
        }
        let toasts = toasts
        let settings = settings
        await orchestrator.start()
        // Postgres que um agente sobe no computador (o smoke): a cada 10 s o app acha, abre a porta e copia as tabelas para datasets.
        await orchestrator.databases.observe { [weak dataHub] list in
            Task { @MainActor in await dataHub?.setComputerDatabases(list) }
        }
        Task.detached { [databases = orchestrator.databases] in
            while !Task.isCancelled {
                await databases.tick()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // T3-07: todos os filhos de um lote terminaram: um item no Inbox e uma notificação (CS-326, AC-429).
        await orchestrator.scheduler.setBatchObserver { [weak self] summary in Task { @MainActor in self?.batchFinished(summary) } }
        await provisioning.setObserver(
            state: { state in
                Task { @MainActor in
                    switch state {
                    case .idle: break
                    case .ready:
                        let native = settings.runtimeInfo.nativeAvailable && !settings.settings.computers.forceDocker
                        settings.dockerStatus = DockerStatusInfo(
                            text: native ? String(localized: "Ready. The computer runtime is installed.", bundle: .module)
                                : String(localized: "Running. Computer images are ready.", bundle: .module))
                    case .failed(let text): settings.dockerStatus = DockerStatusInfo(text: text, stopped: text.hasPrefix(ComputerSetupError.dockerNotRunningMessage))
                    default: settings.dockerStatus = DockerStatusInfo(text: state.label ?? "")
                    }
                }
                Task {
                    // Linhas dos computadores que estão subindo mostram o mesmo progresso (a camada Core já cobre o primeiro quadro).
                    for computer in await orchestrator.hub.allComputers where await computer.state == .provisioning { await computer.setDetail(state.label) }
                }
            },
            problem: { problem in
                if problem == .cloudUnavailable {
                    Task { @MainActor in
                        toasts.show(kind: .error, title: String(localized: "Cloud computers aren't available yet", bundle: .module),
                                    detail: String(localized: "Switch to This Mac in Computers.", bundle: .module))
                    }
                    return
                }
                if case .nativeRuntime = problem {
                    // Sem Docker no meio: não existe "Open Docker"; o texto do Settings traz a causa (download, imagem, entitlement...).
                    Task { @MainActor in
                        settings.dockerStatus = DockerStatusInfo(text: problem.localizedDescription)
                        toasts.show(
                            kind: .error, title: String(localized: "The computer runtime isn't ready", bundle: .module),
                            detail: String(localized: "Subagent computers need the computer runtime. Check Settings › Computers and ask Claude again.", bundle: .module))
                    }
                    return
                }
                Task { @MainActor in
                    settings.dockerStatus = DockerStatusInfo(text: problem.localizedDescription, stopped: true)
                    toasts.show(
                        kind: .error, title: String(localized: "Docker isn't running", bundle: .module),
                        detail: String(localized: "Subagent computers need Docker. Open it and ask Claude again.", bundle: .module),
                        action: ToastAction(.dockerStart, title: String(localized: "Open Docker", bundle: .module)))
                }
            })
        computers.proxyNames = { await StoreProxyDirectory(store: store).names() }
        // Preço por request de cada proxy (Settings › Computers › Proxies): o custo aproximado da aba Computers.
        traffic.proxySource = {
            let profiles = (try? await store.proxies()) ?? []
            return Dictionary(
                profiles.map { ($0.name, TrafficController.ProxyInfo(host: $0.host, pricePerRequestMicros: $0.pricePerRequestMicros)) },
                uniquingKeysWith: { a, _ in a })
        }
        await computers.useOrchestrator(orchestrator)
        computers.startLeftoversSweep()
        computers.startRefreshing()
        // Computadores que seguiram vivos no Docker voltam para o hub (a UI já observa); sem Docker de pé não faz nada.
        Task { await orchestrator.adoptRunning() }
        computerSweeper?.cancel()
        computerSweeper = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                _ = await orchestrator.scheduler.sweep()
            }
        }
    }
}

/// Amostras dos computadores desta instância (label `racky.owner` próprio) para o Insights e a status bar. Detecta o Docker a cada
/// leitura avulsa (só sonda o socket; nunca inicia o Docker) e devolve `nil` quando ele não responde.
struct LazyDockerComputerSource: InsightsComputerSource {
    let owner: String

    func computerSamples() async -> [ContainerSample]? {
        guard let detected = try? await RuntimeDetector().detect() else { return nil }
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(5))
        return await DockerComputerSource(client: client, owner: owner).computerSamples()
    }
}

extension AppEnvironment {
    nonisolated static func computerSource(environment: [String: String]) -> LazyDockerComputerSource {
        LazyDockerComputerSource(owner: computerOwner(environment))
    }
}
