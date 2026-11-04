import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Uma linha da seção Agents: rosto, nome e o ponto de "precisa de você" quando um site logado venceu.
struct SidebarAgentRow: View {
    let controller: AgentsController
    let agent: AgentDefinition
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        DSListRow(.agentsOpen, id: .sidebarAgent(agent.name), selected: controller.selectedName == agent.name, argument: .select(agent.name)) {
            HStack(spacing: DS.Space.s2) {
                AgentAvatarView(image: controller.images[agent.name], size: AgentMetrics.sidebarAvatar)
                Text(verbatim: agent.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: DS.Space.s1)
                if controller.needsLogin.contains(agent.name) {
                    Circle().fill(DS.Color.unread).frame(width: SidebarMetrics.unreadDot, height: SidebarMetrics.unreadDot)
                        .dsTooltip(String(localized: "A logged-in site expired", bundle: .module))
                }
            }
            .padding(.horizontal, SidebarMetrics.cardPaddingH)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.line1Height + DS.Space.s2, alignment: .leading)
        }
        .draggable(AgentsController.dragPayload(agent.name)) {
            HStack(spacing: DS.Space.s2) {
                AgentAvatarView(image: controller.images[agent.name], size: AgentMetrics.sidebarAvatar)
                Text(verbatim: agent.name).dsFont(DS.Font.label)
            }
            .padding(DS.Space.s2)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.panel))
        }
    }
}
