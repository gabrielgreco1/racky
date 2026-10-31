import RackyPlatform
import RackyStore
import AppKit

/// Ciclo de vida AppKit da casca (00 T5): cria o `MainWindowController` e o menu principal.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let env = AppEnvironment()
    private var windowController: MainWindowController?
    private let log = LogFacade(.app, category: "lifecycle")
    private var termination: ExternalTerminationSignals?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let bootPerf = Perf.begin(.boot)
        log.publicInfo("launch")
        // Uma instância por pasta de dados: duas janelas no mesmo PTY brigam pelo tamanho e o Claude redesenha para a largura da
        // outra (texto sobreposto e duplicado). O lock é da pasta de dados: uma cópia de teste com `RACKY_HOME` próprio não
        // impede o app do dono (e vice-versa). A segunda ativa a dona do lock e sai antes de tocar no daemon ou no store.
        if let owner = Self.acquireInstanceLock(environment: ProcessInfo.processInfo.environment) {
            NSRunningApplication(processIdentifier: owner)?.activate()
            log.publicInfo("another instance owns this data folder: yielding to it")
            exit(0)
        }
        // Daqui em diante esta é a dona da pasta: quem ainda escuta em `app.sock` é a instância anterior saindo (F41).
        env.ownsInstanceLock = true
        if env.headless { MainWindowController.invisibleForTests = true }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Telas de fixture (dev e evidência) não leem nem gravam o frame salvo do usuário.
        env.restorePending = true
        let controller = MainWindowController(env: env, autosaveName: env.fixture == nil ? "workspace" : nil)
        windowController = controller
        env.lifecycle.dependencies.showWindow = { [weak controller] in controller?.present(activate: true) }
        env.lifecycle.dependencies.hideWindow = { [weak controller] in controller?.hide() }
        if !env.headless { NSApp.mainMenu = MainMenu.build(registry: env.registry) }
        // Com a automação ligada o app abre sem tirar o foco de quem o lançou (`open -g`).
        controller.present(activate: !env.automationEnabled && !env.headless)
        bootPerf.end()  // do início do `applicationDidFinishLaunching` até a janela estar na tela (AR-605)
        Task { await env.start() }
        let signals = ExternalTerminationSignals { [weak self] number in
            self?.log.info("received signal \(number): leaving the agents running")
            self?.env.lifecycle.externalTerminationRequested()
        }
        signals.install()
        termination = signals
    }

    /// `nil`: esta instância é a dona da pasta de dados; senão, o pid da dona.
    static func acquireInstanceLock(environment: [String: String]) -> pid_t? {
        guard Bundle.main.bundleURL.pathExtension == "app", environment["RACKY_SCREEN"] == nil else { return nil }
        return InstanceLock.acquire(runDirectory: StorePaths.default(environment: environment).root.appendingPathComponent("run", isDirectory: true))
    }

    /// ⌘Q (T1-24): a política decide entre sair, manter os agentes em segundo plano ou perguntar no overlay da janela.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        env.lifecycle.shouldTerminate { shouldQuit in
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        env.shutdownSync()
    }

    /// Fechar a janela com agente vivo não encerra o app: ele passa a accessory e o ícone da barra de menus fica (06 §1.6).
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if env.lifecycle.shouldStayAfterLastWindowClosed {
            env.lifecycle.enterBackground()
            return false
        }
        return true
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { env.lifecycle.leaveBackground() }
        return true
    }
}
