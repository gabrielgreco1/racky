import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Medidas do módulo Files (tokens do DS; nada solto nas views).
enum FilesMetrics {
    static let rowHeight = DS.Space.s6
    static let indent = DS.Space.s3
    static let chevron = DS.Space.s3
    static let icon: CGFloat = 14
    static let chevronIcon: CGFloat = 9
    static let statusWidth = DS.Space.s4
    static let toolbarHeight = DS.Space.s8
    static let pathHeight = DS.Space.s4 + DS.Space.s1
    static let dot: CGFloat = 6
    static let hairline: CGFloat = 1
    /// Breakpoints do módulo: ≥ `wideMinWidth` árvore e visualizador lado a lado; ≥ `mediumMinWidth` uma coluna; abaixo, compacto.
    static let wideMinWidth: CGFloat = 560
    static let mediumMinWidth: CGFloat = 300
    /// Altura mínima para o cabeçalho de duas linhas (nome + caminho) e para o modo largo.
    static let tallMinHeight: CGFloat = 160
    static let treeColumnWidth: CGFloat = 248
}

/// Layout do módulo Files para o espaço disponível (contínuo: recalculado a cada tamanho).
enum FilesLayout: Equatable {
    case wide, medium, compact

    init(width: CGFloat, height: CGFloat) {
        if width >= FilesMetrics.wideMinWidth, height >= FilesMetrics.tallMinHeight { self = .wide }
        else if width >= FilesMetrics.mediumMinWidth, height >= FilesMetrics.tallMinHeight { self = .medium }
        else { self = .compact }
    }

    var isCompact: Bool { self == .compact }
}

/// Corpo do módulo: a árvore (com a barra de raiz) ou, com um arquivo aberto, o visualizador no lugar dela. Em largura de
/// duas colunas a árvore fica à esquerda e o visualizador à direita. `compact` (contexto do painel) é só uma dica: o layout vem
/// do tamanho real, então o módulo se adapta a qualquer largura e altura.
struct FilesPanelView: View {
    let controller: FilesController
    let compact: Bool

    var body: some View {
        GeometryReader { proxy in
            let layout = FilesLayout(width: proxy.size.width, height: proxy.size.height)
            content(layout)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .layoutProbeRoot()
        }
        .background(DS.Color.panel)
        .a11y(.rightPanelFiles, kind: "container")
    }

    @ViewBuilder private func content(_ layout: FilesLayout) -> some View {
        if layout == .wide {
            HStack(spacing: 0) {
                FilesTreeScreen(controller: controller, layout: layout)
                    .frame(width: FilesMetrics.treeColumnWidth)
                DS.Color.border.frame(width: FilesMetrics.hairline)
                ZStack {
                    if let viewer = controller.viewer {
                        FileViewerView(controller: controller, viewer: viewer, compact: false)
                            .transition(.opacity)
                    } else {
                        DSEmptyState(String(localized: "Select a file to read it here.", bundle: .module)) { EmptyView() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: controller.viewer?.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            ZStack(alignment: .top) {
                if let viewer = controller.viewer {
                    FileViewerView(controller: controller, viewer: viewer, compact: layout.isCompact)
                        .transition(.opacity)
                } else {
                    FilesTreeScreen(controller: controller, layout: layout)
                        .transition(.opacity)
                }
            }
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: controller.viewer?.path)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Barra da raiz (nome, branch, ações) e a lista de arquivos.
struct FilesTreeScreen: View {
    let controller: FilesController
    let layout: FilesLayout
    private var compact: Bool { layout.isCompact }

    var body: some View {
        VStack(spacing: 0) {
            if let root = controller.resolution.root {
                rootBar(root)
                ZStack(alignment: .top) {
                    treeBody(root)
                        .id(controller.rootEpoch)
                        .transition(.opacity.combined(with: .offset(y: MotionTokens.Distance.small)))
                }
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: controller.rootEpoch)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            } else {
                DSEmptyState(String(localized: "Select a session to browse its files.", bundle: .module)) { EmptyView() }
                    .a11y(.rightPanelFilesEmpty, kind: "text")
            }
        }
        // Sem isto o conteúdo curto (pasta com poucos arquivos) ficava centralizado e deixava um vazio acima do cabeçalho.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Barra da raiz

    private func rootBar(_ root: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "folder.fill")
                    .font(.system(size: FilesMetrics.icon - 2))
                    .foregroundStyle(DS.Color.textSecondary)
                Text(verbatim: displayName(root))
                    .font(DS.Font.label.font)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .dsTooltip(root)
                if !compact, let branch = controller.branch {
                    Text(verbatim: branch)
                        .font(DS.Font.monoMicro.font)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: DS.Space.s1)
                if controller.canShowSessionFolder {
                    ActionButton(.filesShowSessionFolder, id: .rightPanelFilesSessionFolder, tooltip: String(localized: "Show Session Folder", bundle: .module)) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(DSIconButtonStyle(.header))
                    .accessibilityLabel(Text("Show Session Folder", bundle: .module))
                }
                ActionButton(
                    .filesToggleIgnored, id: .rightPanelFilesShowIgnored,
                    tooltip: controller.showIgnored
                        ? String(localized: "Hide Ignored Files", bundle: .module) : String(localized: "Show Ignored Files", bundle: .module)
                ) {
                    Image(systemName: controller.showIgnored ? "eye" : "eye.slash")
                }
                .buttonStyle(DSIconButtonStyle(.header, active: controller.showIgnored))
                .accessibilityLabel(Text("Show Ignored Files", bundle: .module))
                .accessibilityValue(controller.showIgnored ? Text("On", bundle: .module) : Text("Off", bundle: .module))
                ActionButton(.filesRefresh, id: .rightPanelFilesRefresh, tooltip: String(localized: "Refresh", bundle: .module)) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(DSIconButtonStyle(.header))
                .accessibilityLabel(Text("Refresh", bundle: .module))
            }
            .padding(.leading, DS.Space.s3)
            .padding(.trailing, DS.Space.s1_5)
            .frame(height: FilesMetrics.toolbarHeight - DS.Space.s1)
            if !compact {
                Text(verbatim: abbreviated(root))
                    .font(DS.Font.monoMicro.font)
                    .foregroundStyle(controller.resolution.isOutsideSession ? DS.Color.warning : DS.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, DS.Space.s3)
                    .frame(height: FilesMetrics.pathHeight, alignment: .leading)
            }
        }
        .padding(.bottom, DS.Space.s1)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: FilesMetrics.hairline) }
        .layoutProbe("rootBar")
        .a11y(.rightPanelFilesRoot, kind: "text", label: displayName(root), value: root)
    }

    private func displayName(_ root: String) -> String {
        let name = (root as NSString).lastPathComponent
        return name.isEmpty ? root : name
    }

    private func abbreviated(_ root: String) -> String { (root as NSString).abbreviatingWithTildeInPath }

    // MARK: Lista

    @ViewBuilder
    private func treeBody(_ root: String) -> some View {
        let rows = controller.tree?.rows ?? []
        if rows.isEmpty {
            if controller.isLoadingRoot {
                Color.clear
            } else {
                DSEmptyState(String(localized: "This folder is empty.", bundle: .module)) { EmptyView() }
                    .a11y(.rightPanelFilesEmpty, kind: "text")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        FileRowView(
                            row: row, change: controller.changes.change(for: row.entry.path),
                            hasChanges: row.entry.isDirectory && controller.changes.directoryHasChanges(row.entry.path),
                            selected: controller.viewer?.path == row.entry.path, compact: compact)
                    }
                }
                .padding(.vertical, DS.Space.s1)
            }
            .layoutProbe("tree")
            .a11y(.rightPanelFilesTree, kind: "container", value: "\(rows.count)")
        }
    }
}

