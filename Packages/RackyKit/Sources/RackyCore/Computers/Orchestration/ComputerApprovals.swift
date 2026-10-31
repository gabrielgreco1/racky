import RackyDocker
import RackyProtocol
import Foundation

// F12 (modo Ask), 07 §4.2. Quando o pai chama `boxes_reserve` numa sessão em modo Ask, o app mostra um card de aprovação e a ferramenta
// espera a decisão ("help-style": nunca mais de ~45 s numa chamada; devolve `pending` e o pai repete). Full access cria direto.

/// Um pedido de computador à espera do usuário (card no topo do pane, item no Inbox, notificação).
public struct ComputerApprovalRequest: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `boxes_reserve` do pai (modo Ask).
        case computer
        /// Gatilho de spawn: um subagente comum vai mexer com web (`Give this subagent a computer?`).
        case spawn
    }

    public var kind: Kind = .computer
    /// Só no `spawn`: o que o subagente vai fazer (descrição do spawn), para o card.
    public var subject: String?
    public var id: String
    public var parentID: String
    public var sessionID: UUID?
    public var sessionTitle: String
    public var names: [String]
    public var display: ComputerDisplay
    /// Nome do proxy pedido (`direct` quando não há).
    public var proxy: String
    public var createdAt: Date
    /// CLI do agente pai: o card diz `Claude`, `Codex` ou `OpenCode` wants a computer.
    public var provider: TerminalProvider
    /// O que sai do `work/` quando o computador terminar (o botão ao lado do proxy no card).
    public var leftovers: LeftoversPolicy = .keep

    public init(
        id: String = UUID().uuidString.lowercased(), kind: Kind = .computer, subject: String? = nil, parentID: String, sessionID: UUID?,
        sessionTitle: String, names: [String], display: ComputerDisplay, proxy: String, createdAt: Date = Date(), provider: TerminalProvider = .claude
    ) {
        self.provider = provider
        self.kind = kind; self.subject = subject
        self.id = id; self.parentID = parentID; self.sessionID = sessionID; self.sessionTitle = sessionTitle; self.names = names
        self.display = display; self.proxy = proxy; self.createdAt = createdAt
    }

    /// `phoenix-az` ou `phoenix-az, austin-tx`.
    public var computerName: String { names.joined(separator: ", ") }
    public var displayLabel: String {
        switch display {
        case .headless: "Headless"
        case .desktop: "Desktop"
        case .http: "HTTP"
        }
    }
    public var proxyLabel: String { proxy == "direct" ? "Direct" : proxy }
    /// Nome do agente pai na UI (`Claude`, `Codex`, `OpenCode`).
    public var agentName: String { provider.computerAgentName }
    /// `Claude wants a computer · phoenix-az · Headless · Direct` (03 §16, F12).
    public var summary: String {
        if kind == .spawn { return "Give this subagent a computer?" + (subject.map { " · \($0)" } ?? "") }
        let noun = names.count == 1 ? "a computer" : "\(names.count) computers"
        return "\(agentName) wants \(noun) · \(computerName) · \(displayLabel) · \(proxyLabel)"
    }
}

public enum ComputerApprovalDecision: String, Sendable, Equatable, CaseIterable {
    case allow
    /// `Allow for this session`: o resto da sessão não pergunta mais.
    case allowForSession
    case deny
}

