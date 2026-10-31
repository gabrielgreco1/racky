import RackyCore
import Darwin
import Foundation
import Synchronization

/// Rede de segurança dos testes (F34): o `rackyd` ignora SIGTERM (F30) e não sai ocioso com sessões vivas, então qualquer
/// daemon que o processo de teste subiu e não encerrou ficaria para sempre. Só alcança FILHOS DIRETOS deste processo, com
/// binário `rackyd` e home em `/tmp` (nunca casa por nome sozinho; o daemon do dono do app é filho do launchd).
/// Cópia idêntica em cada alvo de teste que sobe daemons (não há alvo de suporte compartilhado).
nonisolated enum DaemonReaper {
    struct Child { let pid: pid_t, home: String }

    private static let installed = Mutex<Bool>(false)

    /// Varre os daemons filhos ao sair do processo de teste (inclusive os de `TerminalRuntime`/`AppEnvironment`).
    static func installExitSweep() {
        installed.withLock { done in
            guard !done else { return }
            done = true
            atexit { DaemonReaper.reap() }
        }
    }

    private static func normalized(_ path: String) -> String { path.hasPrefix("/private/tmp/") ? String(path.dropFirst("/private".count)) : path }

    /// `rackyd` filhos deste processo cujo home (`--home` ou `RACKY_HOME`) está em `/tmp`; com `home`, só esse.
    static func children(home: URL? = nil) -> [Child] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(getpid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        var found: [Child] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride) where pid > 0 {
            guard let (argv, env) = arguments(of: pid), let first = argv.first, (first as NSString).lastPathComponent == "rackyd" else { continue }
            var path: String?
            if let index = argv.firstIndex(of: "--home"), index + 1 < argv.count { path = argv[index + 1] }
            if path == nil { path = env.first { $0.hasPrefix("RACKY_HOME=") }.map { String($0.dropFirst("RACKY_HOME=".count)) } }
            guard let path, normalized(path).hasPrefix("/tmp/") else { continue }
            if let home, normalized(home.path) != normalized(path) { continue }
            found.append(Child(pid: pid, home: path))
        }
        return found
    }

    /// argv e ambiente de um processo (`KERN_PROCARGS2`).
    private static func arguments(of pid: pid_t) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }  // caminho do executável
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                strings.append(String(decoding: buffer[start ..< index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
    }

    /// SIGKILL nos daemons filhos (todos os de `/tmp`, ou só os do `home`). Síncrono, espera curta.
    static func reap(home: URL? = nil) {
        let victims = children(home: home)
        for child in victims { Darwin.kill(child.pid, SIGKILL) }
        for _ in 0 ..< 100 where victims.contains(where: { Darwin.kill($0.pid, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.02) }
    }

    /// Encerra o daemon do `home` como o app faz (pedido `shutdown` do protocolo), SIGKILL se ele não sair em ~2 s, e apaga o home.
    static func shutdown(home: URL) async {
        installExitSweep()
        let client = PTYClient(configuration: PTYClientConfiguration(socketPath: home.appendingPathComponent("run/ptyd-v1.sock").path, build: "test"))
        let ask = Task { if (try? await client.start()) != nil { try? await client.shutdownDaemon() } }
        let deadline = ContinuousClock.now + .seconds(2)
        while !children(home: home).isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        ask.cancel()
        await client.stop()
        reap(home: home)
        try? FileManager.default.removeItem(at: home)
    }
}
