import RackyCore
import Foundation
import Observation

/// Estado do painel "Clone from GitHub" (03 §16.9b, F24), sem SwiftUI: o campo, a lista filtrada, a seleção por teclado e o
/// andamento do clone. Testado sem janela.
@MainActor @Observable
final class CloneRepoModel {
    enum Listing: Equatable {
        case loading
        case ready
        /// Sem login (ou sem `gh`): mostra `Log in to GitHub`; o campo continua aceitando URL pública.
        case loggedOut
        case ghMissing
        case failed(String)
    }

    enum Phase: Equatable {
        case browsing
        case cloning
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Linha `Clone <owner/repo>` do que foi digitado.
            case typed(RepoReference)
            case repository(GitHubRepository)
        }

        var id: String
        var kind: Kind

        var reference: RepoReference {
            switch kind {
            case .typed(let reference): reference
            case .repository(let repo): repo.reference
            }
        }
    }

    private(set) var source = ""
    private(set) var repositories: [GitHubRepository] = []
    var listing: Listing = .loading
    var phase: Phase = .browsing
    private(set) var selectedID: String?
    private(set) var progress: CloneProgress?
    /// O que está sendo clonado (título do progresso).
    private(set) var cloningName = ""
    var now: () -> Date = { Date() }

    // MARK: Entrada

    func setSource(_ text: String) {
        guard text != source else { return }
        source = text
        if case .failed = phase { phase = .browsing }
        reconcileSelection(resetToFirst: true)
    }

    func setRepositories(_ list: [GitHubRepository]) {
        repositories = list
        reconcileSelection(resetToFirst: selectedID == nil)
    }

    var typedReference: RepoReference? { RepoReferenceParser.parse(source) }

    var isSearching: Bool { !source.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Linhas visíveis: a referência digitada (se válida) e depois os repositórios que casam com o texto.
    var rows: [Row] {
        var result: [Row] = []
        if let typed = typedReference {
            result.append(Row(id: "typed:\(typed.cloneURL)", kind: .typed(typed)))
        }
        let typedName = typedReference?.displayName.lowercased()
        for repo in GitHubRepoCatalog.search(source, in: repositories) where repo.nameWithOwner.lowercased() != typedName {
            result.append(Row(id: repo.id, kind: .repository(repo)))
        }
        return result
    }

    var sectionTitle: String {
        isSearching ? String(localized: "Results", bundle: .module) : String(localized: "Recent repositories", bundle: .module)
    }

    var selectedRow: Row? { rows.first { $0.id == selectedID } }

    /// O que `↵` clona: a linha selecionada; sem linhas, o texto digitado se for uma referência.
    var submitReference: RepoReference? { selectedRow?.reference ?? typedReference }

    // MARK: Seleção

    func select(_ id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func move(_ delta: Int) {
        let list = rows
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        selectedID = list[max(0, min(list.count - 1, index + delta))].id
    }

    private func reconcileSelection(resetToFirst: Bool) {
        let list = rows
        if !resetToFirst, let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        selectedID = list.first?.id
    }

    // MARK: Clone

    func beginCloning(_ reference: RepoReference) {
        cloningName = reference.displayName
        progress = CloneProgress(phase: .starting)
        phase = .cloning
    }

    func update(_ progress: CloneProgress) { self.progress = progress }

    func fail(_ message: String) {
        phase = .failed(message)
        progress = nil
    }

    func reset() {
        phase = .browsing
        progress = nil
    }

    var isCloning: Bool { phase == .cloning }

    // MARK: Textos

    /// `Updated 3 days ago` (a data é a do último push).
    func updatedText(for repo: GitHubRepository) -> String? {
        guard let date = repo.activityDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: min(date, now()), relativeTo: now())
        return String(localized: "Updated \(relative)", bundle: .module)
    }

    /// Mensagem curta para uma falha ao listar: o campo continua valendo.
    static func listingMessage(for error: Error) -> Listing {
        switch error {
        case GitHubError.ghNotInstalled: .ghMissing
        case GitHubError.notAuthenticated: .loggedOut
        case GitHubError.timedOut: .failed(String(localized: "GitHub took too long to answer.", bundle: .module))
        case GitHubError.rateLimited: .failed(String(localized: "GitHub is limiting requests. Try again in a minute.", bundle: .module))
        default: .failed(String(localized: "Couldn't load your repositories.", bundle: .module))
        }
    }
}
