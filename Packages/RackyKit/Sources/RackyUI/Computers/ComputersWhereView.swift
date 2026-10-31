import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Medidas da escolha "onde os computadores rodam" (página Computers, BK-12).
enum WhereMetrics {
    static let column: CGFloat = 720
    static let heroIcon: CGFloat = 52
    static let choiceHeight: CGFloat = 156
    static let choiceIcon: CGFloat = 40
    static let miniLogo: CGFloat = 16
    static let providerTileHeight: CGFloat = 92
    static let providerLogo: CGFloat = 26
    static let regionChipHeight: CGFloat = 44
    static let stepperButton: CGFloat = 24
    static let ringWidth: CGFloat = 1.5
    static let compactBar: CGFloat = 44
    static let pulse: CGFloat = 7
    static let stagger: Double = 0.04
    static let openMaxHeight: CGFloat = 560
    static let heroText: CGFloat = 520
    static let badge: CGFloat = 22
    static let check: CGFloat = 18
    static let stepBadge: CGFloat = 20
    static let dividerInset: CGFloat = 44
    static let stepperNumber: CGFloat = 28
}

/// "Where do agents' computers run?" (BK-12, P27): a escolha principal é local (Docker no Mac) ou a nuvem do próprio usuário. Com
/// computadores na lista vira uma faixa compacta que abre a escolha inteira em "Change".
struct ComputersWhereView: View {
    let settings: SettingsModel
    /// Página já tem computadores: mostra a faixa compacta (a escolha abre por cima da tabela).
    let compact: Bool
    /// Linha discreta no fim da página vazia ("No computers yet…").
    var emptyNote: AnyView?
    /// Dentro de um ScrollView da página (que rola junto com Left on disk): não abre o próprio.
    var embedded = false
    @Namespace private var ring

    private var target: AppSettings.ComputerRunTarget { settings.settings.computers.runOn }

    var body: some View {
        if compact {
            VStack(spacing: 0) {
                CompactWhereBar(settings: settings)
                if settings.computersWhereOpen {
                    ScrollView { chooser.padding(.vertical, DS.Space.s6) }
                        .frame(maxHeight: WhereMetrics.openMaxHeight)
                        .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    DS.Color.border.frame(height: DSMetrics.hairline)
                }
            }
            .animation(MotionPolicy.shared.animation(MotionTokens.Springs.panel), value: settings.computersWhereOpen)
        } else if embedded {
            full
        } else {
            ScrollView { full }
        }
    }

    private var full: some View {
        VStack(spacing: DS.Space.s8) {
            hero
            chooser
            emptyNote
        }
        .padding(.vertical, DS.Space.s10)
        .frame(maxWidth: .infinity)
    }

    private var hero: some View {
        VStack(spacing: DS.Space.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.large).fill(DS.Color.secondary)
                RoundedRectangle(cornerRadius: DS.Radius.large).strokeBorder(DS.Color.borderStrong)
                Image(systemName: "display.2").font(.system(size: 22, weight: .medium)).foregroundStyle(DS.Color.textPrimary)
            }
            .frame(width: WhereMetrics.heroIcon, height: WhereMetrics.heroIcon)
            .padding(.bottom, DS.Space.s2)
            Text("Where do agents' computers run?", bundle: .module).dsFont(DS.Font.pageTitle).foregroundStyle(DS.Color.textPrimary)
            Text("Each subagent gets its own computer with a browser, so agents work side by side without touching your Mac.", bundle: .module)
                .dsFont(DS.Font.dialogBody).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: WhereMetrics.heroText)
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            NewSessionsRow(settings: settings)
            HStack(spacing: DS.Space.s3) {
                WhereChoiceCard(target: .local, selected: target == .local, ring: ring, usesDocker: !settings.usesNativeRuntime) {
                    LocalStatusLine(status: settings.dockerStatus)
                }
                WhereChoiceCard(target: .cloud, selected: target == .cloud, ring: ring, usesDocker: false) {
                    CloudSummaryLine(settings: settings, selected: target == .cloud)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(MotionPolicy.shared.animation(MotionTokens.Springs.lively), value: target)
            if target == .cloud {
                Group {
                    if settings.cloudActive && !settings.cloudEditing {
                        VStack(alignment: .leading, spacing: DS.Space.s6) {
                            CloudSummaryBar(settings: settings)
                            CloudSpendView(settings: settings)
                        }
                    } else {
                        CloudSetupView(settings: settings).padding(.top, DS.Space.s2)
                    }
                }
                .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
            }
        }
        .frame(width: WhereMetrics.column)
        .frame(maxWidth: .infinity)
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.panel), value: target)
        .a11y(.computersWhere, kind: "container")
    }
}

