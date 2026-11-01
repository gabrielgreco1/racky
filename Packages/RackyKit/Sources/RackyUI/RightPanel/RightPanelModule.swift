import RackyCore
import RackyProtocol
import SwiftUI

/// O que o contêiner diz ao módulo sobre o espaço que ele ocupa (10-right-panel §1).
public struct RightPanelModuleContext: Equatable, Sendable {
    /// Largura do painel abaixo do limiar: o módulo mostra só ícones e números principais.
    public var isCompact: Bool
    public var slot: PanelSlot
    /// Área de conteúdo do módulo (abaixo do header de 32 pt).
    public var size: CGSize

    public init(isCompact: Bool, slot: PanelSlot, size: CGSize) {
        self.isCompact = isCompact
        self.slot = slot
        self.size = size
    }
}

/// Contrato de um módulo do painel direito. O contêiner desenha o header (ícone, título, minimizar, arrastar para trocar de
/// posição) e o botão de liga/desliga da faixa de topo; o módulo entrega só o corpo e, se quiser, um acessório no header.
///
/// Para plugar um módulo novo: implementar este protocolo e registrá-lo em `RightPanelModules.make(...)`
/// (`RightPanel/RightPanelModules.swift`). Insights troca o placeholder ali.
@MainActor
public protocol RightPanelModule: AnyObject {
    /// Identificador estável (vai para o `ui_state`).
    var id: PanelModuleID { get }
    /// Título do header, em inglês (P2).
    var title: String { get }
    /// Nome de SF Symbol.
    var icon: String { get }
    /// Ação do registro que liga/desliga o módulo (botão da faixa de topo e atalho); `nil` = sem botão na faixa.
    var toggleAction: ActionID? { get }
    /// Identificador do botão da faixa de topo.
    var stripButtonID: A11yID? { get }
    /// Corpo do módulo. Chamado de novo quando o contexto muda (compacto, tamanho).
    func makeView(context: RightPanelModuleContext) -> AnyView
    /// Acessório à direita do título no header (ex.: chip "Following Claude"). `nil` = nenhum.
    func makeHeaderAccessory(context: RightPanelModuleContext) -> AnyView?
}

extension RightPanelModule {
    public var toggleAction: ActionID? { nil }
    public var stripButtonID: A11yID? { nil }
    public func makeHeaderAccessory(context: RightPanelModuleContext) -> AnyView? { nil }
}
