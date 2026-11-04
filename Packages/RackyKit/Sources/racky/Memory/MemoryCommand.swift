import RackyPlatform
import ArgumentParser
import Foundation

/// `racky memory search|read|add|index`: a memória do agente (`~/Racky/agents/<agente>/memory.sqlite`) para o agente que roda no CLI.
/// É o que o prompt do agente chama de memory_search e memory_read; `add` grava a entrada curta do fim da tarefa.
struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory", abstract: "Read and write an agent's memory.",
        subcommands: [Search.self, Read.self, Add.self, Index.self])

    struct Target: ParsableArguments {
        @Option(name: .long, help: "The agent name.") var agent: String
        func open() throws -> AgentMemoryStore {
            guard agent.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil, !agent.contains("..") else {
                throw ValidationError("Invalid agent name.")
            }
            let root = ProcessInfo.processInfo.environment["RACKY_AGENTS_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Racky/agents", isDirectory: true)
            let folder = root.appendingPathComponent(agent, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { throw ValidationError("No such agent: \(agent).") }
            return try AgentMemoryStore(path: folder.appendingPathComponent("memory.sqlite"))
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search the memory (memory_search).")
        @OptionGroup var target: Target
        @Option(name: .long, help: "Maximum results.") var limit = 8
        @Argument(help: "What to look for.") var query: [String]
        func run() async throws {
            let hits = try await target.open().search(query.joined(separator: " "), limit: limit)
            if hits.isEmpty { print("No matches."); return }
            for h in hits { print("#\(h.id) \(h.title)\n    \(h.snippet.replacingOccurrences(of: "\n", with: " "))") }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read one entry in full (memory_read).")
        @OptionGroup var target: Target
        @Argument(help: "Entry id, as in #12.") var id: String
        func run() async throws {
            guard let n = Int64(id.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else { throw ValidationError("Entry ids are numbers, like 12.") }
            let e = try await target.open().read(id: n)
            print("#\(e.id) \(e.title)\n\(e.body)")
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a short entry at the end of a task.")
        @OptionGroup var target: Target
        @Option(name: .long, help: "Short title.") var title: String
        @Option(name: .long, help: "What to remember. Keep URLs and code as they are.") var body: String
        @Flag(name: .long, help: "Skip the compression of filler words.") var raw = false
        func run() async throws {
            let id = try await target.open().add(title: raw ? title : AgentMemoryText.compress(title), body: raw ? body : AgentMemoryText.compress(body))
            print("Saved #\(id).")
        }
    }

    struct Index: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The short index the task started with.")
        @OptionGroup var target: Target
        func run() async throws { print(try await target.open().index()) }
    }
}
