import RackyCore
import RackyProtocol
import Foundation

/// Estado de uma ação para quem a renderiza ou dispara (03 §24).
public enum ActionAvailability: Equatable {
    /// Fatia futura: o controle não é renderizado (AC-T28).
    case unavailable(ReleaseSlice)
    /// Sem handler registrado.
    case unregistered
    /// Desabilitada por pré-condição real; `reason` é o tooltip exato.
    case disabled(reason: String)
    case enabled

    public var isEnabled: Bool { self == .enabled }
}

public enum ActionRegistryError: Error, Equatable {
    case duplicate(ActionID)
}

/// Registro de ações (08 AR-134, 03 §24): `ActionID` -> handler, `enabled` e motivo de desabilitado.
/// Menus, botões, context menus, palette e `ctl ui action` disparam a mesma ação por aqui.
/// Implementa `ActionDispatching` (protocolo no Core) para o `CtlServer`.
@MainActor
public final class ActionRegistry: ActionDispatching {
    public typealias Handler = @MainActor (ActionArgument) async throws -> String?
    public typealias Enablement = @MainActor () -> ActionAvailability

    struct Registration {
        let enablement: Enablement
        let handler: Handler
    }

    public let flags: SliceFlags
    private var registrations: [ActionID: Registration] = [:]
    /// Provedores de superfície (árvore, captura, estado), ligados pelo `AppEnvironment`.
    private let surface: any AutomationSurface

    public init(flags: SliceFlags, surface: any AutomationSurface) {
        self.flags = flags
        self.surface = surface
    }

    // MARK: Registro

    /// Registra o handler de uma ação. `enablement` devolve `.enabled` ou `.disabled(reason:)`.
    public func register(
        _ id: ActionID,
        enablement: @escaping Enablement = { .enabled },
        handler: @escaping Handler
    ) throws {
        guard registrations[id] == nil else { throw ActionRegistryError.duplicate(id) }
        registrations[id] = Registration(enablement: enablement, handler: handler)
    }

    /// Troca o handler de uma ação já registrada (testes que observam o que um controle dispara).
    func replace(_ id: ActionID, handler: @escaping Handler) {
        registrations[id] = Registration(enablement: { .enabled }, handler: handler)
    }

    public var registeredIDs: [ActionID] { registrations.keys.sorted() }

    /// Quem mostra ao usuário a falha de um clique (o app liga a um toast de erro). Sem isso o botão engolia o erro e "não
    /// acontecia nada" (o "+" da linha do projeto mandava a ação sem o projeto e falhava em silêncio).
    public var onUIFailure: ((ActionID, String) -> Void)?

    /// Execução vinda de um controle (botão, menu, campo): uma falha vira aviso visível, nunca silêncio. Desabilitada ou de outra
    /// fatia não avisa (o controle já mostra o motivo).
    public func performFromUI(_ id: ActionID, _ arg: ActionArgument) async {
        do {
            _ = try await performOnMain(id, arg)
        } catch ActionError.failed(_, let message) {
            onUIFailure?(id, message)
        } catch ActionError.notRegistered {
            onUIFailure?(id, "This action isn't available right now.")
        } catch {
            return
        }
    }

    public func isRegistered(_ id: ActionID) -> Bool { registrations[id] != nil }

    /// Índice de ações (03 §24) com o que está registrado e o estado atual.
    public func index() -> [(spec: ActionSpec, availability: ActionAvailability)] {
        ActionID.catalog.map { ($0, availability(of: $0.id)) }
    }

    // MARK: Estado

    public func availability(of id: ActionID) -> ActionAvailability {
        let slice = id.spec.slice
        // F13: sem restrição explícita de fatia, o que tem handler vale; o gating fica só para controles sem handler.
        if !flags.restricted, let reg = registrations[id] { return reg.enablement() }
        guard flags.isEnabled(slice) else { return .unavailable(slice) }
        guard let reg = registrations[id] else { return .unregistered }
        return reg.enablement()
    }

    /// `true` se o controle da ação deve ser renderizado nesta fatia (feature flag por fatia).
    public func isRendered(_ id: ActionID) -> Bool { flags.restricted ? flags.isEnabled(id.spec.slice) : isRegistered(id) }

    // MARK: ActionDispatching
    // Os requisitos do protocolo (Core) são nonisolated e async; cada um salta para o MainActor.

    public nonisolated func perform(_ id: ActionID, _ arg: ActionArgument?) async throws -> ActionResult {
        try await performOnMain(id, arg)
    }

    public nonisolated func actionID(forControl id: A11yID) async -> ActionID? {
        await onMain { $0.surface.uiTree(root: id).roots.first?.action }
    }

    public nonisolated func boundArgument(forControl id: A11yID) async -> ActionArgument? {
        await onMain { $0.surface.uiTree(root: id).roots.first?.argument }
    }

    public nonisolated func uiTree(root: A11yID?) async -> UITreeSnapshot {
        await onMain { $0.surface.uiTree(root: root) }
    }

    public nonisolated func screenshot(_ target: ScreenshotTarget) async throws -> ScreenshotResult {
        try await screenshotOnMain(target)
    }

    public nonisolated func record(_ command: RecordingCommand) async throws -> RecordingResult {
        try await recordOnMain(command)
    }

    public nonisolated func appState() async -> AppStateSnapshot {
        await onMain { $0.surface.appState(registeredActions: $0.registeredIDs) }
    }

    private nonisolated func onMain<T: Sendable>(_ body: @MainActor (ActionRegistry) -> T) async -> T {
        await MainActor.run { body(self) }
    }

    private func screenshotOnMain(_ target: ScreenshotTarget) async throws -> ScreenshotResult {
        try await surface.screenshot(target)
    }

    private func recordOnMain(_ command: RecordingCommand) async throws -> RecordingResult {
        try await surface.record(command)
    }

    func performOnMain(_ id: ActionID, _ arg: ActionArgument?) async throws -> ActionResult {
        switch availability(of: id) {
        case .unavailable(let slice): throw ActionError.notAvailable(id, slice: slice)
        case .unregistered: throw ActionError.notRegistered(id)
        case .disabled(let reason): throw ActionError.disabled(id, reason: reason)
        case .enabled: break
        }
        guard let reg = registrations[id] else { throw ActionError.notRegistered(id) }
        do {
            let message = try await reg.handler(arg ?? .press)
            return ActionResult(actionID: id, ok: true, message: message)
        } catch let e as ActionError {
            throw e
        } catch {
            throw ActionError.failed(id, message: "\(error)")
        }
    }
}

/// O que o registro precisa da camada de janela (implementado por `WindowAutomation`; fake nos testes).
@MainActor
public protocol AutomationSurface {
    func uiTree(root: A11yID?) -> UITreeSnapshot
    func screenshot(_ target: ScreenshotTarget) async throws -> ScreenshotResult
    func record(_ command: RecordingCommand) async throws -> RecordingResult
    func appState(registeredActions: [ActionID]) -> AppStateSnapshot
}
