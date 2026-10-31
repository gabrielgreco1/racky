import Darwin
import Foundation
import Testing
@testable import RackyPlatform

/// Dirs temporários e shells sintéticos para os testes. Nenhum valor de segredo real aparece aqui.
private final class Sandbox: @unchecked Sendable { // SAFETY: imutável após init; só guarda uma URL
    let root: URL
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abenv-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var runDir: URL { root.appendingPathComponent("run", isDirectory: true) }
    func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    @discardableResult
    func script(_ name: String, _ body: String) -> String {
        let url = root.appendingPathComponent(name)
        try? ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    func write(_ name: String, _ body: String) {
        try? body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }

    func config(
        shell: String, extra: [String: String] = [:],
        interactive: Duration = .seconds(5), nonInteractive: Duration = .seconds(3),
        filter: EnvFilter = .default, maxAge: Duration? = nil
    ) -> LoginShellEnvConfig {
        var base: [String: String] = [
            "HOME": root.path, "USER": "tester", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SSH_AUTH_SOCK": "/tmp/fake-agent.sock", "HTTPS_PROXY": "http://proxy.invalid:8080",
        ]
        base.merge(extra) { $1 }
        return LoginShellEnvConfig(
            shellPath: shell, baseEnvironment: base, runDirectory: runDir,
            interactiveTimeout: interactive, nonInteractiveTimeout: nonInteractive, filter: filter, maxAge: maxAge
        )
    }

    func runDirIsClean() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: runDir.path)) ?? []).isEmpty
    }
}

private let syntheticShell = """
export FOO=bar
export MULTI=$'line1\\nline2\\n-----END CERT-----'
export CRLF=$'a\\r\\nb'
export KITTY_PANE_KEY=pane KITTY_AGENT_HOOK_PORT=1 CLAUDECODE=1 RACKY_PANE_ID=x TERM_PROGRAM=iTerm.app VSCODE_PID=1
export MY_SECRET_TOKEN=value-that-must-not-leak
if [ "$2" = "-i" ]; then export FROM_INTERACTIVE=1; fi
eval "${@: -1}"
"""

/// Polling com prazo (não sleep fixo): sob carga o recolhimento do processo pode demorar além de 2 s.
private func processIsGone(_ pid: pid_t, deadline: Duration = .seconds(15)) async -> Bool {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return kill(pid, 0) != 0 && errno == ESRCH
}

/// Espera o arquivo aparecer, com prazo (o spawn do zsh sob carga pode levar vários segundos).
private func waitForFile(_ box: Sandbox, _ name: String, deadline: Duration = .seconds(20)) async -> String? {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
        if let text = box.read(name), !text.isEmpty { return text }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return box.read(name)
}

