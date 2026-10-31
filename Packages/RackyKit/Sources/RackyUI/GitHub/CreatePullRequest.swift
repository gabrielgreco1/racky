import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation
import Observation
import SwiftUI

/// Estado do overlay "Create Pull Request" (03 §16.9c, 06 §5.6). Nada roda até `submit`.
@MainActor @Observable
final class CreatePRModel {
    enum Phase: Equatable { case editing, running, failed(String) }

    let sessionID: UUID
    let directory: URL
    let repo: GitHubRepoRef
    let head: String
    let push: PullRequestPushNeed
    var title: String
    var base: String
    var body = ""
    var draft = false
    var phase: Phase = .editing

    init(sessionID: UUID, directory: URL, repo: GitHubRepoRef, head: String, push: PullRequestPushNeed, title: String, base: String) {
        self.sessionID = sessionID
        self.directory = directory
        self.repo = repo
        self.head = head
        self.push = push
        self.title = title
        self.base = base
    }

    var isRunning: Bool { phase == .running }
    var titleMissing: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var errorText: String? {
        if case .failed(let text) = phase { return text }
        return nil
    }

    func request() -> CreatePullRequestRequest {
        CreatePullRequestRequest(
            repoDirectory: directory, repo: repo, head: head, base: base.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title, body: body, draft: draft, push: push)
    }

    /// Os comandos que vão rodar, para a prévia do overlay (o corpo vai por arquivo: `<body file>`).
    var preview: String {
        var request = request()
        if titleMissing { request.title = "…" }
        return (try? CreatePullRequestPlan.make(request, bodyFilePath: "<body file>").preview) ?? ""
    }

    var summaryLine: String {
        push == .push
            ? String(localized: "Pushes \(head) and opens a pull request on GitHub.", bundle: .module)
            : String(localized: "Opens a pull request on GitHub.", bundle: .module)
    }
}

extension GitHubController {
    var isCreatePROpen: Bool { overlays.top?.spec.name == "createPR" && createModel != nil }

    /// Abre o overlay com título, base, rascunho e corpo pré-preenchidos. Não envia nada.
    @discardableResult
    func openCreatePR(sessionID: UUID?, from origin: A11yID? = nil) async throws -> String {
        let action = ActionID.gitCreatePR
        if isCreatePROpen { return "open" }
        guard let session = session(sessionID) else {
            throw ActionError.failed(action, message: String(localized: "Select a session first.", bundle: .module))
        }
        guard let branch = session.branch, !branch.isEmpty else {
            throw ActionError.failed(action, message: String(localized: "This session has no branch.", bundle: .module))
        }
        if hasActivePullRequest(session.id) {
            throw ActionError.failed(action, message: String(localized: "This branch already has a pull request.", bundle: .module))
        }
        guard let repo = await resolveRepo(session.folderPath) else {
            throw ActionError.failed(action, message: String(localized: "This repository isn't on GitHub.", bundle: .module))
        }
        let directory = URL(fileURLWithPath: session.folderPath)
        let status = (try? await git.status(at: directory)) ?? session.status
        let base = (try? await git.defaultBranch(in: directory)) ?? "main"
        let subject = (try? await git.lastCommitSubject(at: directory)) ?? nil
        let model = CreatePRModel(
            sessionID: session.id, directory: directory, repo: repo, head: branch,
            push: PullRequestPushNeed.from(upstream: status?.upstream, ahead: status?.ahead),
            title: subject ?? session.title, base: base)
        createModel = model
        let opened = overlays.present(
            OverlaySpec(
                name: "createPR", id: .overlayCreatePR, width: GitHubMetrics.overlayWidth, cancelAction: .dialogCreatePRCancel,
                dismissOnScrim: { !model.isRunning && model.body.isEmpty },
                content: { AnyView(CreatePRView(model: model)) }),
            from: origin)
        guard opened else {
            createModel = nil
            throw ActionError.failed(action, message: String(localized: "Close the open dialog first.", bundle: .module))
        }
        return "opened"
    }

