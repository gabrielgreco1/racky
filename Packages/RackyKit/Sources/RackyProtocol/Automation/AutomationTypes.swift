import Foundation

// DTOs do canal de automação (08 AR-121 `Automation/`, AR-134, AR-806). Todos Sendable e Codable; JSON estável.

/// Argumento de `ui action`: `press` (padrão), `focus`, `select [valor]`, `set <valor>`.
public struct ActionArgument: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case press, focus, select, set }
    public var kind: Kind
    public var value: String?

    public init(kind: Kind, value: String? = nil) {
        self.kind = kind
        self.value = value
    }

    public static let press = ActionArgument(kind: .press)
    public static let focus = ActionArgument(kind: .focus)
    public static func select(_ value: String?) -> ActionArgument { ActionArgument(kind: .select, value: value) }
    public static func set(_ value: String) -> ActionArgument { ActionArgument(kind: .set, value: value) }
}

/// Resultado de uma ação executada com sucesso.
public struct ActionResult: Codable, Sendable, Equatable {
    public var actionID: ActionID
    public var ok: Bool
    public var message: String?

    public init(actionID: ActionID, ok: Bool = true, message: String? = nil) {
        self.actionID = actionID
        self.ok = ok
        self.message = message
    }
}

/// Falhas de `perform` (viram `CtlError` no canal).
public enum ActionError: Error, Sendable, Equatable {
    case notRegistered(ActionID)
    /// Fatia futura: o controle não existe nesta versão (AC-T28), diferente de desabilitado.
    case notAvailable(ActionID, slice: ReleaseSlice)
    /// Desabilitado por pré-condição real, com o motivo exato do tooltip (AC-T02).
    case disabled(ActionID, reason: String)
    case failed(ActionID, message: String)
}

public struct UIFrame: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct UISize: Codable, Sendable, Equatable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// `1440x900` -> UISize.
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
    }
}

/// Nó da árvore de UI (`ctl ui tree`): identificador, rótulo, valor, estado e frame em pontos
/// (origem no canto superior esquerdo do conteúdo da janela; usado por `LayoutConformanceTests`, AR-809).
public struct UITreeNode: Codable, Sendable, Equatable {
    public var id: A11yID
    public var kind: String
    public var label: String?
    public var value: String?
    public var enabled: Bool
    /// Motivo exato de desabilitado (tooltip), quando `enabled == false`.
    public var disabledReason: String?
    /// Ação do registro disparada pelo controle, quando houver.
    public var action: ActionID?
    /// Argumento que o controle manda junto (ex.: `select(supabase)`); `ctl ui action <id>` sem argumento usa este.
    public var argument: ActionArgument?
    public var frame: UIFrame?
    public var children: [UITreeNode]

    public init(
        id: A11yID, kind: String, label: String? = nil, value: String? = nil, enabled: Bool = true,
        disabledReason: String? = nil, action: ActionID? = nil, argument: ActionArgument? = nil, frame: UIFrame? = nil, children: [UITreeNode] = []
    ) {
        self.argument = argument
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.action = action
        self.frame = frame
        self.children = children
    }

    /// Percorre o nó e seus descendentes.
    public func flattened() -> [UITreeNode] { [self] + children.flatMap { $0.flattened() } }

    public func find(_ id: A11yID) -> UITreeNode? { flattened().first { $0.id == id } }
}

public struct UIWindowInfo: Codable, Sendable, Equatable {
    public var title: String
    public var width: Double
    public var height: Double
    public var scale: Double
    public var isKey: Bool

    public init(title: String, width: Double, height: Double, scale: Double, isKey: Bool) {
        self.title = title
        self.width = width
        self.height = height
        self.scale = scale
        self.isKey = isKey
    }
}

public struct UITreeSnapshot: Codable, Sendable, Equatable {
    public var window: UIWindowInfo?
    public var roots: [UITreeNode]

    public init(window: UIWindowInfo?, roots: [UITreeNode]) {
        self.window = window
        self.roots = roots
    }

    public func flattened() -> [UITreeNode] { roots.flatMap { $0.flattened() } }
    public func find(_ id: A11yID) -> UITreeNode? { flattened().first { $0.id == id } }
}

public enum ScreenshotTarget: Sendable, Equatable {
    /// Janela do app; `size` redimensiona a área de conteúdo antes da captura (compare-ui nos dois tamanhos).
    case window(size: UISize?)
    /// Recorte pelo frame do identificador.
    case element(A11yID)
}

public struct ScreenshotResult: Codable, Sendable, Equatable {
    /// `screencapturekit` (fiel, com camadas Metal) ou `appkit` (fallback sem Gravação de Tela; sem Metal).
    public var fidelity: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var note: String?
    public var png: Data

    public init(fidelity: String, pixelWidth: Int, pixelHeight: Int, scale: Double, note: String? = nil, png: Data) {
        self.fidelity = fidelity
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.note = note
        self.png = png
    }
}

public enum RecordingCommand: Sendable, Equatable {
    case start(outPath: String)
    case stop
}

public struct RecordingResult: Codable, Sendable, Equatable {
    public var state: String
    public var path: String?
    public init(state: String, path: String?) {
        self.state = state
        self.path = path
    }
}

/// Estado do app visível ao `ctl state` (modelo de domínio entra com T1-05).
public struct AppStateSnapshot: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    public var pid: Int32
    public var slice: ReleaseSlice
    public var fixture: String?
    public var automation: Bool
    public var window: UIWindowInfo?
    public var registeredActions: [ActionID]
    public var visibleControls: Int
    /// Diagnóstico de foco: tipo do first responder da janela e se overlay/popover bloqueia o terminal.
    public var firstResponder: String?
    public var blocksTerminalInput: Bool?

    public init(
        app: String, version: String, pid: Int32, slice: ReleaseSlice, fixture: String?, automation: Bool,
        window: UIWindowInfo?, registeredActions: [ActionID], visibleControls: Int,
        firstResponder: String? = nil, blocksTerminalInput: Bool? = nil
    ) {
        self.firstResponder = firstResponder
        self.blocksTerminalInput = blocksTerminalInput
        self.app = app
        self.version = version
        self.pid = pid
        self.slice = slice
        self.fixture = fixture
        self.automation = automation
        self.window = window
        self.registeredActions = registeredActions
        self.visibleControls = visibleControls
    }
}