/// Uma linha da árvore: recuo, seta, ícone, nome e a marca de git (letra no arquivo, ponto na pasta).
struct FileRowView: View {
    let row: FileTreeRow
    let change: FileChange?
    let hasChanges: Bool
    let selected: Bool
    let compact: Bool
    @State private var hovering = false

    var body: some View {
        let entry = row.entry
        ActionButton(.filesOpen, id: .rightPanelFilesRow(entry.path), argument: .select(entry.path)) {
            HStack(spacing: DS.Space.s1) {
                Color.clear.frame(width: CGFloat(row.depth) * FilesMetrics.indent, height: FilesMetrics.rowHeight)
                chevron
                Image(systemName: Self.symbol(for: entry, expanded: row.isExpanded))
                    .font(.system(size: FilesMetrics.icon - 2))
                    .foregroundStyle(iconColor)
                    .frame(width: FilesMetrics.icon)
                Text(verbatim: entry.name)
                    .font(DS.Font.small.font)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.s1)
                trailing
            }
            .padding(.horizontal, DS.Space.s2)
            .frame(height: FilesMetrics.rowHeight)
            .background(selected ? DS.Color.panelSelected : (hovering ? DS.Color.hoverRow : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .dsTooltip(entry.isDirectory || !compact ? "" : entry.name)
    }

    @ViewBuilder
    private var chevron: some View {
        if row.entry.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: FilesMetrics.chevronIcon, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: row.isExpanded)
                .frame(width: FilesMetrics.chevron)
        } else {
            Color.clear.frame(width: FilesMetrics.chevron)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let change, !row.entry.isDirectory {
            Text(verbatim: change.rawValue)
                .font(DS.Font.monoMicro.font)
                .foregroundStyle(Self.color(for: change))
                .frame(width: FilesMetrics.statusWidth)
        } else if hasChanges {
            Circle()
                .fill(DS.Color.gitModified)
                .frame(width: FilesMetrics.dot, height: FilesMetrics.dot)
                .frame(width: FilesMetrics.statusWidth)
        }
    }

    private var iconColor: Color {
        if row.entry.isIgnored { return DS.Color.textQuaternary }
        return row.entry.isDirectory ? DS.Color.textSecondary : DS.Color.textTertiary
    }

    private var nameColor: Color {
        if row.entry.isIgnored { return DS.Color.textQuaternary }
        if let change { return Self.color(for: change) }
        return selected ? DS.Color.textPrimary : DS.Color.textPrimary.opacity(0.9)
    }

    static func color(for change: FileChange) -> Color {
        switch change {
        case .modified: DS.Color.gitModified
        case .added: DS.Color.gitAdded
        case .deleted: DS.Color.gitDeleted
        case .untracked: DS.Color.gitUntracked
        case .renamed: DS.Color.gitRenamed
        case .conflicted: DS.Color.conflict
        }
    }

    static func symbol(for entry: FileEntry, expanded: Bool) -> String {
        if entry.isSymlink { return "link" }
        if entry.isDirectory { return expanded ? "folder.fill" : "folder" }
        switch entry.fileExtension {
        case "swift": return "swift"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"
        case "md", "markdown", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico": return "photo"
        case "sh", "zsh", "bash": return "terminal"
        case "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "m", "java", "kt", "php", "lua", "css", "html", "sql":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