    /// `[Create]`: push (se preciso) e `gh pr create`. Erro mantém o overlay com o texto e `[Try Again]`.
    @discardableResult
    func submitCreatePR() async throws -> String {
        let action = ActionID.dialogCreatePRSubmit
        guard let model = createModel, isCreatePROpen else { throw ActionError.failed(action, message: "The Create Pull Request dialog isn't open") }
        guard !model.isRunning else { return "running" }
        guard !model.titleMissing else { throw ActionError.failed(action, message: String(localized: "Add a title.", bundle: .module)) }
        let bodyPath = temporaryDirectory.appendingPathComponent("racky-pr-\(UUID().uuidString).md").path
        let plan: CreatePullRequestPlan
        do {
            plan = try CreatePullRequestPlan.make(model.request(), bodyFilePath: bodyPath)
        } catch CreatePullRequestPlanError.invalidBranch(let name) {
            throw ActionError.failed(action, message: String(localized: "\(name) isn't a valid branch name.", bundle: .module))
        } catch {
            throw ActionError.failed(action, message: String(localized: "Add a title.", bundle: .module))
        }
        model.phase = .running
        do {
            let result = try await plan.execute(git: gitRunner, gh: ghRunner)
            if createModel === model, isCreatePROpen { overlays.dismiss(.action) }
            self.createModel = nil
            let number = result.url.flatMap { URL(string: $0)?.lastPathComponent }.flatMap(Int.init)
            toasts.show(
                kind: .success,
                title: number.map { String(localized: "Opened PR #\($0).", bundle: .module) } ?? String(localized: "Opened the pull request.", bundle: .module),
                detail: result.url)
            await tick(force: true)
            return result.url ?? "created"
        } catch {
            let text = Self.describe(error)
            model.phase = .failed(text)
            throw ActionError.failed(action, message: text)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case GitHubError.commandFailed(let command, _, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? String(localized: "\(command) failed.", bundle: .module) : detail
        case GitHubError.ghNotInstalled:
            return String(localized: "Install the GitHub CLI first: brew install gh", bundle: .module)
        case GitHubError.timedOut:
            return String(localized: "GitHub took too long to answer.", bundle: .module)
        case GitHubError.notAuthenticated:
            return String(localized: "Log in to GitHub CLI first: gh auth login", bundle: .module)
        default:
            return String(localized: "Couldn't create the pull request.", bundle: .module)
        }
    }

    /// `[Open Compare on GitHub]`: `gh pr create --web`. Não faz push nem cria nada pelo app.
    func openCompare() async throws -> String {
        let action = ActionID.dialogCreatePROpenCompare
        guard let model = createModel, isCreatePROpen else { throw ActionError.failed(action, message: "The Create Pull Request dialog isn't open") }
        guard let plan = try? CreatePullRequestPlan.make(model.request().withTitle(model.titleMissing ? model.head : model.title), bodyFilePath: "") else {
            throw ActionError.failed(action, message: String(localized: "Couldn't open GitHub.", bundle: .module))
        }
        do {
            let result = try await ghRunner.run(plan.webAlternative.arguments, in: model.directory, timeout: .seconds(30))
            guard result.succeeded else {
                throw ActionError.failed(action, message: String(GitHubRedaction.redact(result.stderr).prefix(300)))
            }
            return "opened"
        } catch let error as ActionError {
            throw error
        } catch {
            throw ActionError.failed(action, message: Self.describe(error))
        }
    }

    func registerCreatePR(in registry: ActionRegistry) throws {
        try registry.register(
            .gitCreatePR,
            enablement: { [unowned self] in
                guard let session = source.selected() else { return .disabled(reason: String(localized: "Select a session first.", bundle: .module)) }
                if (session.branch ?? "").isEmpty { return .disabled(reason: String(localized: "This session has no branch.", bundle: .module)) }
                if hasActivePullRequest(session.id) { return .disabled(reason: String(localized: "This branch already has a pull request.", bundle: .module)) }
                if notOnGitHub.contains(session.folderPath) { return .disabled(reason: String(localized: "This repository isn't on GitHub.", bundle: .module)) }
                return .enabled
            }
        ) { [unowned self] arg in
            try await openCreatePR(sessionID: resolvedArgument(arg), from: overlays.live.isEmpty ? .rightPanelSourceControlCreatePR : nil)
        }
        func edit(_ id: ActionID, _ change: @escaping @MainActor (CreatePRModel, ActionArgument) -> String) throws {
            try registry.register(id) { [unowned self] arg in
                guard let model = createModel, isCreatePROpen else { throw ActionError.failed(id, message: "The Create Pull Request dialog isn't open") }
                return change(model, arg)
            }
        }
        try edit(.dialogCreatePRSetTitle) { model, arg in
            model.title = arg.value ?? ""
            return model.title
        }
        try edit(.dialogCreatePRSetBase) { model, arg in
            model.base = arg.value ?? ""
            return model.base
        }
        try edit(.dialogCreatePRSetBody) { model, arg in
            model.body = arg.value ?? ""
            return model.body
        }
        try edit(.dialogCreatePRSetDraft) { model, arg in
            model.draft = arg.kind == .set ? arg.value == "on" : !model.draft
            return model.draft ? "on" : "off"
        }
        try registry.register(
            .dialogCreatePRSubmit,
            enablement: { [unowned self] in
                guard let model = createModel, isCreatePROpen else { return .enabled }
                return model.titleMissing ? .disabled(reason: String(localized: "Add a title.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in try await submitCreatePR() }
        try registry.register(.dialogCreatePRRetry) { [unowned self] _ in
            guard let model = createModel, isCreatePROpen else { throw ActionError.failed(.dialogCreatePRRetry, message: "The Create Pull Request dialog isn't open") }
            model.phase = .editing
            return try await submitCreatePR()
        }
        try registry.register(.dialogCreatePROpenCompare) { [unowned self] _ in try await openCompare() }
        try registry.register(.dialogCreatePRCancel) { [unowned self] _ in
            createModel = nil
            overlays.dismiss(.escape)
            return "closed"
        }
    }
}

extension CreatePullRequestRequest {
    fileprivate func withTitle(_ title: String) -> CreatePullRequestRequest {
        var copy = self
        copy.title = title
        return copy
    }
}

/// Overlay "Create Pull Request" (03 §16.9c): título, base, descrição, rascunho, prévia dos comandos e o resultado no próprio overlay.
struct CreatePRView: View {
    let model: CreatePRModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            Text(String(localized: "pr.create.title", defaultValue: "Create Pull Request", bundle: .module))
                .dsFont(DS.Font.composerTitle)
                .foregroundStyle(DS.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                field("Title") {
                    DSTextField(
                        "Pull request title", text: Binding(get: { model.title }, set: { model.title = $0 }), id: .overlayCreatePRTitle,
                        action: .dialogCreatePRSetTitle, autofocus: true, compact: true, mono: false)
                }
                field("Base") {
                    DSTextField(
                        "main", text: Binding(get: { model.base }, set: { model.base = $0 }), id: .overlayCreatePRBase,
                        action: .dialogCreatePRSetBase, compact: true, mono: true)
                }
                field("Description") {
                    DSTextField(
                        "Describe the change (optional)", text: Binding(get: { model.body }, set: { model.body = $0 }), id: .overlayCreatePRBody,
                        action: .dialogCreatePRSetBody, multiline: true)
                }
                DSCheckbox(isOn: model.draft, action: .dialogCreatePRSetDraft, id: .overlayCreatePRDraft, "Draft")
            }
            .overlayGroup(0)
            preview.overlayGroup(1)
            if let message = model.errorText { failure(message).overlayGroup(1) }
            footer.overlayGroup(2)
        }
        .padding(DSMetrics.overlayPadding)
        .disabled(model.isRunning)
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(label, bundle: .module)
                .dsFont(DS.Font.label)
                .foregroundStyle(DS.Color.textSecondary)
            content()
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            Text(verbatim: model.preview)
                .dsFont(DS.Font.monoMicro)
                .foregroundStyle(DS.Color.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s2)
                .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.secondary))
                .a11y(.overlayCreatePRPreview, kind: "text", label: model.preview)
            Text(verbatim: model.summaryLine)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Color.destructive)
            Text(verbatim: message)
                .dsFont(DS.Font.body)
                .foregroundStyle(DS.Color.destructive)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            DSButton(.dialogCreatePRRetry, id: .overlayCreatePRRetry, "Try Again", variant: .outline, size: .sm)
        }
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.destructiveBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.destructiveBorder))
        .a11y(.overlayCreatePRError, kind: "text", label: message)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            DSButton(.dialogCreatePROpenCompare, id: .overlayCreatePRCompare, "Open Compare on GitHub", variant: .ghost, size: .sm)
            Spacer(minLength: DS.Space.s2)
            DSButton(.dialogCreatePRCancel, id: .overlayCreatePRCancel, "Cancel", variant: .outline)
            DSButton(.dialogCreatePRSubmit, id: .overlayCreatePRSubmit, "Create", variant: .primary, loading: model.isRunning ? "Creating…" : nil)
        }
    }
}
