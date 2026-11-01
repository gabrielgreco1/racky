import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Visualizador de código somente leitura (10-right-panel §2): cabeçalho com voltar, nome, busca, "Open in…" e copiar caminho;
/// corpo com número de linha, realce leve e calha de alterações do git.
struct FileViewerView: View {
    let controller: FilesController
    let viewer: FileViewerState
    let compact: Bool

    private enum Metrics {
        static let barHeight = DS.Space.s8 - DS.Space.s1
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if controller.search.isActive { searchBar }
            content
        }
        .layoutProbe("viewer")
        .a11y(.rightPanelFilesViewer, kind: "container", label: viewer.name, value: viewer.path)
    }

    // MARK: Cabeçalho

    private var bar: some View {
        HStack(spacing: DS.Space.s1) {
            ActionButton(.filesCloseFile, id: .rightPanelFilesViewerBack, tooltip: String(localized: "Back to Files", bundle: .module)) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Back to Files", bundle: .module))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.s1) {
                    Text(verbatim: viewer.name)
                        .font(DS.Font.label.font)
                        .foregroundStyle(viewer.change.map(FileRowView.color(for:)) ?? DS.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let change = viewer.change {
                        Text(verbatim: change.rawValue)
                            .font(DS.Font.monoMicro.font)
                            .foregroundStyle(FileRowView.color(for: change))
                    }
                }
                if !compact, let relative = relativePath {
                    Text(verbatim: relative)
                        .font(DS.Font.monoMicro.font)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .dsTooltip(viewer.path)
            .a11y(.rightPanelFilesViewerName, kind: "text", label: viewer.name)
            Spacer(minLength: DS.Space.s1)
            ActionButton(.filesFind, id: .rightPanelFilesViewerFind, tooltip: String(localized: "Find in File", bundle: .module)) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(DSIconButtonStyle(.header, active: controller.search.isActive))
            .accessibilityLabel(Text("Find in File", bundle: .module))
            ActionButton(.filesOpenIn, id: .rightPanelFilesViewerOpenIn, tooltip: String(localized: "Open in…", bundle: .module)) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Open in…", bundle: .module))
            ActionButton(.filesCopyPath, id: .rightPanelFilesViewerCopyPath, tooltip: String(localized: "Copy Path", bundle: .module)) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Copy Path", bundle: .module))
        }
        .padding(.leading, DS.Space.s1_5)
        .padding(.trailing, DS.Space.s1_5)
        .frame(height: compact ? Metrics.barHeight : Metrics.barHeight + DS.Space.s2)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: FilesMetrics.hairline) }
    }

    private var relativePath: String? {
        guard let root = controller.resolution.root else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return viewer.path.hasPrefix(prefix) ? String(viewer.path.dropFirst(prefix.count)) : (viewer.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Busca

    private var searchBar: some View {
        HStack(spacing: DS.Space.s1) {
            FindField(controller: controller)
            if !compact {
                Text(verbatim: controller.search.countLabel)
                    .font(DS.Font.microNumeric.font)
                    .foregroundStyle(DS.Color.textTertiary)
                    .lineLimit(1)
                    .a11y(.rightPanelFilesViewerFindCount, kind: "text", value: controller.search.countLabel)
            }
            ActionButton(.filesFindPrevious, id: .rightPanelFilesViewerFindPrevious, tooltip: String(localized: "Previous Match", bundle: .module)) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Previous Match", bundle: .module))
            ActionButton(.filesFindNext, id: .rightPanelFilesViewerFindNext, tooltip: String(localized: "Next Match", bundle: .module)) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Next Match", bundle: .module))
            ActionButton(.filesFindClose, id: .rightPanelFilesViewerFindClose, tooltip: String(localized: "Close Find", bundle: .module)) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Close Find", bundle: .module))
        }
        .padding(.horizontal, DS.Space.s1_5)
        .frame(height: Metrics.barHeight)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: FilesMetrics.hairline) }
    }

    // MARK: Corpo

    @ViewBuilder
    private var content: some View {
        switch viewer.content {
        case nil:
            DSSpinner(size: DS.Space.s4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let truncated):
            CodeTextView(
                text: text, spans: viewer.spans, marks: viewer.marks, version: viewer.version,
                matches: controller.search.isActive ? controller.search.matches : [], current: controller.search.current,
                line: viewer.targetLine)
                .a11y(.rightPanelFilesViewerCode, kind: "text", value: "\(viewer.lineCount)")
            if truncated || viewer.highlightLimited {
                Text("Showing only the first part of this large file.", bundle: .module)
                    .font(DS.Font.small.font)
                    .foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.s3)
                    .padding(.vertical, DS.Space.s1)
                    .background(DS.Color.chrome)
                    .overlay(alignment: .top) { DS.Color.border.frame(height: FilesMetrics.hairline) }
            }
        case .image(let path):
            ScrollView {
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(DS.Space.s3)
                        .frame(maxWidth: .infinity)
                }
            }
        case .binary:
            message(String(localized: "This file isn't text. Open it in another app.", bundle: .module))
        case .unreadable(let reason):
            message(reason)
        }
    }

    private func message(_ text: String) -> some View {
        DSEmptyState(text) { EmptyView() }
            .a11y(.rightPanelFilesViewerEmpty, kind: "text", label: text)
    }
}

/// Campo de busca do visualizador (Return = próxima, ⇧Return = anterior, Esc fecha).
private struct FindField: View {
    let controller: FilesController
    @FocusState private var focused: Bool

    var body: some View {
        TextField(
            "",
            text: Binding(get: { controller.search.query }, set: { controller.setSearchQuery($0) }),
            prompt: Text("Find in File", bundle: .module).foregroundStyle(DS.Color.textTertiary)
        )
        .textFieldStyle(.plain)
        .font(DS.Font.small.font)
        .foregroundStyle(DS.Color.textPrimary)
        .focused($focused)
        .padding(.horizontal, DS.Space.s2)
        .frame(height: DS.Space.s6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.fg6))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(focused ? DS.Color.ring : DS.Color.border, lineWidth: FilesMetrics.hairline))
        .onSubmit { controller.stepSearch(EventModifiers.held(.shift) ? -1 : 1) }
        .onExitCommand { controller.setSearchActive(false) }
        .onAppear { focused = true }
        .a11y(.rightPanelFilesViewerFindField, kind: "textField", label: "Find in file")
    }
}
