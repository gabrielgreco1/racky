import Foundation

public struct GitWorktreeRemovalResult: Sendable, Equatable {
    public let removedPath: String
    public let branch: String?
    public let branchDeleted: Bool
    /// `git branch -d` recusou por não estar mesclado; `-D` exige segunda confirmação (06 §5.2).
    public let branchNotMerged: Bool
}

/// Git mínimo da Fatia 1 (T1-18, 06 §5): detecção, status, ahead/behind, worktrees.
/// Valor imutável e `Sendable` (AR-403); toda execução vai para o `ProcessRunner`, fora do pool cooperativo.
/// Nunca usa stash, reset nem clean.
public struct GitService: Sendable {
    public struct Timeouts: Sendable, Equatable {
        public var read: Duration
        public var write: Duration
        public var fetch: Duration
        public init(read: Duration = .seconds(10), write: Duration = .seconds(30), fetch: Duration = .seconds(30)) {
            self.read = read
            self.write = write
            self.fetch = fetch
        }
    }

    private let runner: any GitCommandRunning
    private let timeouts: Timeouts

    public init(runner: any GitCommandRunning = GitProcessRunner(), timeouts: Timeouts = Timeouts()) {
        self.runner = runner
        self.timeouts = timeouts
    }

    // MARK: - Detecção e status

