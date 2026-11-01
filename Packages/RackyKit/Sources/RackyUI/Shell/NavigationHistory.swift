import Foundation

/// Lugar onde o usuário esteve no centro da janela: sessão, terminal, viewer de computador ou uma página.
enum NavDestination: Equatable, Sendable {
    case session(UUID)
    case terminal(session: UUID, terminal: UUID)
    case viewer(String)
    case computers
    case batch(String)
    case inbox
    case library
    case datasets
    case dataset(String)
}

/// Histórico de navegação (⌥⌘←/→ e os botões ←/→ da faixa de topo). Linear: navegar a partir do meio descarta o "futuro".
/// Puro e testável; quem aplica cada destino é o `AppEnvironment`.
@MainActor
struct NavigationHistory {
    static let limit = 100

    private(set) var entries: [NavDestination] = []
    private(set) var index = -1

    var current: NavDestination? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Registra o destino atual (ignora repetido).
    mutating func record(_ destination: NavDestination) {
        if current == destination { return }
        // A sessão ainda sem terminal carregado vira o terminal quando ele chega (uma parada só no histórico).
        if case .session(let id)? = current, case .terminal(let session, _) = destination, session == id, index == entries.count - 1 {
            entries[index] = destination
            return
        }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(destination)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// Anda `delta` posições pulando destinos que não existem mais (`isValid`). `nil` se não há para onde ir.
    mutating func move(_ delta: Int, isValid: (NavDestination) -> Bool) -> NavDestination? {
        var i = index + delta
        while entries.indices.contains(i) {
            if isValid(entries[i]) {
                index = i
                return entries[i]
            }
            i += delta
        }
        return nil
    }

    /// Há para onde ir nessa direção, ignorando destinos mortos.
    func canMove(_ delta: Int, isValid: (NavDestination) -> Bool) -> Bool {
        var i = index + delta
        while entries.indices.contains(i) {
            if isValid(entries[i]) { return true }
            i += delta
        }
        return false
    }
}