// MARK: Cards de escolha

private struct WhereChoiceCard<Status: View>: View {
    let target: AppSettings.ComputerRunTarget
    let selected: Bool
    let ring: Namespace.ID
    /// Só o modo Docker mostra a marca e fala do Docker; o runtime nativo (padrão) não.
    let usesDocker: Bool
    @ViewBuilder let status: () -> Status
    @State private var hovering = false

    private var title: String {
        target == .local ? String(localized: "This Mac", bundle: .module) : String(localized: "Your cloud", bundle: .module)
    }

    private var detail: String {
        target == .local
            ? (usesDocker ? String(localized: "Free. Computers run in Docker on this Mac.", bundle: .module) : String(localized: "Free. Computers run on this Mac.", bundle: .module))
            : String(localized: "More computers at once and more power, on your own account.", bundle: .module)
    }

    var body: some View {
        ActionButton(.computersRunOn, id: target == .local ? .computersWhereLocal : .computersWhereCloud, argument: .select(target.rawValue)) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(alignment: .top) {
                    icon
                    Spacer(minLength: 0)
                    check
                }
                .padding(.bottom, DS.Space.s3)
                Text(verbatim: title).dsFont(DS.Font.composerTitle).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: detail).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s2)
                status()
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: .infinity, minHeight: WhereMetrics.choiceHeight, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: DS.Radius.large).strokeBorder(DS.Color.textPrimary.opacity(0.85), lineWidth: WhereMetrics.ringWidth)
                        .matchedGeometryEffect(id: "ring", in: ring)
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.large).strokeBorder(hovering ? DS.Color.borderStrong : DS.Color.border)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large))
            .scaleEffect(hovering && !selected && !MotionPolicy.shared.reduceMotion ? 1.008 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: hovering)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DS.Radius.large)
            .fill(
                LinearGradient(
                    colors: selected ? [DS.Color.secondary, DS.Color.chrome] : [hovering ? DS.Color.secondary.opacity(0.6) : DS.Color.chrome, DS.Color.chrome],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    @ViewBuilder private var icon: some View {
        HStack(spacing: -6) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.canvas.opacity(0.6))
                RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border)
                Image(systemName: target == .local ? "laptopcomputer" : "cloud")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(DS.Color.textPrimary)
                    .symbolEffect(.bounce, value: selected)
            }
            .frame(width: WhereMetrics.choiceIcon, height: WhereMetrics.choiceIcon)
            if target == .local {
                if usesDocker { badge { DSBrandLogo("docker", size: WhereMetrics.miniLogo - 2, tint: DSRGBA(hex: 0x2496ED).color) } }
            } else {
                ForEach(Array(CloudProviderCatalog.all.prefix(3).enumerated()), id: \.element.id) { index, provider in
                    badge { DSBrandLogo(provider.logo, size: WhereMetrics.miniLogo - 4, tint: DSRGBA(hex: provider.brandHex).color) }
                        .zIndex(Double(-index))
                }
            }
        }
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Circle().fill(DS.Color.chrome)
            Circle().strokeBorder(DS.Color.borderStrong)
            content()
        }
        .frame(width: WhereMetrics.badge, height: WhereMetrics.badge)
        .offset(y: WhereMetrics.choiceIcon / 2 - 6)
    }

    private var check: some View {
        ZStack {
            Circle().strokeBorder(selected ? Color.clear : DS.Color.borderStrong, lineWidth: WhereMetrics.ringWidth)
            if selected {
                Circle().fill(DS.Color.primary)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Color.textOnPrimary)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: WhereMetrics.check, height: WhereMetrics.check)
    }
}

/// Estado do Docker no card "This Mac": ponto vivo quando está pronto, aviso e "Open Docker" quando está parado.
private struct LocalStatusLine: View {
    let status: DockerStatusInfo

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            PulseDot(color: status.stopped ? DS.Color.warning : DS.Color.agentDone, pulsing: !status.stopped)
            Text(verbatim: status.stopped ? String(localized: "Docker isn't running", bundle: .module) : status.text)
                .dsFont(DS.Font.small).foregroundStyle(status.stopped ? DS.Color.warning : DS.Color.textTertiary).lineLimit(1)
            if status.stopped {
                DSButton(.dockerStart, id: nil, "Open Docker", variant: .ghost, size: .xs)
            }
        }
    }
}

