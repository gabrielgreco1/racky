import Darwin
import Dispatch
import Foundation

/// Resultado de uma execução de sonda de shell (sempre com o grupo de processos já encerrado e recolhido).
enum ShellProbeOutcome: Sendable, Equatable {
    case markerSeen
    case timedOut
    case exitedWithoutMarker(status: Int32)
    case cancelled
    case spawnFailed(errno: Int32)
}

/// Executa `shell args…` como líder de sessão (`POSIX_SPAWN_SETSID`) e espera, sem `sleep`, até o marcador final
/// aparecer na saída (PTY oculto ou pipe), o prazo estourar, o processo sair ou o `wakeFD` ficar legível.
/// Em TODOS os caminhos o grupo recebe SIGKILL e o líder é recolhido: nenhum órfão fica para trás (06 §1.7, S-06 2c).
/// Função bloqueante: chame-a por `BlockingIOBridge`. Os bytes lidos são descartados (só o marcador importa);
/// o env sai por arquivo, escolhido pelo chamador.
enum ShellProbe {
    static func run(
        shellPath: String,
        arguments: [String],
        environment: [String: String],
        usePTY: Bool,
        endMarker: [UInt8],
        timeoutMillis: Int,
        wakeFD: Int32
    ) -> ShellProbeOutcome {
        var readFD: Int32 = -1
        var childFD: Int32 = -1
        var slavePath = ""

        if usePTY {
            var master: Int32 = -1
            var slave: Int32 = -1
            var size = winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { return .spawnFailed(errno: errno) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard ttyname_r(slave, &nameBuffer, nameBuffer.count) == 0 else {
                let code = errno
                close(master)
                close(slave)
                return .spawnFailed(errno: code)
            }
            slavePath = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            readFD = master
            childFD = slave
        } else {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return .spawnFailed(errno: errno) }
            readFD = fds[0]
            childFD = fds[1]
        }
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var pid: pid_t = 0
        let spawnError = spawn(
            shellPath: shellPath, arguments: arguments, environment: environment,
            usePTY: usePTY, childFD: childFD, slavePath: slavePath, pid: &pid
        )
        close(childFD) // o pai não segura a ponta do filho: sem isso não há EOF/EIO quando o grupo morre
        if spawnError != 0 {
            close(readFD)
            return .spawnFailed(errno: spawnError)
        }

        let outcome = waitForMarker(readFD: readFD, wakeFD: wakeFD, endMarker: endMarker, timeoutMillis: timeoutMillis)

        // Encerra grupo e sessão inteiros antes de recolher o líder (o zumbi segura o pid, sem reuso).
        killSession(leader: pid)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        close(readFD)

        if case .exitedWithoutMarker = outcome {
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            return .exitedWithoutMarker(status: code)
        }
        return outcome
    }

    /// Shell interativo põe jobs em grupos próprios (job control), então só `kill(-pid)` deixaria órfãos
    /// (ex.: `cmd &` no rc). O líder é líder de sessão: varre todos os processos com o mesmo sid e mata cada um.
    private static func killSession(leader: pid_t) {
        for _ in 0..<5 {
            _ = kill(-leader, SIGKILL)
            var found = false
            let capacity = Int(proc_listallpids(nil, 0))
            if capacity > 0 {
                var pids = [pid_t](repeating: 0, count: capacity + 64)
                let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
                for candidate in pids.prefix(Int(max(bytes, 0))) where candidate > 1 && candidate != leader {
                    if getsid(candidate) == leader {
                        _ = kill(candidate, SIGKILL)
                        found = true
                    }
                }
            }
            if !found { return }
        }
    }

    // MARK: - Espera

    private static func waitForMarker(readFD: Int32, wakeFD: Int32, endMarker: [UInt8], timeoutMillis: Int) -> ShellProbeOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(max(timeoutMillis, 0)) * 1_000_000
        var window: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if elapsed >= budget { return .timedOut }
            let remainingMillis = Int32(min((budget - elapsed + 999_999) / 1_000_000, 1_000))
            var fds = [
                pollfd(fd: readFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, remainingMillis)
            if ready < 0 {
                if errno == EINTR { continue }
                return .exitedWithoutMarker(status: -1)
            }
            if ready == 0 { continue }
            if fds[1].revents & Int16(POLLIN) != 0 { return .cancelled }
            if fds[0].revents != 0 {
                let count = read(readFD, &chunk, chunk.count)
                if count > 0 {
                    window.append(contentsOf: chunk[0..<count])
                    if contains(window, endMarker) { return .markerSeen }
                    if window.count > 64 * 1024 { window.removeFirst(window.count - endMarker.count) }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    return .exitedWithoutMarker(status: 0) // EOF ou EIO do PTY: o grupo acabou
                }
            }
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        var index = 0
        while index <= last {
            if haystack[index] == needle[0] && haystack[index..<(index + needle.count)].elementsEqual(needle) { return true }
            index += 1
        }
        return false
    }

    // MARK: - Spawn

    private static func spawn(
        shellPath: String, arguments: [String], environment: [String: String],
        usePTY: Bool, childFD: Int32, slavePath: String, pid: inout pid_t
    ) -> Int32 {
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        if usePTY {
            // Aberto pelo líder de sessão, sem O_NOCTTY: vira o terminal de controle (necessário para `-i`).
            posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
            posix_spawn_file_actions_adddup2(&actions, 0, 1)
            posix_spawn_file_actions_adddup2(&actions, 0, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, childFD, 1)
            posix_spawn_file_actions_adddup2(&actions, childFD, 2)
        }
        var sigDefault = sigset_t()
        sigfillset(&sigDefault)
        var sigMask = sigset_t()
        sigemptyset(&sigMask)
        posix_spawnattr_setsigdefault(&attributes, &sigDefault)
        posix_spawnattr_setsigmask(&attributes, &sigMask)
        let flags = Int32(POSIX_SPAWN_SETSID) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([shellPath] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        return posix_spawn(&pid, shellPath, &actions, &attributes, argv, envp)
    }
}