/// Fila de pedidos do modo Ask. Cada pedido tem a chave `pai + nomes + display`: quando o pai repete a chamada (porque a anterior
/// devolveu `pending`) ele reencontra o mesmo pedido, e uma decisão tomada com o pai fora da espera fica guardada para a próxima chamada.
public actor ComputerApprovalCenter {
    public enum Outcome: Sendable, Equatable {
        case allowed
        case denied
        /// Sem decisão ainda: o pai deve repetir a chamada.
        case pending(requestID: String)
    }

    private struct Entry {
        var request: ComputerApprovalRequest
        var key: String
        var decision: ComputerApprovalDecision?
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var allowedSessions: Set<String> = []
    private var chosenProxies: [String: String] = [:]
    /// Escolha de limpeza feita no card, por sessão (`sessionKey`): vale para os próximos computadores dela.
    private var chosenLeftovers: [String: LeftoversPolicy] = [:]
    /// "Allow" do gatilho de spawn vale para a próxima reserva do mesmo pai (sem um segundo card).
    private var grants: [String: Int] = [:]
    private var observer: (@Sendable ([ComputerApprovalRequest]) -> Void)?

    public init() {}

    /// Recebe a lista de pedidos abertos a cada mudança (a UI mostra card, Inbox e notificação por pedido novo).
    public func setObserver(_ observer: (@Sendable ([ComputerApprovalRequest]) -> Void)?) {
        self.observer = observer
        observer?(open)
    }

    /// Pedidos ainda sem decisão, do mais antigo para o mais novo.
    public var open: [ComputerApprovalRequest] { order.compactMap { entries[$0] }.filter { $0.decision == nil }.map(\.request) }

    static func key(_ request: ComputerApprovalRequest) -> String {
        "\(request.kind.rawValue)|\(request.subject ?? "")|\(request.parentID)|\(request.names.sorted().joined(separator: ","))|\(request.display.rawValue)"
    }

    /// Chave de "Allow for this session": a sessão do app; sem sessão conhecida, o próprio pai.
    static func sessionKey(_ request: ComputerApprovalRequest) -> String { request.sessionID?.uuidString ?? request.parentID }

    public func isSessionAllowed(_ request: ComputerApprovalRequest) -> Bool { allowedSessions.contains(Self.sessionKey(request)) }
    public func allowSession(sessionID: UUID) { allowedSessions.insert(sessionID.uuidString) }
    public func grant(parent: String) { grants[parent, default: 0] += 1 }

    /// Tira um pedido da fila sem decisão (o prazo do hook estourou: o card some e o subagente comum segue).
    public func withdraw(id: String) {
        guard entries[id] != nil else { return }
        let waiters = entries[id]?.waiters ?? [:]
        remove(id)
        for continuation in waiters.values { continuation.resume() }
    }

    /// Espera a decisão por até `waitS` segundos.
    public func authorize(_ request: ComputerApprovalRequest, waitS: TimeInterval) async -> Outcome {
        if allowedSessions.contains(Self.sessionKey(request)) { return .allowed }
        if request.kind == .computer, let n = grants[request.parentID], n > 0 {
            grants[request.parentID] = n - 1
            return .allowed
        }
        let key = Self.key(request)
        var id: String
        if let existing = order.first(where: { entries[$0]?.key == key }) {
            id = existing
            if let decision = entries[existing]?.decision {  // decidido com o pai fora da espera: consome
                remove(existing, notify: false)
                return decision == .deny ? .denied : .allowed
            }
        } else {
            id = request.id
            entries[id] = Entry(request: request, key: key)
            order.append(id)
            notify()
        }
        if waitS > 0 { await wait(for: id, seconds: waitS) }
        guard let entry = entries[id] else { return .denied }  // cancelado (o pai terminou)
        if let decision = entry.decision {
            remove(id, notify: false)
            return decision == .deny ? .denied : .allowed
        }
        return .pending(requestID: id)
    }

    private func wait(for id: String, seconds: TimeInterval) async {
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard entries[id] != nil, entries[id]?.decision == nil else { continuation.resume(); return }
            entries[id]?.waiters[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.timeout(id: id, token: token)
            }
        }
    }

    private func timeout(id: String, token: UUID) {
        guard let continuation = entries[id]?.waiters.removeValue(forKey: token) else { return }
        continuation.resume()
    }

    /// F29: o usuário escolheu o proxy no card. Vale para este pedido e vira o padrão da sessão. `nil` = Direct.
    @discardableResult
    public func setProxy(id: String, proxy: String?) -> Bool {
        guard entries[id] != nil, entries[id]?.decision == nil else { return false }
        entries[id]?.request.proxy = proxy ?? "direct"
        if let parent = entries[id]?.request.parentID { chosenProxies[parent] = proxy ?? "direct" }
        notify()
        return true
    }

    /// O usuário escolheu no card o que sai do `work/` quando o computador terminar. Vale para este pedido e para o resto da sessão.
    @discardableResult
    public func setLeftovers(id: String, _ policy: LeftoversPolicy) -> Bool {
        guard let entry = entries[id], entry.decision == nil else { return false }
        entries[id]?.request.leftovers = policy
        chosenLeftovers[Self.sessionKey(entry.request)] = policy
        notify()
        return true
    }

    /// A escolha de limpeza da sessão do pai, se houve uma no card.
    public func leftovers(parentID: String, sessionID: UUID?) -> LeftoversPolicy? { chosenLeftovers[sessionID?.uuidString ?? parentID] }

    /// Proxy que o usuário escolheu no card de um pedido do pai (consumido na autorização).
    func takeChosenProxy(parent: String) -> String? { chosenProxies.removeValue(forKey: parent) }

    /// A decisão do usuário. `false` se o pedido já não existe (outro clique, pai encerrado).
    @discardableResult
    public func decide(id: String, _ decision: ComputerApprovalDecision) -> Bool {
        guard var entry = entries[id], entry.decision == nil else { return false }
        entry.decision = decision
        let waiters = entry.waiters
        entry.waiters = [:]
        entries[id] = entry
        if decision == .allowForSession { allowedSessions.insert(Self.sessionKey(entry.request)) }
        notify()
        for continuation in waiters.values { continuation.resume() }
        return true
    }

    /// O pai terminou (terminal fechado ou relançado): os pedidos dele somem sem decisão.
    public func cancel(parent: String) {
        for id in order where entries[id]?.request.parentID == parent {
            let waiters = entries[id]?.waiters ?? [:]
            remove(id, notify: false)
            for continuation in waiters.values { continuation.resume() }
        }
        notify()
    }

    private func remove(_ id: String, notify shouldNotify: Bool = true) {
        entries[id] = nil
        order.removeAll { $0 == id }
        if shouldNotify { notify() }
    }

    private func notify() { observer?(open) }
}