    /// Nil para pasta comum (fora de repositório Git). Lança `invalidDirectory` se a pasta não existe.
    public func detectRepository(at directory: URL) async throws -> GitRepositoryInfo? {
        let dir = directory.canonicalPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.invalidDirectory(dir.path)
        }
        let inside = try await runner.run(["rev-parse", "--is-inside-work-tree"], in: dir, kind: .read,
                                          timeout: timeouts.read)
        guard inside.succeeded, inside.stdout.trimmed == "true" else { return nil }
        let out = try await checked(["rev-parse", "--show-toplevel", "--path-format=absolute", "--git-common-dir"],
                                    in: dir, kind: .read, timeout: timeouts.read)
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 2, !lines[0].isEmpty, !lines[1].isEmpty else {
            throw GitError.unexpectedOutput("rev-parse")
        }
        let root = URL(fileURLWithPath: lines[0], isDirectory: true).canonicalPath
        let common = URL(fileURLWithPath: lines[1], isDirectory: true).canonicalPath
        let main = common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : root
        return GitRepositoryInfo(rootURL: root, mainRootURL: main)
    }

    /// Estado local do checkout (branch, upstream, ahead/behind, contagens). `GIT_OPTIONAL_LOCKS=0`.
    public func status(at checkoutURL: URL) async throws -> GitStatus {
        let out = try await checked(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"],
                                    in: checkoutURL, kind: .read, timeout: timeouts.read, notRepository: true)
        return GitParsers.parseStatus(out)
    }

    /// Remove do Git as referências de worktrees que já não existem no disco.
    public func pruneWorktrees(in repositoryURL: URL) async throws {
        _ = try await runner.run(["worktree", "prune"], in: repositoryURL, kind: .write, timeout: timeouts.write)
    }

    /// Caminhos alterados ou não rastreados (`status --porcelain=v1 -z`), para listar no diálogo de apagar (06 §5.2).
    /// Devolve no máximo `limit`; o total vem de `status(at:)`.
    public func changedPaths(at checkoutURL: URL, limit: Int = 8) async throws -> [String] {
        let out = try await checked(["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
                                    in: checkoutURL, kind: .read, timeout: timeouts.read, notRepository: true)
        var paths: [String] = []
        var skipNext = false
        for record in out.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipNext { skipNext = false; continue }
            let line = String(record)
            guard line.count > 3 else { continue }
            let code = line.prefix(2)
            if code.contains("R") || code.contains("C") { skipNext = true }
            paths.append(String(line.dropFirst(3)))
            if paths.count >= limit { break }
        }
        return paths
    }

    /// Branch atual; nil com HEAD destacado.
    public func currentBranch(at checkoutURL: URL) async throws -> String? {
        try await status(at: checkoutURL).branch
    }

    /// Branch padrão: `origin/HEAD`, senão `origin/main|master`, senão `main|master` local.
    public func defaultBranch(in repositoryURL: URL) async throws -> String {
        let head = try await runner.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                                        in: repositoryURL, kind: .read, timeout: timeouts.read)
        if head.succeeded {
            let value = head.stdout.trimmed
            if value.hasPrefix("origin/") { return String(value.dropFirst("origin/".count)) }
        }
        for name in ["main", "master"] {
            if try await refExists("refs/remotes/origin/\(name)", in: repositoryURL) { return name }
        }
        for name in ["main", "master"] {
            if try await refExists("refs/heads/\(name)", in: repositoryURL) { return name }
        }
        throw GitError.baseRefMissing("origin/main")
    }

    /// URL do remote `origin` sem credenciais embutidas (`https://user:token@host/x` vira `https://host/x`); nil sem remote.
    public func remoteURL(in repositoryURL: URL) async throws -> String? {
        let result = try await runner.run(["config", "--get", "remote.origin.url"], in: repositoryURL, kind: .read,
                                          timeout: timeouts.read)
        guard result.succeeded else { return nil }
        let raw = result.stdout.trimmed
        return raw.isEmpty ? nil : GitNaming.stripCredentials(raw)
    }

    /// Prefixo de branch a partir de `git config user.name` (06 §5.2; o login do `gh` entra na Fatia 2).
    public func gitUsernamePrefix(in repositoryURL: URL) async throws -> GitBranchPrefix {
        let result = try await runner.run(["config", "--get", "user.name"], in: repositoryURL, kind: .read,
                                          timeout: timeouts.read)
        let name = result.succeeded ? result.stdout.trimmed : ""
        return name.isEmpty ? .none : .gitUsername(name)
    }

    // MARK: - Branches

    /// Onde um branch existe: local (`refs/heads`), só no `origin` ou em lugar nenhum.
    public func lookupBranch(_ name: String, in repositoryURL: URL) async throws -> GitBranchLookup {
        guard !name.isEmpty, !name.hasPrefix("-") else { return .none }
        if try await refExists("refs/heads/\(name)", in: repositoryURL) { return .local }
        if try await refExists("refs/remotes/origin/\(name)", in: repositoryURL) { return .remote }
        return .none
    }

    /// Nomes curtos dos branches locais e `origin/*` (sem `origin/HEAD`), locais primeiro, no máximo `limit`.
    public func branches(in repositoryURL: URL, limit: Int = 60) async throws -> [String] {
        let out = try await checked(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin"],
                                    in: repositoryURL, kind: .read, timeout: timeouts.read, notRepository: true)
        var locals: [String] = [], remotes: [String] = []
        for line in out.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("refs/heads/") { locals.append(String(line.dropFirst("refs/heads/".count))) }
            else if line.hasPrefix("refs/remotes/") {
                let short = String(line.dropFirst("refs/remotes/".count))
                if short != "origin/HEAD" { remotes.append(short) }
            }
        }
        return Array((locals.sorted() + remotes.sorted()).prefix(limit))
    }

    // MARK: - Worktrees

    /// Lista worktrees (o primeiro é o checkout principal).
    public func listWorktrees(in repositoryURL: URL) async throws -> [GitWorktreeInfo] {
        let out = try await checked(["worktree", "list", "--porcelain", "-z"], in: repositoryURL, kind: .read,
                                    timeout: timeouts.read, notRepository: true)
        return GitParsers.parseWorktrees(out)
    }

    /// Cria um worktree (branch existente, ou nova a partir de `origin/<default>`), com nomes de pasta e branch
    /// únicos (`-2`, `-3`…). Em falha desfaz só o que esta chamada criou.
    public func createWorktree(_ request: GitWorktreeRequest, progress: (@Sendable (GitWorktreePhase) -> Void)? = nil) async throws -> GitWorktreeCreation {
        guard let info = try await detectRepository(at: request.repositoryURL) else {
            throw GitError.notARepository(request.repositoryURL.path)
        }
        let repo = info.mainRootURL
        let existing = try await listWorktrees(in: repo)
        let parent = request.worktreeRoot.canonicalPath
            .appendingPathComponent(info.name, isDirectory: true)
        guard !(parent.path + "/").hasPrefix(repo.path + "/") else {
            throw GitError.invalidDestination("A raiz de worktrees não pode ficar dentro do repositório.")
        }

        var plan: CreationPlan
        var fetched = false
        switch request.source {
        case .existingBranch(let name):
            try await validateBranchName(name, in: repo)
            if let other = existing.first(where: { $0.branch == name }) {
                throw GitError.branchInUse(branch: name, worktreePath: other.path)
            }
            let local = try await refExists("refs/heads/\(name)", in: repo)
            let remote = try await refExists("refs/remotes/origin/\(name)", in: repo)
            guard local || remote else { throw GitError.branchNotFound(name) }
            plan = CreationPlan(branch: name, baseRef: nil, kind: local ? .checkoutExisting : .trackRemote,
                                slug: GitNaming.slug(from: name))
        case .newBranch(let slug, let prefix, let baseRef):
            let normalized = GitNaming.slug(from: slug)
            let branchBase = prefix.value.map { "\($0)/\(normalized)" } ?? normalized
            try await validateBranchName(branchBase, in: repo)
            let base = try await resolveBase(baseRef, in: repo, policy: request.fetch, fetched: &fetched, progress: progress)
            plan = CreationPlan(branch: branchBase, baseRef: base, kind: .newBranch, slug: normalized)
            plan.autoSuffix = true
        case .newBranchExact(let name, let baseRef):
            try await validateBranchName(name, in: repo)
            if try await branchTaken(name, in: repo) { throw GitError.branchAlreadyExists(name) }
            let base = try await resolveBase(baseRef, in: repo, policy: request.fetch, fetched: &fetched, progress: progress)
            plan = CreationPlan(branch: name, baseRef: base, kind: .newBranch, slug: GitNaming.slug(from: name))
        }

        progress?(.creating)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let (destination, branch) = try await pickNames(plan, parent: parent, in: repo)
        let baseCommit: String? = if let base = plan.baseRef { try await resolvedCommit(base, in: repo) } else { nil }

        var args = ["worktree", "add"]
        switch plan.kind {
        case .newBranch: args += ["--no-track", "-b", branch, "--", destination.path, baseCommit ?? ""]
        case .checkoutExisting: args += ["--", destination.path, branch]
        case .trackRemote: args += ["--track", "-b", branch, "--", destination.path, "origin/\(branch)"]
        }
        let createdBranch = plan.kind != .checkoutExisting
        let expectedTip: String? = switch plan.kind {
        case .newBranch: baseCommit
        case .trackRemote: try await resolvedCommit("origin/\(branch)", in: repo)
        case .checkoutExisting: nil
        }
        let existedBefore = FileManager.default.fileExists(atPath: destination.path)
        let result: GitCommandResult
        do {
            result = try await runner.run(args, in: repo, kind: .write, timeout: timeouts.write)
        } catch {
            _ = await rollback(repo: repo, branch: createdBranch ? branch : nil, tip: expectedTip,
                               destination: destination, existedBefore: existedBefore)
            throw error
        }
        guard result.succeeded else {
            let clean = await rollback(repo: repo, branch: createdBranch ? branch : nil, tip: expectedTip,
                                       destination: destination, existedBefore: existedBefore)
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmed
            if !existedBefore, detail.contains("already exists"), FileManager.default.fileExists(atPath: destination.path) {
                throw GitError.destinationOccupied(destination.path)
            }
            throw GitError.creationFailed(detail, cleanupIncomplete: !clean)
        }
        guard let created = try await detectRepository(at: destination), created.rootURL.path == destination.path,
              try await currentBranch(at: destination) == branch else {
            throw GitError.creationFailed("O checkout criado não pôde ser confirmado.", cleanupIncomplete: true)
        }
        return GitWorktreeCreation(path: destination, branch: branch, baseRef: plan.baseRef, fetched: fetched)
    }

    /// Recria o checkout de uma branch que já existe em `path` (sessão arquivada cujo worktree saiu do disco e volta com Restore).
    public func checkoutWorktree(repositoryURL: URL, path: URL, branch: String) async throws {
        _ = try await runner.run(["worktree", "prune"], in: repositoryURL, kind: .write, timeout: timeouts.write)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await checked(["worktree", "add", "--", path.path, branch], in: repositoryURL, kind: .write, timeout: timeouts.write)
    }

    /// Checagem prévia da remoção: mudanças não commitadas e commits não publicados.
    public func inspectRemoval(repositoryURL: URL, worktreePath: URL) async throws -> WorktreeRemovalReport {
        let (_, entry) = try await locate(worktreePath, in: repositoryURL)
        return try await removalReport(for: entry, repositoryURL: repositoryURL)
    }

    /// Remove o worktree. Sem `force`, recusa quando há mudanças não commitadas (`worktreeHasChanges`).
    /// Depois roda `worktree prune`; com `deleteBranch`, tenta `branch -d` (nunca `-D`).
    public func removeWorktree(repositoryURL: URL, worktreePath: URL,
                               options: GitWorktreeRemovalOptions = .init()) async throws -> GitWorktreeRemovalResult {
        let (repo, entry) = try await locate(worktreePath, in: repositoryURL)
        if entry.isMain { throw GitError.cannotRemoveMainWorktree }
        if entry.isLocked { throw GitError.worktreeLocked(entry.path) }
        let report = try await removalReport(for: entry, repositoryURL: repo)
        if report.hasUncommittedChanges && !options.force { throw GitError.worktreeHasChanges(report) }
        var args = ["worktree", "remove"]
        if options.force { args.append("--force") }
        args += ["--", entry.path]
        _ = try await checked(args, in: repo, kind: .write, timeout: timeouts.write)
        _ = try await runner.run(["worktree", "prune"], in: repo, kind: .write, timeout: timeouts.write)
        var deleted = false, notMerged = false
        if options.deleteBranch, let branch = entry.branch {
            let result = try await runner.run(["branch", "-d", "--", branch], in: repo, kind: .write,
                                              timeout: timeouts.write)
            deleted = result.succeeded
            notMerged = !result.succeeded && result.stderr.contains("not fully merged")
            if !result.succeeded && !notMerged {
                throw GitError.commandFailed(operation: "branch", exitCode: result.exitCode, stderr: result.stderr.trimmed)
            }
        }
        return GitWorktreeRemovalResult(removedPath: entry.path, branch: entry.branch, branchDeleted: deleted,
                                        branchNotMerged: notMerged)
    }

    // MARK: - Internos

    private struct CreationPlan {
        enum Kind { case newBranch, checkoutExisting, trackRemote }
        var branch: String
        var baseRef: String?
        var kind: Kind
        var slug: String
        var autoSuffix = false
    }

    private func checked(_ args: [String], in dir: URL, kind: GitCommandKind, timeout: Duration,
                         notRepository: Bool = false) async throws -> String {
        let result = try await runner.run(args, in: dir, kind: kind, timeout: timeout)
        guard result.succeeded else {
            let detail = result.stderr.trimmed
            if notRepository, detail.contains("not a git repository") { throw GitError.notARepository(dir.path) }
            throw GitError.commandFailed(operation: GitProcessRunner.operationName(args), exitCode: result.exitCode,
                                         stderr: detail)
        }
        return result.stdout
    }

    /// Saída de uma leitura; nil se o git terminou com erro (ex.: sem merge-base). Só leituras.
    func readOutput(_ args: [String], in dir: URL) async throws -> String? {
        let result = try await runner.run(args, in: dir, kind: .read, timeout: timeouts.read)
        return result.succeeded ? result.stdout : nil
    }

    /// Assunto do último commit (para pré-preencher o título do PR); nil sem commits.
    public func lastCommitSubject(at checkoutURL: URL) async throws -> String? {
        let out = try await readOutput(["log", "-1", "--format=%s"], in: checkoutURL)?.trimmed
        return (out ?? "").isEmpty ? nil : out
    }

    private func refExists(_ ref: String, in repo: URL) async throws -> Bool {
        let result = try await runner.run(["show-ref", "--verify", "--quiet", ref], in: repo, kind: .read,
                                          timeout: timeouts.read)
        if result.exitCode == 0 { return true }
        if result.exitCode == 1 { return false }
        throw GitError.commandFailed(operation: "show-ref", exitCode: result.exitCode, stderr: result.stderr.trimmed)
    }

    private func branchTaken(_ branch: String, in repo: URL) async throws -> Bool {
        if try await refExists("refs/heads/\(branch)", in: repo) { return true }
        return try await refExists("refs/remotes/origin/\(branch)", in: repo)
    }

    private func validateBranchName(_ name: String, in repo: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\n"), !name.contains("\0") else {
            throw GitError.invalidBranchName(name)
        }
        let result = try await runner.run(["check-ref-format", "--branch", name], in: repo, kind: .read,
                                          timeout: timeouts.read)
        guard result.succeeded else { throw GitError.invalidBranchName(name) }
    }

    private func resolvedCommit(_ ref: String, in repo: URL) async throws -> String {
        let result = try await runner.run(["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], in: repo,
                                          kind: .read, timeout: timeouts.read)
        let value = result.stdout.trimmed
        guard result.succeeded, !value.isEmpty else { throw GitError.baseRefMissing(ref) }
        return value
    }

    /// Base `origin/<default>` com fetch opcional; sem `origin`, usa o branch padrão local.
    private func resolveBase(_ explicit: String?, in repo: URL, policy: GitFetchPolicy,
                             fetched: inout Bool, progress: (@Sendable (GitWorktreePhase) -> Void)? = nil) async throws -> String {
        if let explicit {
            guard !explicit.hasPrefix("-") else { throw GitError.baseRefMissing(explicit) }
            _ = try await resolvedCommit(explicit, in: repo)
            return explicit
        }
        let hasOrigin = try await runner.run(["remote", "get-url", "origin"], in: repo, kind: .read,
                                             timeout: timeouts.read).succeeded
        let name = try await defaultBranch(in: repo)
        guard hasOrigin else {
            _ = try await resolvedCommit(name, in: repo)
            return name
        }
        if policy == .fetchFirst {
            progress?(.fetching)
            let result: GitCommandResult
            do {
                result = try await runner.run(["fetch", "origin", name], in: repo, kind: .write, timeout: timeouts.fetch)
            } catch let error as GitError {
                if case .timedOut = error { throw GitError.fetchFailed("O fetch excedeu o tempo limite.") }
                throw error
            }
            guard result.succeeded else { throw GitError.fetchFailed(result.stderr.trimmed) }
            fetched = true
        }
        let base = "origin/\(name)"
        _ = try await resolvedCommit(base, in: repo)
        return base
    }

    /// Primeiro par (pasta, branch) livre: `slug`, `slug-2`, `slug-3`…
    private func pickNames(_ plan: CreationPlan, parent: URL, in repo: URL) async throws -> (URL, String) {
        let branchPrefix: String
        if let slash = plan.branch.lastIndex(of: "/"), plan.autoSuffix {
            branchPrefix = String(plan.branch[...slash])
        } else {
            branchPrefix = ""
        }
        for attempt in 1...200 {
            let slug = GitNaming.candidate(plan.slug, attempt: attempt)
            let dir = parent.appendingPathComponent(slug, isDirectory: true)
            if Self.isOccupied(dir) { continue }
            guard plan.kind == .newBranch else { return (dir, plan.branch) }
            let branch = plan.autoSuffix ? branchPrefix + slug : plan.branch
            if plan.autoSuffix, try await branchTaken(branch, in: repo) { continue }
            return (dir, branch)
        }
        throw GitError.destinationOccupied(parent.appendingPathComponent(plan.slug).path)
    }

    private static func isOccupied(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            // Link simbólico quebrado também ocupa o nome.
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        }
        guard isDirectory.boolValue else { return true }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return true }
        return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]).isEmpty
    }

    /// Remove só o que esta chamada criou: o branch (se ainda existe e o worktree não foi registrado) e a
    /// pasta vazia. Retorna se tudo ficou limpo.
    private func rollback(repo: URL, branch: String?, tip: String?, destination: URL,
                          existedBefore: Bool) async -> Bool {
        var clean = true
        let listed = (try? await listWorktrees(in: repo)) ?? []
        let registered = listed.contains { URL(fileURLWithPath: $0.path).canonicalPath.path == destination.path }
        if registered { return false }
        if let branch {
            // O branch pode ter sido criado por esta chamada, mas só apagamos se nenhum worktree o usa.
            let head = try? await runner.run(["show-ref", "--verify", "--hash", "refs/heads/\(branch)"], in: repo,
                                             kind: .read, timeout: timeouts.read)
            if head?.succeeded == true {
                // Só apaga o branch que ainda aponta para o commit inicial desta chamada.
                if let tip, head?.stdout.trimmed == tip {
                    let deleted = try? await runner.run(["branch", "-D", "--", branch], in: repo, kind: .write,
                                                        timeout: timeouts.write)
                    if deleted?.succeeded != true { clean = false }
                } else {
                    clean = false
                }
            }
        }
        if !existedBefore, FileManager.default.fileExists(atPath: destination.path) {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: destination.path), items.isEmpty {
                do { try FileManager.default.removeItem(at: destination) } catch { clean = false }
            } else {
                clean = false
            }
        }
        return clean
    }

    private func locate(_ worktreePath: URL, in repositoryURL: URL) async throws -> (URL, GitWorktreeInfo) {
        guard let info = try await detectRepository(at: repositoryURL) else {
            throw GitError.notARepository(repositoryURL.path)
        }
        let wanted = worktreePath.canonicalPath.path
        let all = try await listWorktrees(in: info.mainRootURL)
        guard let entry = all.first(where: { URL(fileURLWithPath: $0.path).canonicalPath.path == wanted }) else {
            throw GitError.worktreeNotFound(worktreePath.path)
        }
        return (info.mainRootURL, entry)
    }

    private func removalReport(for entry: GitWorktreeInfo, repositoryURL: URL) async throws -> WorktreeRemovalReport {
        let url = URL(fileURLWithPath: entry.path, isDirectory: true)
        var changed = 0, untracked = 0, conflicted = 0
        var unpublished: Int?
        if FileManager.default.fileExists(atPath: url.path) {
            let status = try await status(at: url)
            changed = status.changedFiles
            untracked = status.untrackedFiles
            conflicted = status.conflictedFiles
            unpublished = try await unpublishedCommits(at: url, hasUpstream: status.upstream != nil)
        }
        return WorktreeRemovalReport(path: entry.path, branch: entry.branch, changedFiles: changed,
                                     untrackedFiles: untracked, conflictedFiles: conflicted,
                                     unpublishedCommits: unpublished)
    }

    /// `@{u}..HEAD`; sem upstream, commits à frente de `origin/<default>` (nil se não houver base).
    private func unpublishedCommits(at checkout: URL, hasUpstream: Bool) async throws -> Int? {
        var range = "@{u}..HEAD"
        if !hasUpstream {
            guard let name = try? await defaultBranch(in: checkout) else { return nil }
            let remote = try await refExists("refs/remotes/origin/\(name)", in: checkout)
            range = "\(remote ? "origin/" : "")\(name)..HEAD"
        }
        let result = try await runner.run(["rev-list", "--count", range], in: checkout, kind: .read,
                                          timeout: timeouts.read)
        return result.succeeded ? Int(result.stdout.trimmed) : nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
