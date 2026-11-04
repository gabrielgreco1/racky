import RackyDesignSystem
import SwiftUI

struct AgentCreatePageView: View {
    let controller: AgentCreateController

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "New Agent") { EmptyView() }
            Spacer()
        }
        .background(DS.Color.canvas)
        .a11y(.agentsCreatePage, kind: "page")
    }
}