/// O que o `ComputerToolService` pergunta antes de reservar para o pai.
public enum ReserveAuthorization: Sendable, Equatable {
    case proceed
    /// F29: o usuário escolheu este proxy no card de aprovação; vale no lugar do que o agente pediu.
    case proceedWith(proxy: String)
    /// Sem decisão ainda: devolve isto ao pai (não é erro) e ele repete a chamada.
    case pending(JSON)
}

/// Resposta do gatilho de spawn ao hook `PreToolUse` do helper.
public enum SpawnVerdict: Sendable, Equatable {
    case allow
    case block(reason: String)
}

public protocol ReserveGating: Sendable {
    func authorize(parent: String, _ request: ReserveRequest) async throws -> ReserveAuthorization
    /// Gatilho de spawn (F12). Padrão: deixa passar.
    func spawnGuard(parent: String, _ input: SubagentSpawnGuard.Input) async -> SpawnVerdict
}

extension ReserveGating {
    public func spawnGuard(parent: String, _ input: SubagentSpawnGuard.Input) async -> SpawnVerdict { .allow }
}

/// O que o app sabe de um pai (lançamento de um terminal Claude com "Subagent computers" ligado).
public struct ParentInfo: Sendable, Equatable {
    public var parentID: String
    public var sessionID: UUID?
    public var sessionTitle: String
    public var mode: SubagentComputersMode
    /// F29: proxy padrão da sessão (card de aprovação, composer); `nil` = padrão global de Settings.
    public var proxy: String?
    /// CLI do pai (decide a injeção; Claude por padrão).
    public var provider: TerminalProvider
    /// Quem roda os subagentes da sessão no lançamento (decide o texto do pai); o valor vivo vem do Store a cada spawn.
    public var harness: SubagentHarness
    public init(
        parentID: String, sessionID: UUID?, sessionTitle: String, mode: SubagentComputersMode, proxy: String? = nil, provider: TerminalProvider = .claude,
        harness: SubagentHarness = .claude
    ) {
        self.harness = harness
        self.parentID = parentID; self.sessionID = sessionID; self.sessionTitle = sessionTitle; self.mode = mode; self.proxy = proxy; self.provider = provider
    }
}

public actor ParentDirectory {
    private var parents: [String: ParentInfo] = [:]
    public init() {}
    public func register(_ info: ParentInfo) { parents[info.parentID] = info }
    public func remove(_ parentID: String) { parents[parentID] = nil }
    /// F29: escolhe o proxy padrão da sessão do pai (e das próximas reservas dele); `nil` volta ao padrão global.
    public func setProxy(_ proxy: String?, for parentID: String) {
        parents[parentID]?.proxy = proxy
        if parents[parentID] != nil { onProxyChange?(parentID, proxy) }
        if let session = parents[parentID]?.sessionID { sessionProxies[session] = proxy }
    }
    /// O proxy escolhido para a sessão (o Claude relançado ganha identidade nova, a sessão não muda).
    public func proxy(forSession id: UUID) -> String? { sessionProxies[id] }
    private var sessionProxies: [UUID: String] = [:]
    /// O app persiste a escolha para o pai que sobreviver a um reinício.
    private var onProxyChange: (@Sendable (_ parentID: String, _ proxy: String?) -> Void)?
    public func observeProxyChanges(_ hook: (@Sendable (_ parentID: String, _ proxy: String?) -> Void)?) { onProxyChange = hook }
    public func info(_ parentID: String) -> ParentInfo? { parents[parentID] }
    public var all: [ParentInfo] { Array(parents.values) }
}

