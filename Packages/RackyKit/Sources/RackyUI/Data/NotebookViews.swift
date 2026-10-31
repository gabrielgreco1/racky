import AppKit
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI
import WebKit

/// Medidas da tab de notebook.
enum NotebookMetrics {
    static let sidebar: CGFloat = 240
    static let row: CGFloat = 30
    static let logo: CGFloat = 16
    /// Proporções da marca do notebook (fração do tamanho): espessura da órbita, altura, deslocamento e a lua.
    static let orbitStroke: CGFloat = 0.12
    static let orbitHeight: CGFloat = 0.42
    static let orbitOffset: CGFloat = 0.22
    static let moon: CGFloat = 0.18
    static let moonX: CGFloat = 0.38
    static let moonY: CGFloat = 0.42
}

/// Dataset arrastado da coluna Data: o texto que viaja no arrasto (prefixado para não ser confundido com outros arrastos de texto).
enum NotebookDrop {
    static let prefix = "racky-dataset:"
    static func payload(_ datasetID: String) -> String { prefix + datasetID }
    static func datasetID(_ text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let id = String(text.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

/// Tab de notebook da área Data: à esquerda os datasets do Racky (marca quais entram e carrega), à direita o JupyterLab.
struct NotebookObjectView: View {
    let hub: DataHubController
    let id: String
    /// Já é um pane da sessão: sem o botão de levar para o lado do agente.
    var inSession = false
    /// Pane da sessão: o X que fecha o pane.
    var close: (() -> Void)?
    @Environment(\.actionRegistry) private var registry
    @State private var dropTargeted = false

    private var notebook: NotebookController.Notebook? { hub.notebooks.notebooks[id] }

    /// Os datasets da sessão do primeiro marcado (o notebook é da sessão que coletou os dados) e os de outras sessões que foram
    /// soltos aqui.
    private var listed: [DatasetSummary] {
        let all = hub.datasets.summaries
        let selected = notebook?.selected ?? []
        let session = all.first { $0.id == selected.first }?.dataset.sessionID
        return all.filter { $0.dataset.sessionID == session || selected.contains($0.id) }
    }

    /// Solta datasets arrastados da coluna Data neste notebook.
    private func drop(_ texts: [String]) -> Bool {
        let ids = texts.compactMap(NotebookDrop.datasetID)
        guard !ids.isEmpty, let registry else { return false }
        Task { for dataset in ids { _ = try? await registry.perform(.notebookAddDataset, .select("\(id)|\(dataset)")) } }
        return true
    }

    var body: some View {
        // Num pane estreito (ao lado do agente) a lista de datasets sai e o JupyterLab fica com o espaço todo.
        GeometryReader { geo in
            HStack(spacing: .zero) {
                if geo.size.width >= NotebookMetrics.sidebar * 2.6 {
                    sidebar
                    Rectangle().fill(DS.Color.border).frame(width: DSMetrics.hairline)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(DS.Color.locate.opacity(dropTargeted ? 1 : 0), lineWidth: MotionTokens.Stroke.focusRing)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { dropTargeted = $0 }
            .overlay(alignment: .topTrailing) {
                if let close {
                    // lint-ui: allow buttons fecha o pane (layout do workspace, sem ação de registro própria)
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(DSIconButtonStyle(.header))
                        .help(String(localized: "Close", bundle: .module))
                        .padding(DS.Space.s1)
                        .a11y(.notebookClose, kind: "button")
                }
            }
        }
        .background(DS.Color.canvas)
        .task(id: "\(id)#\(hub.datasets.summaries.count)") { hub.notebooks.restore(id) }  // tab reaberta depois de reiniciar o app
        .a11y(.notebookPage, kind: "page")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                JupyterMark(size: NotebookMetrics.logo)
                Text("Datasets in this notebook", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.top, DS.Space.s3)
            ScrollView {
                VStack(spacing: .zero) {
                    ForEach(listed) { summary in row(summary) }
                }
            }
            VStack(spacing: DS.Space.s2) {
                DSButton(.notebookApply, id: .notebookApply, "Load into notebook", variant: .primary, size: .sm, symbol: "arrow.down.doc", argument: .select(id))
                if !inSession {
                    DSButton(
                        .notebookOpenBeside, id: .notebookOpenBeside, "Beside the agent", variant: .outline, size: .sm, symbol: "rectangle.split.2x1",
                        argument: .select(id))
                }
            }
            .padding(DS.Space.s3)
        }
        .frame(width: NotebookMetrics.sidebar)
        .background(DS.Color.panel)
    }

    private func row(_ summary: DatasetSummary) -> some View {
        let on = notebook?.selected.contains(summary.id) ?? false
        return ActionButton(.notebookToggleDataset, id: .notebookDataset(summary.id), argument: .select("\(id)|\(summary.id)")) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: on ? "checkmark.square.fill" : "square").dsFont(DS.Font.body)
                    .foregroundStyle(on ? DS.Color.dataValid : DS.Color.textTertiary)
                Text(verbatim: summary.dataset.name).dsFont(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: summary.rowCount.formatted()).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: NotebookMetrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch notebook?.status ?? .idle {
        case .ready(let url):
            NotebookWebView(url: url, revision: notebook?.revision ?? 0, onDrop: { drop([$0]) }).a11y(.notebookWeb, kind: "web")
        case .failed(let message):
            status(symbol: "exclamationmark.triangle", text: message)
        case .starting(let message):
            VStack(spacing: DS.Space.s3) {
                ProgressView().controlSize(.small)
                Text(verbatim: message.isEmpty ? String(localized: "Preparing the notebook…", bundle: .module) : message)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center)
            }
            .a11y(.notebookStatus, kind: "text")
        case .idle:
            status(symbol: "book.pages", text: String(localized: "Pick datasets on the left and load them.", bundle: .module))
        }
    }

    private func status(symbol: String, text: String) -> some View {
        VStack(spacing: DS.Space.s2) {
            Image(systemName: symbol).dsFont(DS.Font.dialogTitle).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: text).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center)
        }
        .padding(DS.Space.s6)
        .a11y(.notebookStatus, kind: "text")
    }
}

