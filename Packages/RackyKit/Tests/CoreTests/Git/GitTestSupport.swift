import Foundation
@testable import RackyCore

/// Sandbox temporário: HOME, config global e repositórios vivem só aqui. Nunca toca em repositórios do usuário.
final class GitSandbox: @unchecked Sendable { // SAFETY: imutável depois do init; usado só por testes.
    let root: URL
    let env: [String: String]
    let runner: GitProcessRunner
    let service: GitService

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("racky-git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.canonicalPath
        env = [
            "HOME": root.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test User", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test User", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]
        runner = GitProcessRunner(extraEnvironment: env)
        service = GitService(runner: runner)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func git(_ args: [String], in dir: URL) async throws -> String {
        let result = try await runner.run(args, in: dir, kind: .write, timeout: .seconds(30))
        guard result.succeeded else {
            throw GitError.commandFailed(operation: args.joined(separator: " "), exitCode: result.exitCode,
                                         stderr: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ file: String, _ text: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Repositório com um commit em `main`.
    func makeRepo(_ name: String = "proj") async throws -> URL {
        let url = try dir(name)
        try await git(["init", "-q", "-b", "main"], in: url)
        try await git(["config", "user.name", "Alex Doe"], in: url)
        try write("README.md", "hello\n", in: url)
        try await git(["add", "."], in: url)
        try await git(["commit", "-q", "-m", "init"], in: url)
        return url
    }

    /// Repositório com `origin` bare local, `main` publicado e `origin/HEAD` definido.
    func makeRepoWithOrigin(_ name: String = "proj") async throws -> (repo: URL, origin: URL) {
        let repo = try await makeRepo(name)
        let origin = root.appendingPathComponent("\(name)-origin.git", isDirectory: true)
        try await git(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try await git(["remote", "add", "origin", origin.path], in: repo)
        try await git(["push", "-q", "-u", "origin", "main"], in: repo)
        try await git(["remote", "set-head", "origin", "main"], in: repo)
        return (repo, origin)
    }

    /// Publica um commit novo em `origin/main` por outro clone, sem que `repo` saiba.
    func pushCommitToOrigin(_ origin: URL, file: String = "other.txt") async throws -> String {
        let clone = root.appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
        try await git(["clone", "-q", origin.path, clone.path], in: root)
        try write(file, "x\n", in: clone)
        try await git(["add", "."], in: clone)
        try await git(["commit", "-q", "-m", "remote work"], in: clone)
        try await git(["push", "-q", "origin", "main"], in: clone)
        return try await git(["rev-parse", "HEAD"], in: clone)
    }
}
