import RackyPlatform
import RackyProtocol
import ArgumentParser
import Darwin
import Foundation

/// `racky hook --provider <claude|codex> --event <Evento>` (06 §3.2, 08 §5.5).
///
/// Lê o JSON do hook no stdin, identifica execução e pane pelo env (`RACKY_RUN_ID`, `RACKY_PANE_ID`), entrega ao
/// serviço `hook` de `RACKY_APP_SOCK` com prazo de 200 ms e, se o app não responder, acrescenta ao spool
/// `run/spool/hooks/<runID>.jsonl`. Escreve `{}` no stdout e sai com 0 sempre: nunca bloqueia nem muda o comportamento do
/// agente. Sem `RACKY_RUN_ID` (por exemplo um `claude` aberto no Terminal.app) sai em silêncio.
struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Forward an agent hook event to Racky (never blocks the agent).")

    @Option(name: .long, help: "claude or codex.")
    var provider: String = "claude"

    @Option(name: .long, help: "Hook event name (default: hook_event_name from the payload).")
    var event: String?

    func run() {
        HookRunner(environment: ProcessInfo.processInfo.environment).run(provider: provider, event: event)
        // Exit 0 sempre (ParsableCommand sai com 0 ao retornar).
    }
}

struct HookRunner {
    let environment: [String: String]

    /// Quanto o helper espera o stdin antes de seguir com o que já leu.
    static let stdinBudgetMs = 500

    func run(provider providerName: String, event: String?) {
        defer { FileHandle.standardOutput.write(Data("{}\n".utf8)) }
        guard let runID = environment["RACKY_RUN_ID"], !runID.isEmpty else { return }
        let provider = HookProvider(rawValue: providerName.lowercased()) ?? .claude
        let atNs = HookTransport.realtimeNs()

        let raw = Self.readStdin(budgetMs: Self.stdinBudgetMs)
        let eventName = event.flatMap { $0.isEmpty ? nil : $0 } ?? Self.eventName(in: raw) ?? "Unknown"
        let envelope = HookEnvelope(
            provider: provider, event: eventName, runID: runID,
            paneID: environment["RACKY_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 },
            atNs: atNs, payload: HookPayloadReducer.reduce(raw))
        guard let line = try? HookCodec.line(envelope) else { return }

        let socket = AppSockPath.resolve(environment: environment)
        // `RACKY_HOOK_TIMEOUT_MS` é só de teste (08 §0.2): sob carga o app de teste pode demorar mais que 200 ms.
        let timeoutMs = environment["RACKY_HOOK_TIMEOUT_MS"].flatMap(Int.init).map { min(max($0, 1), 10_000) } ?? HookLimits.deliveryTimeoutMs
        if HookTransport.deliver(line, socketPath: socket, timeoutMs: timeoutMs).isDelivered { return }
        try? HookSpool.append(
            line, runID: runID, directory: HookSpool.directory(forSocketPath: socket), nowNs: HookTransport.realtimeNs())
    }

    static func eventName(in raw: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        return o["hook_event_name"] as? String
    }

    /// Lê o stdin até EOF, até o JSON fechar ou até o prazo. Terminal interativo: não lê. Guarda até 16 MiB e descarta o resto.
    static func readStdin(budgetMs: Int) -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        let deadline = HookTransport.monotonicNs() + UInt64(budgetMs) * 1_000_000
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let now = HookTransport.monotonicNs()
            guard now < deadline else { break }
            var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
            let rc = poll(&p, 1, ms)
            if rc == 0 { break }
            if rc < 0 { if errno == EINTR { continue } else { break } }
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n > 0 {
                if data.count < HookLimits.maxStdinBytes { data.append(buffer, count: min(n, HookLimits.maxStdinBytes - data.count)) }
                // O JSON do hook é um objeto único: se já fecha, não espera o EOF.
                if buffer[n - 1] == 0x7D || buffer[n - 1] == 0x0A,
                   (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { break }
                continue
            }
            if n == 0 { break }
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        return data
    }
}