/// Porta do modo da sessão: Full cria direto; Ask espera a decisão; Off não chega a registrar pai (as ferramentas nem existem).
public struct SubagentComputersGate: ReserveGating {
    public let parents: ParentDirectory
    public let approvals: ComputerApprovalCenter
    /// Quanto uma chamada espera antes de devolver `pending` (45 s; os testes encurtam).
    public var waitSeconds: TimeInterval
    /// Quanto o gatilho de spawn espera o card antes de deixar o subagente comum seguir (menos que o prazo do hook).
    public var spawnWaitSeconds: TimeInterval
    /// F29: o proxy que o scheduler aplicaria (para o card mostrar o efetivo).
    public var effectiveProxy: (@Sendable (_ parent: String, _ requested: String?) async -> String)?
    /// A escolha de limpeza que o computador receberia (o card mostra; o scheduler grava a mesma no `box.json`).
    public var effectiveLeftovers: (@Sendable (_ parent: String) async -> LeftoversPolicy)?

    public init(
        parents: ParentDirectory, approvals: ComputerApprovalCenter, waitSeconds: TimeInterval = 45,
        spawnWaitSeconds: TimeInterval = TimeInterval(SubagentSpawnGuard.appBudgetSeconds),
        effectiveProxy: (@Sendable (_ parent: String, _ requested: String?) async -> String)? = nil,
        effectiveLeftovers: (@Sendable (_ parent: String) async -> LeftoversPolicy)? = nil
    ) {
        self.effectiveProxy = effectiveProxy; self.effectiveLeftovers = effectiveLeftovers
        self.parents = parents; self.approvals = approvals; self.waitSeconds = waitSeconds; self.spawnWaitSeconds = spawnWaitSeconds
    }

    public func spawnGuard(parent: String, _ input: SubagentSpawnGuard.Input) async -> SpawnVerdict {
        guard let info = await parents.info(parent) else { return .allow }
        switch SubagentSpawnGuard.decide(mode: info.mode, input) {
        case .allow: return .allow
        case .block(let reason): return .block(reason: reason)
        case .askUser:
            let subject = input.description.isEmpty ? String(input.prompt.prefix(80)) : input.description
            let asked = ComputerApprovalRequest(
                kind: .spawn, subject: subject, parentID: parent, sessionID: info.sessionID, sessionTitle: info.sessionTitle, names: [subject],
                display: .headless, proxy: "direct", provider: info.provider)
            switch await approvals.authorize(asked, waitS: spawnWaitSeconds) {
            case .allowed:
                await approvals.grant(parent: parent)
                return .block(reason: SubagentSpawnGuard.blockReason)
            case .denied: return .allow
            case .pending(let id):
                await approvals.withdraw(id: id)  // o app demorou: o subagente comum segue
                return .allow
            }
        }
    }

    public func authorize(parent: String, _ request: ReserveRequest) async throws -> ReserveAuthorization {
        guard let info = await parents.info(parent), info.mode != .off else {
            throw ToolError(.blockedByPolicy, "Subagent computers is off for this session; use normal subagents. The user can turn it on in the session settings.")
        }
        if info.mode == .full { return .proceed }
        // F29: o card mostra o proxy que a reserva receberia (pedido do agente > padrão da sessão > padrão global).
        let shown = await effectiveProxy?(parent, request.proxy) ?? request.proxy ?? "direct"
        var asked = ComputerApprovalRequest(
            parentID: parent, sessionID: info.sessionID, sessionTitle: info.sessionTitle, names: request.names, display: request.display,
            proxy: shown, provider: info.provider)
        asked.leftovers = await effectiveLeftovers?(parent) ?? .keep
        switch await approvals.authorize(asked, waitS: waitSeconds) {
        case .allowed:
            if let chosen = await approvals.takeChosenProxy(parent: parent) {
                await parents.setProxy(chosen == "direct" ? nil : chosen, for: parent)
                return .proceedWith(proxy: chosen)
            }
            return .proceed
        case .denied:
            throw ToolError(
                .blockedByPolicy,
                "The user denied this computer request (\(asked.computerName)). Do not ask again for the same targets; continue without a computer or tell the user.")
        case .pending(let id):
            return .pending([
                "status": "pending", "request_id": .string(id), "retry_after_s": 5,
                "message": "Waiting for the user to approve computer access in Racky. Call boxes_reserve again with the same arguments to keep waiting.",
            ])
        }
    }
}

extension TerminalProvider {
    /// Como o agente se chama nos textos de computadores ("Claude is using", "Hand back to Codex?"); não é o nome do produto.
    public var computerAgentName: String {
        switch self {
        case .codex: "Codex"
        case .opencode: "OpenCode"
        default: "Claude"
        }
    }
}
