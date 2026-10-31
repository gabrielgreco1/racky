import RackyDesignSystem
import CoreGraphics

/// Medidas da sidebar (03 §2.1–§2.12, DS §12.8–§12.10). Os números que não são tokens de layout ficam aqui, num só lugar,
/// e são os mesmos que `LayoutConformanceTests` compara com a árvore de UI real.
enum SidebarMetrics {
    // Contêiner (03 §2.1): padding 8 nos lados e no topo, 4 embaixo, gap 2 entre itens de nav.
    static let paddingH: CGFloat = DS.Space.s2
    static let paddingTop: CGFloat = DS.Space.s2
    static let paddingBottom: CGFloat = DS.Space.s1
    static let navGap: CGFloat = DS.Space.s0_5

    // Search e itens de nav (DS §12.8, §12.10): 32 de altura, padding 8×6, ícone 16.
    static let searchHeight: CGFloat = 32
    static let navHeight: CGFloat = 32
    static let navPaddingH: CGFloat = DS.Space.s2
    static let navGapContent: CGFloat = DS.Space.s2
    static let navIcon: CGFloat = 16
    static let navRadius: CGFloat = DS.Radius.control

    // Cabeçalho de seção (Projects / Sessions): 32, margem superior 8, padding 0×8.
    static let sectionHeaderHeight: CGFloat = 32
    static let sectionMarginTop: CGFloat = DS.Space.s2
    static let sectionPaddingH: CGFloat = DS.Space.s2

    // Linha de projeto (03 §2.5): 28, padding esquerdo 10.
    static let projectRowHeight: CGFloat = 28
    static let projectPaddingLeading: CGFloat = DS.Space.s2_5
    static let chevron: CGFloat = 12
    static let repoBox: CGFloat = 16
    static let repoGlyph: CGFloat = 12
    static let repoRadius: CGFloat = 4
    static let projectGap: CGFloat = DS.Space.s1_5
    static let rowActionBox: CGFloat = 20

    // Card de sessão (v5, 2026-10-27): raio 10, margem 4/6, padding 9×10 (10 só com título), gap 4; linhas mais altas e texto maior.
    static let cardRadius: CGFloat = DS.Radius.card
    static let cardMarginLeading: CGFloat = DS.Space.s1
    static let cardMarginTrailing: CGFloat = DS.Space.s1_5
    static let cardPaddingV: CGFloat = DS.Space.s2
    static let cardPaddingVTitleOnly: CGFloat = DS.Space.s2_5
    static let cardPaddingH: CGFloat = DS.Space.s2_5
    static let cardGap: CGFloat = DS.Space.s1
    static let cardSpacing: CGFloat = DS.Space.s1
    static let statusColumn: CGFloat = 16
    static let statusGap: CGFloat = DS.Space.s2
    static let line1Height: CGFloat = 22
    static let line2Height: CGFloat = 16
    static let line2Icon: CGFloat = 10
    static let unreadDot: CGFloat = 6
    static let placeholderSize = CGSize(width: 60, height: 8)

    // Linhas de agente e pílula (03 §2.7): 24, padding 0×4, gap 4, raio 6.
    static let agentRowHeight: CGFloat = 26
    static let agentRowPaddingH: CGFloat = DS.Space.s1
    static let agentRowGap: CGFloat = DS.Space.s1
    static let agentRowRadius: CGFloat = DS.Radius.sm
    static let agentLogo: CGFloat = 14
    static let summaryLogo: CGFloat = 16

    // Linha pendente (03 §2.9): 32, spinner 16.
    static let pendingHeight: CGFloat = 32
    static let pendingSpinner: CGFloat = 16

    // Rodapé (03 §2.12): 32, border-top, padding 8×6.
    static let footerHeight: CGFloat = 32
    static let footerPaddingH: CGFloat = DS.Space.s2
    static let footerPaddingV: CGFloat = DS.Space.s1_5
    static let footerIcon: CGFloat = 14
    static let filterMenuWidth: CGFloat = 240

    /// Limite de sessões visíveis por projeto antes de `Show <n> more` (03 §2.5).
    static let sessionsBeforeShowMore = 5
    /// Mais linhas que isto viram a pílula-resumo (03 §2.6).
    static let agentRowsBeforeSummary = 4
    /// Sessões ociosas por mais de 7 dias ficam escondidas por padrão (03 §2.4 `Show`).
    static let idleDays = 7
}
