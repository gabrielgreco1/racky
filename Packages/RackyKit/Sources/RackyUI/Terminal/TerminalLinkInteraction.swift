import RackyCore
import RackyDesignSystem
import RackyPlatform
import AppKit
import Foundation
import SwiftTerm

/// Arquivo ou pasta clicado no terminal, com o `:linha:col` do texto.
nonisolated public struct TerminalFileTarget: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var column: Int?
    public var isDirectory: Bool
}

/// ⌘-clique abre no visualizador do app; ⇧⌘-clique no app padrão do sistema (03 §4.1).
nonisolated public enum TerminalLinkOpenMode: Sendable {
    case inApp
    case system
}

/// Caminhos de arquivo no terminal: sublinhado e dica ao passar o mouse com ⌘, e o clique (03 §4.1). URLs ficam com o
/// SwiftTerm (detecção implícita, OSC 8 e realce próprios); aqui só entram caminhos que existem em disco.
///
/// O SwiftTerm expõe `mouseMoved`/`flagsChanged` como `public` (não `open`), então o acompanhamento do mouse é uma
/// `NSTrackingArea` própria e um monitor local de `flagsChanged`. A leitura da linha usa `visibleRowsText` (cópia) e o
/// `stat` roda fora do main; o resultado só vale se o mouse ainda está na mesma célula.
@MainActor
final class TerminalLinkInteraction: NSResponder {
    private struct Hover: Equatable {
        var target: TerminalFileTarget
        var row: Int
        var columns: Range<Int>
    }

    private unowned let surface: TerminalSurfaceView
    /// Pasta onde caminhos relativos são resolvidos (cwd do terminal).
    var cwd: () -> String? = { nil }
    var onOpen: ((TerminalFileTarget, TerminalLinkOpenMode) -> Void)?

    private let underline = NSView()
    private let tip = LinkTipView()
    private var hover: Hover?
    private var probe: Task<Void, Never>?
    private var probedCell: (row: Int, col: Int, text: String)?
    private var monitor: Any?
    private var claimed: Hover?
    /// Mouse parado sobre um caminho por `dwell`: o cartão aparece sem precisar do ⌘.
    private var dwellTask: Task<Void, Never>?
    /// Saiu do caminho: espera um pouco antes de esconder, para dar tempo de levar o mouse até o cartão.
    private var hideTask: Task<Void, Never>?
    static let dwell: Duration = .milliseconds(200)
    static let hideGrace: Duration = .milliseconds(350)

