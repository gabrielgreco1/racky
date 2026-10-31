import RackyCore
import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Git de mentira: responde às consultas do módulo Files com saídas fixas (a árvore e o status não dependem do git instalado).
struct FakeGitRunner: GitCommandRunning {
    var top: String
    var porcelain: String
    var branch = "main"
    var diff = ""

    func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind, timeout: Duration) async throws -> GitCommandResult {
        switch arguments.first {
        case "rev-parse":
            if arguments.contains("--show-toplevel") { return GitCommandResult(exitCode: 0, stdout: top + "\n", stderr: "") }
            return GitCommandResult(exitCode: 0, stdout: branch + "\n", stderr: "")
        case "status": return GitCommandResult(exitCode: 0, stdout: porcelain, stderr: "")
        case "diff": return GitCommandResult(exitCode: 0, stdout: diff, stderr: "")
        default: return GitCommandResult(exitCode: 1, stdout: "", stderr: "unsupported")
        }
    }
}

/// Estado que o módulo lê do workspace (sessão, pasta, terminal focado), editável pelos testes.
@MainActor
final class FilesSourceBox {
    var sessionID: UUID? = UUID()
    var sessionRoot: String?
    var focused: FilesFocusedTerminal?

    var source: FilesSource {
        FilesSource(sessionID: { self.sessionID }, sessionRoot: { self.sessionRoot }, focusedTerminal: { self.focused })
    }
}

@MainActor
enum FilesFixture {
    /// Cria `files` (com `/` no fim = pasta) debaixo de uma pasta temporária e devolve o caminho canônico.
    static func makeTree(_ files: [String], name: String = UUID().uuidString) throws -> String {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("racky-files-ui-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            if file.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return FileTreeLoader.canonical(root.path)
    }

    static func write(_ text: String, to path: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }

    static func controller(
        box: FilesSourceBox, porcelain: String = "", diff: String = ""
    ) -> FilesController {
        let controller = FilesController(
            source: box.source, service: FilesService(),
            git: FilesGitService(runner: FakeGitRunner(top: box.sessionRoot ?? "/", porcelain: porcelain, diff: diff), timeout: .seconds(2)))
        controller.treeDebounce = .milliseconds(40)
        controller.gitDebounce = .milliseconds(20)
        return controller
    }

    static func claude(_ id: UUID = UUID(), cwd: String? = nil) -> FilesFocusedTerminal {
        FilesFocusedTerminal(id: id, agent: "Claude", fallbackCwd: cwd)
    }

    /// Espera uma condição do main actor (a árvore carrega fora do main).
    /// 15 s: sob a suíte paralela carregada o FSEvents atrasa mais que 5 s (só pesa quando a condição demora).
    static func wait(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    static func rowNames(_ controller: FilesController) -> [String] { controller.tree?.rows.map(\.entry.name) ?? [] }

    /// Registro de ações próprio (o `AppEnvironment` já registra as ações do `files` dele).
    static func registry(for controller: FilesController) throws -> ActionRegistry {
        let elements = UIElementStore()
        let flags = SliceFlags()
        let surface = WindowAutomation(store: elements, flags: flags, fixture: nil, automationEnabled: false)
        let registry = ActionRegistry(flags: flags, surface: surface)
        try controller.register(in: registry, openIn: nil, overlays: OverlayRouter(), elements: elements)
        return registry
    }
}
