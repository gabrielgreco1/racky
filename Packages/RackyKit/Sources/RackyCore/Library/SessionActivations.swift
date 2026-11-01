import RackyStore
import Foundation

/// Item ligado só numa sessão (06 §4.2). Guarda o caminho (a fonte da verdade é o arquivo nativo), nunca o conteúdo.
public struct ActivationRef: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var kind: String
    public var name: String
    public var path: String

    public init(id: String, kind: String, name: String, path: String) {
        self.id = id; self.kind = kind; self.name = name; self.path = path
    }

    public init(_ item: LibraryEntry) { self.init(id: item.id, kind: item.kind.rawValue, name: item.name, path: item.path) }
}

/// Ativação aditiva por sessão: persistida no `ui_state` (`library.activations`) e lida no lançamento do Claude. O que cada
/// terminal carregou no último start (`noteLaunched`) diz se há mudança esperando o próximo lançamento (`Applies on next launch`).
public actor SessionActivationStore {
    public static let uiStateKey = "library.activations"

    private var store: RackyStore?
    private var refs: [UUID: [ActivationRef]] = [:]
    private var launched: [UUID: Set<String>] = [:]
    private var continuation: AsyncStream<UUID>.Continuation?

    public init(store: RackyStore? = nil) { self.store = store }

    /// Sessões cujas ativações mudaram (um consumidor).
    public func changes() -> AsyncStream<UUID> {
        let (stream, cont) = AsyncStream.makeStream(of: UUID.self, bufferingPolicy: .bufferingNewest(16))
        continuation = cont
        return stream
    }

    public func attach(store: RackyStore) async {
        self.store = store
        let saved = (try? await store.uiState(Self.uiStateKey, as: [String: [ActivationRef]].self)) ?? [:]
        for (key, value) in saved { if let id = UUID(uuidString: key) { refs[id] = value } }
    }

    public func refs(for session: UUID) -> [ActivationRef] { refs[session] ?? [] }
    public func ids(for session: UUID) -> Set<String> { Set(refs(for: session).map(\.id)) }

    @discardableResult
    public func set(_ ref: ActivationRef, on: Bool, session: UUID) async -> Bool {
        var list = refs[session] ?? []
        let present = list.contains { $0.id == ref.id }
        guard present != on else { return false }
        if on { list.append(ref) } else { list.removeAll { $0.id == ref.id } }
        refs[session] = list.isEmpty ? nil : list
        await persist()
        continuation?.yield(session)
        return true
    }

    /// A sessão foi apagada: as ativações dela também.
    public func forget(session: UUID) async {
        guard refs.removeValue(forKey: session) != nil else { return }
        launched[session] = nil
        await persist()
    }

    /// O lançamento levou exatamente estes itens (o banner `Applies on next launch` compara com o atual).
    public func noteLaunched(session: UUID, ids: Set<String>) {
        launched[session] = ids
        continuation?.yield(session)
    }

    /// `nil` = nenhum agente da sessão lançou ainda neste app (nada a aplicar).
    public func launchedIDs(session: UUID) -> Set<String>? { launched[session] }

    /// Há diferença entre o que a sessão quer e o que o último lançamento levou.
    public func hasPendingChange(session: UUID) -> Bool {
        guard let launched = launched[session] else { return false }
        return launched != ids(for: session)
    }

    private func persist() async {
        guard let store else { return }
        var out: [String: [ActivationRef]] = [:]
        for (id, list) in refs { out[id.uuidString] = list }
        try? await store.setUIState(Self.uiStateKey, out)
    }
}
