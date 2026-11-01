import RackyProtocol
import Darwin
import Foundation

struct SpawnedPTY: Sendable {
    var master: Int32
    var pid: pid_t
}

/// Cria o PTY e lança o processo com `setsid` (líder de sessão e de grupo: `pgid == pid`) sem `fork` do processo
/// multithread do daemon: `posix_spawn` com `POSIX_SPAWN_SETSID`, o slave aberto por caminho e `POSIX_SPAWN_CLOEXEC_DEFAULT`
/// (nenhum fd do daemon vaza para o filho).
///
/// No macOS abrir o slave NÃO faz dele o tty de controle (no Linux faz): sem `TIOCSCTTY` o processo ficava sem tty de controle
/// (`ps` mostra `??`), o kernel não entregava SIGWINCH no resize e o Claude nunca redesenhava na largura nova; ⌃C/⌃Z do
/// terminal também não viravam sinal. O `posix_spawn` não tem ação para isso, então o filho é o próprio `rackyd` no modo
/// trampolim (`--exec-with-ctty`): faz `ioctl(0, TIOCSCTTY)` e `execve` do programa, no mesmo pid.
enum PTYSpawner {
    static let cttyFlag = "--exec-with-ctty"
    /// Caminho do próprio executável (o trampolim). `nil`: lança o programa direto (sem tty de controle).
    nonisolated(unsafe) static var cttyShim: String?  // SAFETY: gravado uma vez no início do main, antes de qualquer spawn; depois só leitura.

    static func ownExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().path
        return access(path, X_OK) == 0 ? path : nil
    }

    /// Modo trampolim: `[programa, argv0, argv1...]`. Só chamadas seguras antes do `execve`; em falha, sai com 127.
    static func execWithControllingTTY(_ arguments: [String]) -> Never {
        _ = ioctl(0, TIOCSCTTY, 0)
        let path = arguments[0]
        var cArgv: [UnsafeMutablePointer<CChar>?] = arguments.dropFirst().map { strdup($0) }
        cArgv.append(nil)
        execve(path, cArgv, environ)
        let message = "rackyd: exec \(path) failed: \(String(cString: strerror(errno)))\n"
        _ = message.withCString { write(2, $0, strlen($0)) }
        _exit(127)
    }

    static func spawn(argv: [String], cwd: String, env: [String: String], cols: UInt16, rows: UInt16) throws(DaemonError) -> SpawnedPTY {
        guard let first = argv.first else { throw DaemonError(.badRequest, "argv must not be empty") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DaemonError(.spawnFailed, "cwd does not exist", errnoValue: ENOENT, path: cwd)
        }
        guard let executable = resolve(first, path: env["PATH"]) else {
            throw DaemonError(.spawnFailed, "executable not found", errnoValue: ENOENT, path: first)
        }

        // `posix_openpt` + `O_NOCTTY` e o slave NUNCA aberto aqui: o daemon do launchd é líder de sessão sem tty de controle, e
        // o `openpty` abria o slave nele, o que no macOS dá aquele tty ao DAEMON. O filho ficava sem tty de controle (sem
        // SIGWINCH no resize, sem ⌃C/⌃Z como sinal). Só o filho abre o slave, já líder de sessão nova.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw DaemonError(.spawnFailed, "posix_openpt failed", errnoValue: errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            let failure = errno
            close(master)
            throw DaemonError(.spawnFailed, "pty setup failed", errnoValue: failure)
        }
        let name = Array(UnsafeBufferPointer(start: slaveName, count: strlen(slaveName) + 1))
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        var attributes = termios()
        if tcgetattr(master, &attributes) == 0 {
            attributes.c_iflag |= tcflag_t(IUTF8)
            _ = tcsetattr(master, TCSANOW, &attributes)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        var spawnAttributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&spawnAttributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&spawnAttributes, &mask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&spawnAttributes, Int16(flags))

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        // Com o trampolim: `rackyd --exec-with-ctty <executável> <argv...>`; o argv do programa chega intacto.
        let shim = cttyShim.flatMap { access($0, X_OK) == 0 ? $0 : nil }
        let spawnPath = shim ?? executable
        let spawnArgv = shim.map { [$0, cttyFlag, executable] + argv } ?? argv
        var cArgv: [UnsafeMutablePointer<CChar>?] = spawnArgv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for pointer in cArgv { free(pointer) }
            for pointer in cEnv { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, spawnPath, &actions, &spawnAttributes, cArgv, cEnv)
        guard result == 0 else {
            close(master)
            throw DaemonError(.spawnFailed, "posix_spawn failed", errnoValue: result, path: executable)
        }
        return SpawnedPTY(master: master, pid: pid)
    }

    static func resolve(_ name: String, path: String?) -> String? {
        if name.contains("/") { return access(name, X_OK) == 0 ? name : nil }
        let search = path ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in search.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }
}