    init(surface: TerminalSurfaceView) {
        self.surface = surface
        super.init()
        underline.wantsLayer = true
        underline.layer?.backgroundColor = DS.ColorSpec.textPrimary.nsColor.cgColor
        underline.isHidden = true
        tip.isHidden = true
        tip.onPick = { [weak self] mode in self?.openFromTip(mode) }
        tip.onHoverChange = { [weak self] inside in
            if inside { self?.cancelHide() } else { self?.scheduleHide() }
        }
        surface.addSubview(underline)
        surface.addSubview(tip)
        surface.addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChanged(event) }
            return event
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        probe?.cancel()
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        // Sobre o cartão: ele cuida do próprio hover; o caminho continua sublinhado.
        if !tip.isHidden, tip.frame.contains(surface.convert(event.locationInWindow, from: nil)) {
            cancelHide()
            return
        }
        if event.modifierFlags.contains(.command) { return update(at: event.locationInWindow, flags: event.modifierFlags) }
        // Sem ⌘: ainda sobre o caminho mostrado, nada muda; fora dele, some depois da folga; parado num lugar novo por `dwell`,
        // procura um caminho ali.
        if let hover, let hit = cell(at: event.locationInWindow), hit.row == hover.row, hover.columns.contains(hit.col) {
            cancelHide()
            return
        }
        if hover != nil { scheduleHide() }
        dwellTask?.cancel()
        let point = event.locationInWindow
        // Cada movimento reinicia a espera: só dispara com o mouse parado `dwell` no mesmo lugar.
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled, let self else { return }
            self.update(at: point, flags: .command)
        }
    }

    override func mouseExited(with event: NSEvent) {
        dwellTask?.cancel()
        scheduleHide()
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide() {
        guard hover != nil, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideGrace)
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            if self.tip.isMouseInside { return }
            self.clear()
        }
    }

    private func modifiersChanged(_ event: NSEvent) {
        guard event.window != nil, event.window === surface.window else { return }
        guard event.modifierFlags.contains(.command), let window = surface.window else { return clear() }
        update(at: window.mouseLocationOutsideOfEventStream, flags: event.modifierFlags)
    }

    private func clear() {
        probe?.cancel()
        dwellTask?.cancel()
        hideTask?.cancel()
        hideTask = nil
        probedCell = nil
        guard hover != nil || !underline.isHidden else { return }
        hover = nil
        underline.isHidden = true
        tip.isHidden = true
    }

    /// Célula (coluna, linha da tela) sob o ponto da janela, ou `nil` fora da grade.
    private func cell(at windowPoint: NSPoint) -> (col: Int, row: Int, cellSize: CGSize)? {
        let point = surface.convert(windowPoint, from: nil)
        let dims = surface.terminalDimensions
        guard surface.bounds.contains(point), dims.cols > 0, dims.rows > 0 else { return nil }
        let optimal = surface.getOptimalFrameSize()
        let size = CGSize(width: optimal.width / CGFloat(dims.cols), height: optimal.height / CGFloat(dims.rows))
        guard size.width > 0, size.height > 0 else { return nil }
        let col = Int(point.x / size.width)
        let row = Int((surface.bounds.height - point.y) / size.height)
        guard (0..<dims.cols).contains(col), (0..<dims.rows).contains(row) else { return nil }
        return (col, row, size)
    }

    private func update(at windowPoint: NSPoint, flags: NSEvent.ModifierFlags) {
        guard flags.contains(.command), let hit = cell(at: windowPoint),
            let text = surface.visibleRowsText(hit.row..<hit.row + 1).first
        else { return clear() }
        if let hover, hover.row == hit.row, hover.columns.contains(hit.col), probedCell?.text == text { return }
        if hover != nil {  // saiu do caminho: some já, sem esperar o `stat` da célula nova
            hover = nil
            underline.isHidden = true
            tip.isHidden = true
        }
        if let probed = probedCell, probed.row == hit.row, probed.col == hit.col, probed.text == text { return }
        guard let index = TerminalLinkDetector.characterIndex(forColumn: hit.col, in: text) else { return clear() }
        probe?.cancel()
        probedCell = (hit.row, hit.col, text)
        let cwd = cwd()
        let row = hit.row
        let size = hit.cellSize
        probe = Task { [weak self] in
            let found = await BlockingIOBridge.run { () -> (TerminalLink, Bool)? in
                var isDirectory = false
                let link = TerminalLinkDetector.detect(line: text, column: index, cwd: cwd) { path in
                    guard let kind = PathProbe.kind(of: path) else { return false }
                    isDirectory = kind == .directory
                    return true
                }
                return link.map { ($0, isDirectory) }
            }
            guard !Task.isCancelled, let self, self.probedCell?.row == row, self.probedCell?.text == text else { return }
            guard let (link, isDirectory) = found, case .file(let path, let line, let col) = link.kind else {
                self.hover = nil
                self.underline.isHidden = true
                self.tip.isHidden = true
                return
            }
            let columns = TerminalLinkDetector.columns(of: link.range, in: text)
            self.show(
                Hover(target: TerminalFileTarget(path: path, line: line, column: col, isDirectory: isDirectory), row: row, columns: columns),
                cellSize: size)
        }
    }

    private func show(_ next: Hover, cellSize: CGSize) {
        hover = next
        let x = CGFloat(next.columns.lowerBound) * cellSize.width
        let width = CGFloat(next.columns.count) * cellSize.width
        let top = surface.bounds.height - CGFloat(next.row) * cellSize.height
        underline.frame = CGRect(x: x, y: top - cellSize.height + 1, width: width, height: 1)
        underline.isHidden = false
        tip.configure(isDirectory: next.target.isDirectory)
        let size = tip.fittingSize
        let above = top + DS.Space.s1
        let y = above + size.height <= surface.bounds.height ? above : top - cellSize.height - DS.Space.s1 - size.height
        tip.frame = CGRect(x: min(x, max(0, surface.bounds.width - size.width)), y: y, width: size.width, height: size.height)
        tip.isHidden = false
    }

    // MARK: Clique

    /// ⌘-clique sobre um caminho já resolvido pelo hover: o evento é consumido (não chega ao SwiftTerm nem ao programa).
    func claimClick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let hover, let hit = cell(at: event.locationInWindow),
            hit.row == hover.row, hover.columns.contains(hit.col)
        else { return false }
        claimed = hover
        return true
    }

    func finishClaimedClick(_ event: NSEvent) {
        guard let target = claimed?.target else { return }
        claimed = nil
        onOpen?(target, event.modifierFlags.contains(.shift) ? .system : .inApp)
    }

    var hasClaimedClick: Bool { claimed != nil }

    /// Clique numa ação do cartão (abrir no app ou no app padrão).
    func openFromTip(_ mode: TerminalLinkOpenMode) {
        guard let target = hover?.target else { return }
        clear()
        onOpen?(target, mode)
    }

    /// O cartão está na tela (testes).
    var tipVisible: Bool { !tip.isHidden }

    /// Caminho sob o mouse neste instante (já resolvido em disco); usado pelos testes.
    var hoveredTarget: TerminalFileTarget? { hover?.target }
}