/// JupyterLab num web view; recarrega quando o notebook ganha células novas.
struct NotebookWebView: NSViewRepresentable {
    let url: URL
    let revision: Int
    /// Um dataset solto em cima do JupyterLab (o web view pega o arrasto antes do SwiftUI).
    var onDrop: (String) -> Bool = { _ in false }

    final class Coordinator { var revision = -1; var url: URL? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = DatasetDropWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.underPageBackgroundColor = .clear
        // Chave KVC não pública: só se o WebKit ainda responde a ela (senão `setValue` lança exceção ObjC).
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) { view.setValue(false, forKey: "drawsBackground") }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        (view as? DatasetDropWebView)?.onDrop = onDrop
        guard context.coordinator.url != url || context.coordinator.revision != revision else { return }
        context.coordinator.url = url
        context.coordinator.revision = revision
        view.load(URLRequest(url: url))
    }
}

/// WKWebView que reconhece um dataset arrastado da coluna Data: em vez de colar o texto numa célula, põe o dataset no notebook.
/// Qualquer outro arrasto (arquivo, texto) segue para o JupyterLab como antes.
final class DatasetDropWebView: WKWebView {
    var onDrop: (String) -> Bool = { _ in false }

    private func dataset(in sender: any NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .string).flatMap { NotebookDrop.datasetID($0) == nil ? nil : $0 }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dataset(in: sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dataset(in: sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let text = dataset(in: sender) { return onDrop(text) }
        return super.performDragOperation(sender)
    }
}

/// Marca de notebook (as três órbitas do Jupyter, desenhadas): laranja, pequena, sem depender de imagem.
struct JupyterMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            let M = NotebookMetrics.self
            Ellipse().stroke(DS.Color.warning, lineWidth: size * M.orbitStroke).frame(width: size, height: size * M.orbitHeight).offset(y: -size * M.orbitOffset)
            Ellipse().stroke(DS.Color.warning, lineWidth: size * M.orbitStroke).frame(width: size, height: size * M.orbitHeight).offset(y: size * M.orbitOffset)
            Circle().fill(DS.Color.textSecondary).frame(width: size * M.moon).offset(x: size * M.moonX, y: -size * M.moonY)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
