import Foundation
@testable import RackyCore

/// Runner falso do `gh`: responde por closure e grava as chamadas. Nunca executa processo.
final class FakeGitHubRunner: GitHubCommandRunning, @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var handler: @Sendable ([String]) throws -> GitCommandResult

    init(_ handler: @escaping @Sendable ([String]) throws -> GitCommandResult) { self.handler = handler }

    var calls: [[String]] { lock.withLock { _calls } }
    var graphQLCalls: [[String]] { calls.filter { $0.prefix(2) == ["api", "graphql"] } }

    func setHandler(_ new: @escaping @Sendable ([String]) throws -> GitCommandResult) {
        lock.withLock { handler = new }
    }

    func run(_ arguments: [String], in directory: URL?, timeout: Duration) async throws -> GitCommandResult {
        let current = lock.withLock { () -> @Sendable ([String]) throws -> GitCommandResult in
            _calls.append(arguments)
            return handler
        }
        return try current(arguments)
    }
}

/// Runner falso do git para o plano de "Create PR".
final class FakeGitRunner: GitCommandRunning, @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let result: GitCommandResult
    init(result: GitCommandResult = GitCommandResult(exitCode: 0, stdout: "", stderr: "")) { self.result = result }
    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind, timeout: Duration) async throws -> GitCommandResult {
        lock.withLock { _calls.append(arguments) }
        return result
    }
}

final class TestClock: @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

enum GitHubFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    /// Resposta sintética para `count` branches, reaproveitando os PRs reais anonimizados do fixture
    /// (alias `b<i>` recebe os nós de `b<i % 6>`); `remaining` controla o `rateLimit`.
    static func response(branchCount count: Int, remaining: Int = 4900) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: data("pr-batch.json")) as? [String: Any],
              var payload = root["data"] as? [String: Any],
              let repository = payload["repository"] as? [String: Any] else { fatalError("bad fixture") }
        var synthetic: [String: Any] = [:]
        for index in 0..<count { synthetic["b\(index)"] = repository["b\(index % 6)"] }
        payload["repository"] = synthetic
        payload["rateLimit"] = ["cost": 1, "remaining": remaining, "resetAt": "2026-10-17T18:00:00Z"]
        root["data"] = payload
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    /// Quantidade de branches (`-f b<i>=…`) numa chamada `gh api graphql`.
    static func branchCount(in arguments: [String]) -> Int {
        arguments.filter { $0.range(of: #"^b\d+="#, options: .regularExpression) != nil }.count
    }
}

extension GitCommandResult {
    static func ok(_ stdout: String) -> GitCommandResult { GitCommandResult(exitCode: 0, stdout: stdout, stderr: "") }
    static func fail(_ stderr: String, code: Int32 = 1, stdout: String = "") -> GitCommandResult {
        GitCommandResult(exitCode: code, stdout: stdout, stderr: stderr)
    }
}