/// Cartão sobre um caminho: duas ações clicáveis ("Open file", "Open with default app"), com o atalho ao lado. Aparece com o
/// mouse parado no caminho e fica enquanto o mouse está nele ou no cartão.
@MainActor
private final class LinkTipView: NSView {
    private let stack = NSStackView()
    private let primary = TipRow()
    private let secondary = TipRow()
    var onPick: ((TerminalLinkOpenMode) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isMouseInside = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.ColorSpec.menuSolid.nsColor.cgColor
        layer?.borderColor = DS.ColorSpec.borderStrong.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = DS.Radius.md
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = DS.Space.s2
        layer?.shadowOffset = CGSize(width: 0, height: -DS.Space.s0_5)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.s1, left: DS.Space.s1, bottom: DS.Space.s1, right: DS.Space.s1)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        primary.onClick = { [weak self] in self?.onPick?(.inApp) }
        secondary.onClick = { [weak self] in self?.onPick?(.system) }
        stack.addArrangedSubview(primary)
        stack.addArrangedSubview(secondary)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    func configure(isDirectory: Bool) {
        primary.configure(
            symbol: isDirectory ? "folder" : "doc.text",
            title: isDirectory ? String(localized: "Open folder", bundle: .module) : String(localized: "Open file", bundle: .module),
            shortcut: "⌘" + String(localized: "Click", bundle: .module))
        secondary.configure(
            symbol: isDirectory ? "magnifyingglass" : "arrow.up.forward.app",
            title: isDirectory ? String(localized: "Reveal in Finder", bundle: .module) : String(localized: "Open with default app", bundle: .module),
            shortcut: "⇧⌘" + String(localized: "Click", bundle: .module))
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true; onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { isMouseInside = false; onHoverChange?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Uma ação do cartão: ícone, título e atalho; destaca no hover e age no clique.
@MainActor
private final class TipRow: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.sm
        icon.contentTintColor = DS.ColorSpec.textSecondary.nsColor
        title.font = DS.Font.label.nsFont
        title.textColor = DS.ColorSpec.textPrimary.nsColor
        key.font = DS.Font.small.nsFont
        key.textColor = DS.ColorSpec.textTertiary.nsColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, title, spacer, key])
        row.orientation = .horizontal
        row.spacing = DS.Space.s2
        row.edgeInsets = NSEdgeInsets(top: DS.Space.s1_5, left: DS.Space.s2, bottom: DS.Space.s1_5, right: DS.Space.s2)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: DS.Space.s8 * 7),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    func configure(symbol: String, title text: String, shortcut: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = text
        key.stringValue = shortcut
        setAccessibilityLabel(text)
        setAccessibilityRole(.button)
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = DS.ColorSpec.secondary.nsColor.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
