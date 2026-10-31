import RackyDesignSystem
import SwiftUI

/// Escolhe, de forma contínua, o layout que cabe no espaço do módulo: duas colunas (largo), uma coluna (médio), uma coluna sem as
/// listas e gráficos (condensado, quando a altura não comporta o médio) ou só barras e números principais (compacto). A largura decide os breakpoints (`InsightsMetrics.wideMinWidth` / `mediumMinWidth`); a altura
/// decide por `ViewThatFits`: o primeiro layout que cabe inteiro vence. Só se nem o compacto cabe (altura menor que o mínimo do
/// modo compacto) o compacto ganha rolagem interna. Nada é cortado nem sai da caixa.
struct InsightsAdaptive<Wide: View, Medium: View, Condensed: View, Compact: View>: View {
    let width: CGFloat
    @ViewBuilder let wide: Wide
    @ViewBuilder let medium: Medium
    @ViewBuilder let condensed: Condensed
    @ViewBuilder let compact: Compact

    var body: some View {
        ViewThatFits(in: .vertical) {
            if width >= InsightsMetrics.wideMinWidth { wide.frame(maxWidth: .infinity, alignment: .topLeading) }
            if width >= InsightsMetrics.mediumMinWidth { medium.frame(maxWidth: .infinity, alignment: .topLeading) }
            if width >= InsightsMetrics.mediumMinWidth { condensed.frame(maxWidth: .infinity, alignment: .topLeading) }
            compact.frame(maxWidth: .infinity, alignment: .topLeading)
            ScrollView {
                compact.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
        }
    }
}