/// Resumo da nuvem no card: provedor, região e teto quando escolhida; senão, o selo de prévia.
private struct CloudSummaryLine: View {
    let settings: SettingsModel
    let selected: Bool

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            if settings.cloudActive {
                PulseDot(color: DS.Color.dataValid, pulsing: !settings.cloudSnapshot.hosts.isEmpty)
            } else if selected {
                PulseDot(color: DS.Color.textQuaternary, pulsing: false)
                Text("Setting up · not on yet", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            } else {
                PreviewPill()
            }
            if selected && settings.cloudActive {
                let cloud = settings.settings.computers.cloud
                let provider = settings.cloudProvider
                let city = provider.regions.first { $0.id == cloud.region }?.city ?? cloud.region
                Text(verbatim: "\(provider.name) · \(city) · " + String(localized: "up to \(cloud.maxComputers)", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct PreviewPill: View {
    var body: some View {
        Text("Preview", bundle: .module)
            .dsFont(DS.Font.micro).foregroundStyle(DS.Color.aiAccent)
            .padding(.horizontal, DS.Space.s1_5).padding(.vertical, DS.Space.s0_5)
            .background(Capsule().fill(DS.Color.aiAccent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(DS.Color.aiAccent.opacity(0.3)))
    }
}

/// Ponto de estado com um anel que pulsa devagar (some com Reduce Motion).
struct PulseDot: View {
    let color: Color
    let pulsing: Bool
    @State private var expanded = false

    var body: some View {
        ZStack {
            if pulsing, !MotionPolicy.shared.reduceMotion {
                Circle().fill(color.opacity(expanded ? 0 : 0.45)).scaleEffect(expanded ? 2.4 : 1)
            }
            Circle().fill(color)
        }
        .frame(width: WhereMetrics.pulse, height: WhereMetrics.pulse)
        .onAppear {
            guard pulsing, !MotionPolicy.shared.reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true }
        }
    }
}

// MARK: Nuvem

extension View {
    /// Entrada escalonada: cada bloco sobe 6 pt e aparece um pouco depois do anterior.
    func stagger(_ index: Int, _ shown: Bool) -> some View {
        let reduce = MotionPolicy.shared.reduceMotion
        return opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 6)
            .animation(
                MotionPolicy.shared.animation(MotionTokens.Springs.panel)?.delay(reduce ? 0 : WhereMetrics.stagger * Double(index)), value: shown)
    }
}

struct ProviderTile: View {
    let info: CloudProviderInfo
    let selected: Bool
    @State private var hovering = false

    private var brand: Color { DSRGBA(hex: info.brandHex).color }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .top) {
                DSBrandLogo(info.logo, size: WhereMetrics.providerLogo, tint: info.available ? brand : DS.Color.textSecondary)
                Spacer(minLength: 0)
                if !info.available {
                    Text("Soon", bundle: .module).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: info.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            Text(verbatim: info.referenceHourlyUSD.map { "≈ " + $0.formatted(.currency(code: "USD").precision(.fractionLength(2))) + "/h" } ?? " ")
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, minHeight: WhereMetrics.providerTileHeight, maxHeight: WhereMetrics.providerTileHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.large).fill(selected ? brand.opacity(0.08) : (hovering ? DS.Color.secondary.opacity(0.6) : DS.Color.chrome)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .strokeBorder(selected ? brand.opacity(0.75) : (hovering ? DS.Color.borderStrong : DS.Color.border), lineWidth: selected ? WhereMetrics.ringWidth : 1))
        .shadow(color: selected ? brand.opacity(0.18) : .clear, radius: 12, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large))
        .opacity(info.available ? 1 : 0.55)

        Group {
            if info.available {
                ActionButton(.computersCloudProvider, id: .computersCloudProvider(info.id), argument: .select(info.id)) { content }
                    .buttonStyle(.plain)
            } else {
                content
                    .dsTooltip(String(localized: "\(info.name) is coming soon.", bundle: .module), shortcut: nil)
                    .a11y(.computersCloudProvider(info.id), kind: "text", label: info.name, value: "soon")
            }
        }
        .onHover { hovering = $0 && info.available }
        .offset(y: hovering && !MotionPolicy.shared.reduceMotion ? -1 : 0)
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: hovering)
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.lively), value: selected)
    }
}

