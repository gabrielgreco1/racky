import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Medidas da faixa de titlebar (03 §1.3, DS §12.2).
enum StripMetrics {
    static let nameHeight: CGFloat = 24
    static let namePaddingH: CGFloat = DS.Space.s1_5
    static let nameMarginLeading: CGFloat = DS.Space.s0_5
    static let nameMarginTrailing: CGFloat = DS.Space.s1
    static let toggleSize = CGSize(width: 32, height: 24)
    static let navSize = CGSize(width: 22, height: 20)
    static let navGap: CGFloat = DS.Space.s0_5
    static let navMarginTrailing: CGFloat = DS.Space.s3
    static let hairline: CGFloat = 1
    static let buttonRadius: CGFloat = 4
    static let disabledOpacity = 0.45
    static let brandSize: CGFloat = 18
    static let toggleIcon: CGFloat = 16
    static let navIcon: CGFloat = 12
}

/// Faixa de 36 pt sobre a sidebar: pad dos semáforos · nome · toggle da sidebar · (flexível) · selo · ←/→.
struct TitlebarStrip: View {
    let env: AppEnvironment

    var body: some View {
        let shell = env.shell
        let inSettings = env.settings.isOpen
        HStack(spacing: 0) {
            Color.clear.frame(width: WindowGeometry.trafficLightPad(fullScreen: shell.isFullScreen))
            if !shell.appNameHidden { appName }
            if inSettings {
                Spacer(minLength: 0)
            } else {
            ActionButton(.viewToggleSidebar, id: .windowSidebarToggle) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(
                StripButtonStyle(
                    size: StripMetrics.toggleSize, icon: StripMetrics.toggleIcon, secondary: true,
                    active: env.overlays.originActive == .windowSidebarToggle))
            if shell.sidebarCollapsed {
                Color.clear.frame(width: DS.Space.s3, height: DS.Layout.titlebarHeight)
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: StripMetrics.navGap) {
                ActionButton(.navBack, id: .windowHistoryBack) { Image(systemName: "arrow.left") }
                    .buttonStyle(StripButtonStyle(size: StripMetrics.navSize, icon: StripMetrics.navIcon, secondary: false))
                ActionButton(.navForward, id: .windowHistoryForward) { Image(systemName: "arrow.right") }
                    .buttonStyle(StripButtonStyle(size: StripMetrics.navSize, icon: StripMetrics.navIcon, secondary: false))
            }
            .padding(.trailing, StripMetrics.navMarginTrailing)
            }
        }
        .frame(height: DS.Layout.titlebarHeight)
        .frame(maxWidth: (shell.sidebarCollapsed && !inSettings) ? nil : .infinity)
        .fixedSize(horizontal: shell.sidebarCollapsed && !inSettings, vertical: false)
        .background(TitlebarDragRegion())
        // Em Settings a faixa tem a cor e a largura da nav de Settings (F5): sem degrau, sem emenda.
        .background(inSettings ? DS.Color.panel : (shell.sidebarCollapsed ? DS.Color.chrome : DS.Color.sidebar))
        .overlay(alignment: .bottom) { if !inSettings { DS.Color.border.frame(height: StripMetrics.hairline) } }
        .overlay(alignment: .trailing) {
            if shell.sidebarCollapsed && !inSettings { DS.Color.border.frame(width: StripMetrics.hairline) }
        }
        .environment(\.actionRegistry, env.registry)
        .environment(\.overlayRouter, env.overlays)
        .a11y(.windowTitlebar, kind: "container")
    }

    private var appName: some View {
        AppNameButton(env: env)
    }
}

/// Nome do app (03 §1.3 #2): clique abre o `DSMenuPanel` (About · Settings… · Check for Problems · Hide App Name);
/// clique direito oferece só `Hide App Name`.
private struct AppNameButton: View {
    let env: AppEnvironment
    @State private var anchor: CGRect = .zero
    @State private var hovering = false