@Suite(.tags(.integration)) struct LoginShellEnvTests {
    // MARK: Shell sintético rápido

    @Test func syntheticFastShellCapturesInteractiveFilteredEnv() async throws {
        let box = Sandbox()
        let shell = box.script("fast-shell", syntheticShell)
        // Folga para a suíte paralela carregada: com 5 s a captura interativa às vezes estoura e cai (corretamente) no fallback.
        let provider = LoginShellEnvProvider(config: box.config(shell: shell, interactive: .seconds(20)))
        let result = await provider.environment()

        guard case .interactive(let captured) = result else { Issue.record("esperado interactive: \(result)"); return }
        let vars = captured.variables
        #expect(vars["FOO"] == "bar")
        #expect(vars["FROM_INTERACTIVE"] == "1")
        #expect(vars["SSH_AUTH_SOCK"] == "/tmp/fake-agent.sock")
        #expect(vars["HTTPS_PROXY"] == "http://proxy.invalid:8080")
        #expect(vars["PATH"]?.contains("/usr/bin") == true)
        // denylist (AC-T11): nada de KITTY_*, RACKY_*, CLAUDECODE, TERM_PROGRAM*, VSCODE_*, artefatos da captura
        for name in ["KITTY_PANE_KEY", "KITTY_AGENT_HOOK_PORT", "CLAUDECODE", "RACKY_PANE_ID", "TERM_PROGRAM", "VSCODE_PID", "AB_ENV_OUT", "TERM", "PWD", "SHLVL", "_"] {
            #expect(vars[name] == nil, "\(name) deveria ter sido removida")
        }
        #expect(result.diagnostics.banner == nil)
        #expect(result.diagnostics.keys == vars.keys.sorted())
        #expect(box.runDirIsClean(), "arquivo temporário do env deve ser apagado")
    }

    @Test func multilineValuesSurviveByteForByte() async {
        let box = Sandbox()
        let provider = LoginShellEnvProvider(config: box.config(shell: box.script("s", syntheticShell)))
        let vars = await provider.environment().variables
        #expect(vars["MULTI"] == "line1\nline2\n-----END CERT-----")
        #expect(vars["CRLF"] == "a\r\nb") // nenhum \n virou \r\n e nenhum \r sumiu
    }

    @Test func secretValuesNeverAppearInDiagnosticsOrDescriptions() async {
        let box = Sandbox()
        let provider = LoginShellEnvProvider(config: box.config(shell: box.script("s", syntheticShell)))
        let result = await provider.environment()
        let value = "value-that-must-not-leak"
        #expect(result.variables["MY_SECRET_TOKEN"] == value) // passa para o terminal (06 §1.7)...
        #expect(result.diagnostics.secretLikeKeys.contains("MY_SECRET_TOKEN"))
        #expect(!"\(result.captured)".contains(value)) // ...mas nunca vai para texto de diagnóstico
        #expect(!String(reflecting: result.captured).contains(value))
        #expect(!result.diagnostics.keys.joined().contains(value))
    }

    @Test func realZshWithNoisyRcIsIgnoredByMarkerAndFile() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let box = Sandbox()
        let zdot = box.root.appendingPathComponent("zdot", isDirectory: true)
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        try """
        print -P '%F{red}BANNER%f'; printf '\\033[2J\\033[HWelcome\\n'; for i in 1 2 3 4 5 6 7 8 9 10; do echo "noise $i" >&2; done
        export NOISY_RC=1
        export CERT=$'l1\\nl2'
        sleep 0.7
        """.write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let provider = LoginShellEnvProvider(config: box.config(shell: "/bin/zsh", extra: ["ZDOTDIR": zdot.path]))
        let result = await provider.environment()
        guard case .interactive(let captured) = result else { Issue.record("esperado interactive: \(result)"); return }
        #expect(captured.variables["NOISY_RC"] == "1")
        #expect(captured.variables["CERT"] == "l1\nl2")
        #expect(captured.variables["ZDOTDIR"] == zdot.path)
    }

    // MARK: Travamento, fallback e falhas

    @Test func hangingInteractiveRcIsKilledAfterFiveSecondsWithoutOrphanAndFallsBack() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let box = Sandbox()
        let zdot = box.root.appendingPathComponent("zdot", isDirectory: true)
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        // O .zshrc só roda no modo interativo; o `-l -c` do fallback não o lê.
        try "sleep 60 &\necho $! > \(box.path("sleeper.pid"))\nwait\n".write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let provider = LoginShellEnvProvider(config: box.config(shell: "/bin/zsh", extra: ["ZDOTDIR": zdot.path]))

        let started = ContinuousClock.now
        let result = await provider.environment()
        let elapsed = ContinuousClock.now - started

        guard case .nonInteractive(let captured) = result else { Issue.record("esperado nonInteractive: \(result)"); return }
        #expect(captured.diagnostics.interactiveFailure == .timedOut(milliseconds: 5000))
        #expect(captured.diagnostics.banner == "Using non-interactive shell environment")
        #expect(captured.diagnostics.source == .nonInteractive)
        // Spec: o prazo interativo é de 5 s (limite inferior exato, medido pelo próprio provider). O teto cobre o
        // fallback não interativo (até 3 s) mais folga de carga; o que importa é não esperar o `sleep 60`.
        #expect(elapsed >= .seconds(5) && elapsed < .seconds(15), "levou \(elapsed)")

        let pidText = try #require(box.read("sleeper.pid")).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        #expect(await processIsGone(pid), "o sleep filho do rc travado deveria estar morto (sem órfão)")
        #expect(box.runDirIsClean())
    }

    @Test func interactiveExitWithoutMarkerFallsBackToNonInteractive() async {
        let box = Sandbox()
        let shell = box.script("no-i", "if [ \"$2\" = \"-i\" ]; then exit 3; fi\nexport ONLY_NONINT=1\neval \"${@: -1}\"")
        let result = await LoginShellEnvProvider(config: box.config(shell: shell)).environment()
        guard case .nonInteractive(let captured) = result else { Issue.record("esperado nonInteractive: \(result)"); return }
        #expect(captured.variables["ONLY_NONINT"] == "1")
        #expect(captured.diagnostics.interactiveFailure == .exitedWithoutMarker(status: 3))
        #expect(result.diagnostics.banner == "Using non-interactive shell environment")
    }

    @Test func bothModesHangingYieldsFailedWithLaunchdFallbackAndNoOrphans() async throws {
        let box = Sandbox()
        let shell = box.script("hang", "sleep 60 &\necho $! >> \(box.path("pids"))\nwait")
        let config = box.config(shell: shell, extra: ["KITTY_PANE_KEY": "leak"], interactive: .seconds(1), nonInteractive: .seconds(1))
        let result = await LoginShellEnvProvider(config: config).environment()
        guard case .failed(let interactive, let nonInteractive, let fallback) = result else { Issue.record("esperado failed: \(result)"); return }
        #expect(interactive == .timedOut(milliseconds: 1000))
        #expect(nonInteractive == .timedOut(milliseconds: 1000))
        #expect(fallback.diagnostics.source == .launchdFallback)
        #expect(fallback.diagnostics.banner == "Using fallback environment")
        let path = try #require(fallback.variables["PATH"])
        #expect(path.contains("/opt/homebrew/bin") && path.contains("/usr/local/bin") && path.contains("/.local/bin"))
        #expect(fallback.variables["KITTY_PANE_KEY"] == nil)
        #expect(fallback.variables["SSH_AUTH_SOCK"] == "/tmp/fake-agent.sock")
        let pids = try #require(box.read("pids")).split(separator: "\n").compactMap { pid_t($0) }
        #expect(pids.count == 2)
        for pid in pids { #expect(await processIsGone(pid)) }
    }

    @Test func missingShellIsFailedWithReasons() async {
        let box = Sandbox()
        let result = await LoginShellEnvProvider(config: box.config(shell: "/nonexistent/shell")).environment()
        guard case .failed(let i, let n, _) = result else { Issue.record("esperado failed"); return }
        if case .spawnFailed = i {} else { Issue.record("motivo interativo inesperado: \(i)") }
        if case .spawnFailed = n {} else { Issue.record("motivo não interativo inesperado: \(n)") }
        #expect(!i.reason.isEmpty)
    }

    // MARK: Cache e invalidação

    private func counting(_ box: Sandbox) -> String {
        box.script("counting", "echo x >> \(box.path("count"))\nexport GEN=$(wc -l < \(box.path("count")) | tr -d ' ')\neval \"${@: -1}\"")
    }
    private func captures(_ box: Sandbox) -> Int { (box.read("count") ?? "").split(separator: "\n").count }

    @Test func cacheServesRepeatedCallsAndReloadInvalidates() async {
        let box = Sandbox()
        let provider = LoginShellEnvProvider(config: box.config(shell: counting(box)))
        #expect(await provider.cachedResult() == nil)
        let first = await provider.environment()
        let second = await provider.environment()
        #expect(first == second)
        #expect(captures(box) == 1)
        #expect(await provider.cachedResult() == first)

        let reloaded = await provider.reload()
        #expect(captures(box) == 2, "\(reloaded.diagnostics)")
        #expect(reloaded.variables["GEN"] == "2")
        await provider.invalidate()
        #expect(await provider.cachedResult() == nil)
        _ = await provider.environment()
        #expect(captures(box) == 3)
    }

    @Test func concurrentCallsShareOneCapture() async {
        let box = Sandbox()
        let provider = LoginShellEnvProvider(config: box.config(shell: counting(box)))
        await withTaskGroup(of: LoginShellEnvResult.self) { group in
            for _ in 0..<8 { group.addTask { await provider.environment() } }
            for await _ in group {}
        }
        #expect(captures(box) == 1)
    }

    @Test func maxAgeExpiresTheCache() async throws {
        let box = Sandbox()
        let provider = LoginShellEnvProvider(config: box.config(shell: counting(box), maxAge: .milliseconds(150)))
        _ = await provider.environment()
        try await Task.sleep(for: .milliseconds(300))
        _ = await provider.environment()
        #expect(captures(box) == 2)
    }

    @Test func failuresAreNotCached() async {
        let box = Sandbox()
        let provider = LoginShellEnvProvider(config: box.config(shell: "/nonexistent/shell"))
        _ = await provider.environment()
        #expect(await provider.cachedResult() == nil)
    }

    @Test func cancelledCaptureKillsTheShellQuickly() async throws {
        let box = Sandbox()
        let shell = box.script("hang", "sleep 60 &\necho $! > \(box.path("pid"))\nwait")
        let provider = LoginShellEnvProvider(config: box.config(shell: shell))
        let task = Task { await provider.environment() }
        _ = try #require(await waitForFile(box, "pid"), "o shell travado nunca iniciou")
        // O relógio só conta a partir do cancelamento: cancelar tem que ser bem mais rápido que o prazo de 5 s da spec.
        let cancelledAt = ContinuousClock.now
        await provider.invalidate()
        let result = await task.value
        #expect(ContinuousClock.now - cancelledAt < .seconds(4), "cancelar levou \(ContinuousClock.now - cancelledAt)")
        if case .failed(.cancelled, _, _) = result {} else { Issue.record("esperado failed(cancelled): \(result)") }
        let pid = try #require(pid_t((box.read("pid") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await processIsGone(pid))
    }

    // MARK: Filtro e parser

    @Test func allowlistBeatsDenylistAndExtraRulesApply() async {
        let box = Sandbox()
        let filter = EnvFilter.default.adding(denyNames: ["FOO"], allowNames: ["KITTY_KEEP_ME"])
        let shell = box.script("s", "export KITTY_KEEP_ME=1 KITTY_DROP=1 FOO=bar BAR=baz\neval \"${@: -1}\"")
        let vars = await LoginShellEnvProvider(config: box.config(shell: shell, filter: filter)).environment().variables
        #expect(vars["KITTY_KEEP_ME"] == "1")
        #expect(vars["KITTY_DROP"] == nil)
        #expect(vars["FOO"] == nil)
        #expect(vars["BAR"] == "baz")
    }

    @Test func inheritedParentAgentSessionMarkersAreDropped() {
        let f = EnvFilter.default
        let parent = [
            "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_EXECPATH": "/x", "CLAUDECODE": "1",
            "CLAUDE_AGENT_SDK_VERSION": "1", "KITTY_PANE_KEY": "p", "RACKY_APP_SOCK": "/s", "TERM_PROGRAM": "iTerm.app",
            "TERM_PROGRAM_VERSION": "3", "CODEX_THREAD_ID": "t", "CODEX_SANDBOX": "seatbelt", "CODEX_SANDBOX_NETWORK_DISABLED": "1",
            "CODEX_CI": "1", "CODEX_SESSION_ID": "s",
            // o que o usuário configurou continua
            "PATH": "/usr/bin", "HOME": "/Users/u", "ANTHROPIC_API_KEY": "k", "CODEX_HOME": "/h", "CLAUDE_CODE_OAUTH_TOKEN": "tok",
            "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CONFIG_DIR": "/c",
        ]
        let kept = f.apply(to: parent)
        #expect(Set(kept.keys) == ["PATH", "HOME", "ANTHROPIC_API_KEY", "CODEX_HOME", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CONFIG_DIR"])
    }

    @Test func defaultFilterMatchesSpecDenylist() {
        let f = EnvFilter.default
        for name in ["PWD", "OLDPWD", "SHLVL", "_", "TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_PROFILE",
                     "WEZTERM_PANE", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "VSCODE_INJECTION", "KITTY_PANE_KEY", "RACKY_RUN_ID",
                     "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "ORCA_AGENT_HOOK_PORT", "ORCA_PANE_KEY"] {
            #expect(!f.keeps(name), "\(name)")
        }
        for name in ["PATH", "SSH_AUTH_SOCK", "HTTP_PROXY", "https_proxy", "NO_PROXY", "all_proxy", "GH_TOKEN", "ANTHROPIC_API_KEY", "LANG", "HOME"] {
            #expect(f.keeps(name), "\(name)")
        }
    }

    @Test func parserHandlesNulSeparatedEntries() {
        let data = Data("A=1\0B=x=y\0C=\0=bad\0noequals\0M=l1\nl2\0".utf8)
        let vars = LoginShellEnvParser.parse(data)
        #expect(vars == ["A": "1", "B": "x=y", "C": "", "M": "l1\nl2"])
    }

    @Test func secretNameDetector() {
        for n in ["OPENAI_API_KEY", "GH_TOKEN", "CLIENT_SECRET", "DB_PASSWORD", "SSH_AUTH_SOCK", "passphrase"] { #expect(SecretNames.isSecretLike(n)) }
        for n in ["PATH", "HOME", "LANG"] { #expect(!SecretNames.isSecretLike(n)) }
    }
}

// MARK: - Integração com o $SHELL real da máquina

private func toolSearchDirs() -> [String] {
    let home = NSHomeDirectory()
    let ambient = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return ambient + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin"]
}

private func exists(_ tool: String, in dirs: [String]) -> Bool {
    dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
}

@Suite(.tags(.integration), .serialized, .timeLimit(.minutes(1))) struct LoginShellEnvRealShellTests {
    // Pula quando `claude` ou `gh` não existem na máquina.
    @Test(.enabled(if: exists("claude", in: toolSearchDirs()) && exists("gh", in: toolSearchDirs())))
    func realLoginShellPathResolvesClaudeAndGh() async throws {
        // Env mínimo no estilo launchd (como o app lançado pelo Finder), não o da sessão de teste.
        let base = [
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
        ]
        let box = Sandbox()
        let config = LoginShellEnvConfig(baseEnvironment: base, runDirectory: box.runDir)
        let result = await LoginShellEnvProvider(config: config).environment()
        #expect(result.isInteractive, "captura interativa esperada com o shell real: \(result.diagnostics.source)")
        let pathDirs = (result.variables["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(exists("claude", in: pathDirs), "claude deve resolver pelo PATH capturado")
        #expect(exists("gh", in: pathDirs), "gh deve resolver pelo PATH capturado")
        #expect(result.variables.keys.allSatisfy { !$0.hasPrefix("KITTY_") })
        #expect(box.runDirIsClean())
    }
}