struct LinkChip: View {
    let kind: CloudProviderLink.Kind
    let title: String
    let provider: CloudProviderInfo
    @State private var hovering = false

    var body: some View {
        if provider.links.contains(where: { $0.kind == kind }) {
            ActionButton(.computersCloudOpenLink, id: .computersCloudLink(kind.rawValue), argument: .select(kind.rawValue)) {
                HStack(spacing: DS.Space.s1) {
                    Text(verbatim: title).dsFont(DS.Font.label)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        .offset(x: hovering ? 1 : 0, y: hovering ? -1 : 0)
                }
                .foregroundStyle(hovering ? DS.Color.textPrimary : DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .background(Capsule().fill(hovering ? DS.Color.secondary : Color.clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: hovering)
        }
    }
}

// MARK: Sessões novas e faixa compacta

/// Padrão de "Subagent computers" das sessões novas (o mesmo de Settings › Computers), aqui onde a escolha faz sentido.
private struct NewSessionsRow: View {
    let settings: SettingsModel

    private var mode: SubagentComputersMode { settings.settings.computers.defaultSubagentMode }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.secondary)
                RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border)
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textSecondary)
            }
            .frame(width: CloudMetrics.accountLogo, height: CloudMetrics.accountLogo)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text("New sessions", bundle: .module).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: mode.explanation).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    .id(mode).transition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s4)
            DSSegmented(
                SubagentComputersMode.allCases.map { .init($0.rawValue, $0.segmentTitle) }, selection: mode.rawValue,
                action: .settingsComputersDefaultSubagentMode, id: .computersNewSessions)
        }
        .padding(DS.Space.s3)
        .cloudTile()
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: mode)
    }
}

private struct CompactWhereBar: View {
    let settings: SettingsModel

    var body: some View {
        let local = settings.settings.computers.runOn == .local
        HStack(spacing: DS.Space.s2) {
            Image(systemName: local ? "laptopcomputer" : "cloud").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary)
            Text(local ? "Computers run on this Mac" : "Computers run in your cloud", bundle: .module)
                .dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            if local {
                LocalStatusLine(status: settings.dockerStatus)
            } else {
                CloudSummaryLine(settings: settings, selected: true)
            }
            Spacer(minLength: DS.Space.s2)
            ActionButton(.computersWhereToggle, id: .computersWhereChange) {
                HStack(spacing: DS.Space.s1) {
                    Text(settings.computersWhereOpen ? "Done" : "Change…", bundle: .module).dsFont(DS.Font.label)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(settings.computersWhereOpen ? 180 : 0))
                }
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: WhereMetrics.compactBar)
        .background(DS.Color.canvas)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: DSMetrics.hairline) }
    }
}

// MARK: Conta e gasto

/// Estado da conta: conectada (conta e o que está subindo agora), esperando o navegador, sessão vencida, sem CLI ou erro.
struct CloudStatusLine: View {
    let settings: SettingsModel

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            switch settings.cloudConnection {
            case .connected(let account):
                PulseDot(color: DS.Color.dataValid, pulsing: settings.cloudProgress != nil)
                Text(verbatim: settings.cloudProgress ?? String(localized: "Connected to AWS account \(account).", bundle: .module))
                    .foregroundStyle(DS.Color.textSecondary)
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Checking your AWS sign-in…", bundle: .module).foregroundStyle(DS.Color.textSecondary)
            case .signingIn:
                ProgressView().controlSize(.mini)
                Text("Confirm the sign-in in your browser.", bundle: .module).foregroundStyle(DS.Color.textSecondary)
            case .signedOut:
                Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Color.warning)
                Text("Your AWS sign-in expired. Connect again to use cloud computers.", bundle: .module).foregroundStyle(DS.Color.warning)
            case .missingCLI:
                Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Color.warning)
                Text("Install the AWS command line tool (aws.amazon.com/cli), then connect.", bundle: .module).foregroundStyle(DS.Color.warning)
            case .failed(let message):
                Image(systemName: "xmark.circle").foregroundStyle(DS.Color.destructive)
                Text(verbatim: message).foregroundStyle(DS.Color.destructive).lineLimit(2)
            case .unknown:
                Image(systemName: "cloud").foregroundStyle(DS.Color.textTertiary)
                Text("Connect your AWS account to run computers there.", bundle: .module).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .dsFont(DS.Font.small)
        .a11y(.computersCloudStatus, kind: "text", value: settings.cloudConnection.summary)
    }
}