    private var isOpen: Bool { env.overlays.popover?.spec.id == .menuPanel("appMenu") && env.overlays.popoverIsOpen }

    var body: some View {
        // lint-ui: allow buttons abre o DSMenuPanel (apresentação); os itens disparam ações do registro
        Button { open() } label: {
            HStack(spacing: DS.Space.s1_5) {
                BrandMark(size: StripMetrics.brandSize, glyph: true)
                Text("Racky", bundle: .module)
                    .font(DS.Font.sectionLabel.font)
                    .foregroundStyle(DS.Color.textSecondary)
            }
                .padding(.horizontal, StripMetrics.namePaddingH)
                .lineLimit(1)
                .fixedSize()
                .frame(height: StripMetrics.nameHeight)
                .background(
                    RoundedRectangle(cornerRadius: StripMetrics.buttonRadius)
                        .fill(hovering || isOpen ? DS.Color.accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
        .padding(.leading, StripMetrics.nameMarginLeading)
        .padding(.trailing, StripMetrics.nameMarginTrailing)
        .a11y(.windowAppName, kind: "button", label: "Racky")
        .dsContextMenu(name: "appNameContext", groups: {
            [[MenuEntry(action: .appHideAppName, title: String(localized: "Hide App Name", bundle: .module))]]
        })
    }

    private func open() {
        guard !isOpen else { return }
        DSMenuPanel.present(
            router: env.overlays, registry: env.registry, name: "appMenu", anchor: anchor, entries: AppMenuEntries.entries)
    }
}

/// Itens do menu do nome do app (03 §1.3 #2, ações de §24).
enum AppMenuEntries {
    static var entries: [DSMenuEntry] {
        [
            .item(DSMenuItem("about", String(localized: "About Racky", bundle: .module), action: .appAbout)),
            .item(DSMenuItem("settings", String(localized: "settings.menu", defaultValue: "Settings…", bundle: .module), shortcut: ActionID.appSettings.spec.shortcut, action: .appSettings)),
            .separator("checks"),
            .item(DSMenuItem("checkProblems", String(localized: "Check for Problems", bundle: .module), action: .appCheckProblems)),
            .item(DSMenuItem("hideAppName", String(localized: "Hide App Name", bundle: .module), action: .appHideAppName)),
        ]
    }
}

/// Botão da faixa: hover `accent` a 100% com ícone `textPrimary`; desabilitado a 45% (DS §12.2).
struct StripButtonStyle: ButtonStyle {
    let size: CGSize
    let icon: CGFloat
    let secondary: Bool
    /// Origem de um overlay aberto: mantém o fundo "ativo" enquanto o overlay existe (M-101), sai em `hover` 0,12 s.
    var active = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: icon, weight: .regular))
            .foregroundStyle((hovering || active) && isEnabled ? DS.Color.textPrimary : DS.Color.textSecondary)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: StripMetrics.buttonRadius)
                    .fill(active ? DS.Color.fg10 : (hovering && isEnabled ? DS.Color.accent : Color.clear))
            )
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: active)
            .scaleEffect(configuration.isPressed && !MotionPolicy.shared.reduceMotion ? MotionTokens.Scale.press : 1)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.press), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : StripMetrics.disabledOpacity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Região de arrastar da faixa: arrasta a janela; duplo clique = zoom/minimizar conforme `AppleActionOnDoubleClick`.
struct TitlebarDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let window else {
                super.mouseDown(with: event)
                return
            }
            switch CFPreferencesCopyAppValue("AppleActionOnDoubleClick" as CFString, kCFPreferencesAnyApplication) as? String {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Marca do app (racky.png, F1): 18 pt à esquerda do nome, alinhada ao texto. `glyph` usa só o cubo, sem o fundo azul
/// (racky-glyph.png), para a barra de título.
struct BrandMark: View {
    let size: CGFloat
    var glyph = false

    var body: some View {
        if let url = Bundle.module.url(forResource: glyph ? "racky-glyph" : "racky", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
