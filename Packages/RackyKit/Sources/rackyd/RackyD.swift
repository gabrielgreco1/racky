import RackyPlatform
import RackyProtocol
import Darwin
import Foundation

/// `rackyd`: daemon de PTY (06 §1). Dois modos de escuta:
/// - LaunchAgent (T1-24, S-01): `--launchd [<nome>]` recebe o socket do launchd com `launch_activate_socket` (nunca `bind`).
/// - Degradado e testes: processo filho do app, `bind` em `AB/run/ptyd-v1.sock` (`$RACKY_HOME/run/ptyd-v1.sock` nos testes).
///
/// Opções: `--socket <caminho>`, `--home <diretório>`, `--idle-exit <segundos>` (0 desliga; padrão 60), `--build <texto>`,
/// `--launchd [<nome>]` (nome da entrada em `Sockets`; padrão `Listeners`), `--socket-fd <n>` (fd de escuta herdado; simula o launchd).
/// Configuração explícita de build do modo ad-hoc de desenvolvimento (S-03): `-Xswiftc -DRACKY_ALLOW_ADHOC_PEERS`.
/// Nunca por variável de ambiente nem argumento. Só tem efeito se o próprio daemon estiver assinado ad-hoc.
#if RACKY_ALLOW_ADHOC_PEERS
    private let allowAdhocPeersBuild = true
#else
    private let allowAdhocPeersBuild = false
#endif

@main
struct RackyD {
    static func main() async {
        // Trampolim do spawn (PTYSpawner): já líder de sessão com o slave no fd 0, pega o tty de controle e vira o programa.
        let launch = CommandLine.arguments
        if launch.count >= 3, launch[1] == PTYSpawner.cttyFlag { PTYSpawner.execWithControllingTTY(Array(launch.dropFirst(2))) }
        PTYSpawner.cttyShim = PTYSpawner.ownExecutablePath()
        signal(SIGPIPE, SIG_IGN)
        // F30: o daemon só encerra por `shutdown` (protocolo) ou ocioso sem sessões. SIGTERM/SIGHUP/SIGINT do app, do shell ou de
        // um `kill` por engano são ignorados. Um handler (e não `SIG_IGN`) para que os filhos PTY voltem ao padrão no `exec`.
        for ignored in [SIGTERM, SIGHUP, SIGINT] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { _ in }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            sigaction(ignored, &action, nil)
        }
        var socket: String?
        var home: String?
        var idleExit = 60
        var build = "1.0 (dev)"
        var listen = DaemonListenSource.bind
        let rest = Array(CommandLine.arguments.dropFirst())
        var arguments = rest.makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--socket": socket = arguments.next()
            case "--home": home = arguments.next()
            case "--idle-exit": idleExit = Int(arguments.next() ?? "") ?? idleExit
            case "--build": build = arguments.next() ?? build
            case "--launchd":
                // Nome opcional: só consome o próximo argumento se não for outra opção.
                var name = LaunchdSocketActivation.defaultSocketName
                if let index = rest.firstIndex(of: "--launchd"), index + 1 < rest.count, !rest[index + 1].hasPrefix("--") {
                    name = rest[index + 1]
                    _ = arguments.next()
                }
                listen = .launchd(name: name)
            case "--socket-fd":
                guard let value = arguments.next(), let descriptor = Int32(value), descriptor >= 0 else {
                    FileHandle.standardError.write(Data("rackyd: --socket-fd needs a descriptor number\n".utf8))
                    Darwin.exit(64)
                }
                listen = .inheritedFD(descriptor)
            default:
                FileHandle.standardError.write(Data("rackyd: unknown option \(argument)\n".utf8))
                Darwin.exit(64)
            }
        }
        let paths = DaemonPaths.resolve(environment: ProcessInfo.processInfo.environment, socketOverride: socket, homeOverride: home)
        // Log em disco do daemon (08 AR-602): `logs/ptyd.jsonl`, redigido antes de gravar; as métricas do daemon vão para o mesmo arquivo.
        let disk = DiskLog(.init(directory: paths.home.appendingPathComponent("logs", isDirectory: true), process: "ptyd"))
        DiskLog.install(disk)
        MetricRecorder.shared.install { sample in
            disk.write(level: .metric, subsystem: LogFacade.Subsystem.ptyd.rawValue, category: "perf", message: sample.name,
                       fields: sample.tags.merging(["value": String(sample.value), "unit": sample.unit]) { a, _ in a })
        }
        let policy = PeerAuthPolicy.resolve(daemon: CodeIdentity.ofCurrentProcess(), allowAdhocDevelopment: allowAdhocPeersBuild)
        let configuration = DaemonConfiguration(
            paths: paths, listen: listen, build: build, idleExit: idleExit > 0 ? .seconds(idleExit) : nil,
            peerAuthenticator: PeerAuthenticator(policy: policy))
        do {
            try await DaemonServer(configuration: configuration).run()
        } catch {
            FileHandle.standardError.write(Data("rackyd: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
