import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

// A nuvem na página Computers, no mesmo idioma dos tiles de provedor: passos com ✓ (provedor, conta, região, limites) e um
// "Save and turn on" obrigatório; depois de salvo, uma linha de resumo com Edit e o gasto (tiles + tabela das VMs).

enum CloudMetrics {
    static let tileRadius: CGFloat = 12
    static let regionTile: CGFloat = 64
    static let limitTile: CGFloat = 104
    static let kpiTile: CGFloat = 96
    static let accountLogo: CGFloat = 34
    static let countryBadgeWidth: CGFloat = 24
    static let barHeight: CGFloat = 4
    static let stepHeight: CGFloat = 22
    static let colState: CGFloat = 60
    static let colStarted: CGFloat = 110
    static let colTime: CGFloat = 64
    static let colCost: CGFloat = 76
    static let colAction: CGFloat = 52
}

/// Fundo e borda dos tiles (o mesmo dos tiles de provedor).
struct CloudTileBackground: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: CloudMetrics.tileRadius).fill(selected ? DS.Color.secondary : DS.Color.chrome))
            .overlay(
                RoundedRectangle(cornerRadius: CloudMetrics.tileRadius)
                    .strokeBorder(selected ? DS.Color.textPrimary.opacity(0.8) : DS.Color.border, lineWidth: selected ? WhereMetrics.ringWidth : 1))
    }
}

extension View {
    func cloudTile(selected: Bool = false) -> some View { modifier(CloudTileBackground(selected: selected)) }
}

/// Rótulo de um passo: bolinha com o número (✓ quando pronto), o título e uma dica à direita.
struct CloudStepLabel: View {
    let number: Int
    let title: String
    let done: Bool
    var hint: String?

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            ZStack {
                Circle().fill(done ? DS.Color.dataValid.opacity(0.14) : DS.Color.secondary)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Color.dataValid)
                } else {
                    Text(verbatim: "\(number)").dsFont(DS.Font.micro).foregroundStyle(DS.Color.textSecondary)
                }
            }
            .frame(width: WhereMetrics.stepBadge, height: WhereMetrics.stepBadge)
            Text(verbatim: title).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: DS.Space.s2)
            if let hint { Text(verbatim: hint).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
        }
        .padding(.horizontal, DS.Space.s0_5)
    }
}

// MARK: Passos

/// Provedor, conta, região e limites, e o Save que liga a nuvem (antes dele os computers seguem no Mac).
struct CloudSetupView: View {
    let settings: SettingsModel
    @State private var shown = false

    private var cloud: AppSettings.Cloud { settings.settings.computers.cloud }
    private var provider: CloudProviderInfo { settings.cloudProvider }
    private var connected: Bool { settings.cloudConnection.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                CloudStepLabel(number: 1, title: String(localized: "Provider", bundle: .module), done: true)
                HStack(spacing: DS.Space.s2) {
                    ForEach(CloudProviderCatalog.all) { info in ProviderTile(info: info, selected: info.id == provider.id) }
                }
            }
            .stagger(0, shown)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                CloudStepLabel(number: 2, title: String(localized: "Account", bundle: .module), done: connected)
                CloudAccountTile(settings: settings, provider: provider)
            }
            .stagger(1, shown)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                CloudStepLabel(
                    number: 3, title: String(localized: "Region", bundle: .module), done: true,
                    hint: String(localized: "Pick the closest: the screen streams to you from there.", bundle: .module))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s2), count: 4), spacing: DS.Space.s2) {
                    ForEach(provider.regions) { region in CloudRegionTile(region: region, selected: region.id == cloud.region) }
                }
            }
            .stagger(2, shown)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                CloudStepLabel(
                    number: 4, title: String(localized: "Limits", bundle: .module), done: settings.settings.computers.cloud.confirmed,
                    hint: String(localized: "Required before cloud computers can start.", bundle: .module))
                HStack(spacing: DS.Space.s2) {
                    CloudLimitTile(
                        title: String(localized: "Daily limit", bundle: .module), prefix: "US$", number: cloud.dailyCapUSD, key: "daily", id: .computersCloudDailyCap)
                    CloudLimitTile(
                        title: String(localized: "Monthly limit", bundle: .module), prefix: "US$", number: cloud.monthlyCapUSD, key: "monthly",
                        id: .computersCloudMonthlyCap)
                    CloudLimitTile(
                        title: String(localized: "At once", bundle: .module),
                        suffix: cloud.maxComputers == 1 ? String(localized: "computer at once", bundle: .module) : String(localized: "computers at once", bundle: .module),
                        number: cloud.maxComputers, key: "max", id: .computersCloudMaxComputers)
                }
                Text(verbatim: limitNote).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.s0_5)
            }
            .stagger(3, shown)
            saveBar.stagger(4, shown)
        }
        .onAppear { shown = true }
    }

    private var limitNote: String {
        let worst = CloudProviderCatalog.fullDayUSD(provider: provider, computers: cloud.maxComputers)
            .map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0))) } ?? "—"
        return String(localized: "At a limit Racky stops creating computers and shuts down the ones that would go over it. All \(cloud.maxComputers) on for a whole day: about \(worst).", bundle: .module)
    }

    private var saveBar: some View {
        HStack(spacing: DS.Space.s3) {
            Text(connected
                ? String(localized: "Cloud computers start only after you save. Until then they keep running on this Mac.", bundle: .module)
                : String(localized: "Connect your AWS account first. Until then computers keep running on this Mac.", bundle: .module))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            DSButton(.computersCloudCancel, id: .computersCloudCancel, "Cancel", variant: .ghost, size: .sm)
            DSButton(
                .computersCloudSave, id: .computersCloudSave, settings.settings.computers.cloud.confirmed ? "Save" : "Save and turn on",
                variant: .primary, size: .sm)
        }
        .padding(DS.Space.s3)
        .cloudTile()
    }
}

/// Conta: o logo do provedor, o estado da sessão e Connect / Check again.
struct CloudAccountTile: View {
    let settings: SettingsModel
    let provider: CloudProviderInfo

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.control).fill(DSRGBA(hex: provider.brandHex).color.opacity(0.1))
                RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DSRGBA(hex: provider.brandHex).color.opacity(0.35))
                DSBrandLogo(provider.logo, size: WhereMetrics.providerLogo - 6, tint: DSRGBA(hex: provider.brandHex).color)
            }
            .frame(width: CloudMetrics.accountLogo, height: CloudMetrics.accountLogo)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                CloudStatusLine(settings: settings)
                Text("Signed in with aws login in your browser. Racky never sees your password or keys. Connecting accepts the AWS Acceptable Use Policy.", bundle: .module)
                    .dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s2)
            if settings.cloudConnection.isConnected {
                DSButton(.computersCloudConnect, id: .computersCloudConnect, "Check Again", variant: .ghost, size: .sm)
            } else {
                DSButton(.computersCloudConnect, id: .computersCloudConnect, "Connect \(provider.name)…", variant: .primary, size: .sm)
            }
        }
        .padding(DS.Space.s3)
        .cloudTile()
    }
}

/// Região: código do país (texto, legível) no lugar da bandeira, a cidade e o código da AWS.
struct CloudRegionTile: View {
    let region: CloudRegionInfo
    let selected: Bool
    @State private var hovering = false

    /// `🇺🇸` -> `US` (os dois indicadores regionais viram letras).
    static func countryCode(_ flag: String) -> String {
        String(flag.unicodeScalars.compactMap { scalar in
            (0x1F1E6...0x1F1FF).contains(scalar.value) ? Character(UnicodeScalar(scalar.value - 0x1F1E6 + 65)!) : nil
        })
    }

    var body: some View {
        ActionButton(.computersCloudRegion, id: .computersCloudRegion(region.id), argument: .select(region.id)) {
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                HStack(alignment: .top) {
                    Text(verbatim: Self.countryCode(region.flag))
                        .dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textSecondary)
                        .frame(width: CloudMetrics.countryBadgeWidth)
                        .padding(.vertical, DSMetrics.hairline)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs).strokeBorder(DS.Color.borderStrong))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(DS.Color.textPrimary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: region.city).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Text(verbatim: region.id).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            }
            .padding(DS.Space.s2_5)
            .frame(maxWidth: .infinity, minHeight: CloudMetrics.regionTile, alignment: .topLeading)
            .cloudTile(selected: selected)
            .opacity(hovering && !selected ? 0.92 : 1)
            .contentShape(RoundedRectangle(cornerRadius: CloudMetrics.tileRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: selected)
    }
}

/// Um limite: o rótulo, o valor grande (clica e digita; Enter ou sair do campo salva) e − / +.
struct CloudLimitTile: View {
    let title: String
    /// Prefixo antes do número (`US$`) ou unidade depois (`computers`).
    var prefix: String?
    var suffix: String?
    let number: Int
    let key: String
    let id: A11yID
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                if let prefix { Text(verbatim: prefix).dsFont(DS.Font.metric).foregroundStyle(DS.Color.textSecondary) }
                TextField(text: $draft) { EmptyView() }
                    .textFieldStyle(.plain)
                    .dsFont(DS.Font.metric).monospacedDigit().foregroundStyle(DS.Color.textPrimary)
                    .focused($editing)
                    .fixedSize()
                    .onSubmit(commit)
                    .onChange(of: editing) { _, now in if !now { commit() } }
                    .padding(.horizontal, DS.Space.s1).padding(.vertical, DSMetrics.hairline)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.xs + 2).fill(editing ? DS.Color.canvas : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs + 2).strokeBorder(editing ? DS.Color.borderStrong : DS.Color.border))
                    .a11y(id, kind: "textfield", label: title, value: "\(number)", action: .computersCloudLimits)
                if let suffix { Text(verbatim: suffix).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary) }
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.s1) {
                step("minus", "\(key)-")
                step("plus", "\(key)+")
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, minHeight: CloudMetrics.limitTile, alignment: .topLeading)
        .cloudTile(selected: editing)
        .onAppear { draft = "\(number)" }
        .onChange(of: number) { _, new in if !editing { draft = "\(new)" } }
    }

    /// Só dígitos; vazio ou inválido volta ao valor salvo. Fora do intervalo, o modelo prende no limite.
    private func commit() {
        let digits = draft.filter(\.isNumber)
        guard let value = Int(digits), let registry else {
            draft = "\(number)"
            return
        }
        // O mesmo limite que o modelo aplica: o campo já mostra o valor que vai valer.
        let range = key == "daily" ? AppSettings.Cloud.dailyCapRange : key == "monthly" ? AppSettings.Cloud.monthlyCapRange : AppSettings.Cloud.maxComputersRange
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        draft = "\(clamped)"
        Task { await registry.performFromUI(.computersCloudLimits, .set("\(key)=\(clamped)")) }
    }

    private func step(_ symbol: String, _ argument: String) -> some View {
        ActionButton(.computersCloudLimits, argument: .select(argument)) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: WhereMetrics.stepperButton, height: CloudMetrics.stepHeight)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs + 2).strokeBorder(DS.Color.borderStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(DSIconButtonStyle(.row))
    }
}

// MARK: Depois de salvo

/// A configuração inteira numa linha, com Edit.
struct CloudSummaryBar: View {
    let settings: SettingsModel

    var body: some View {
        let cloud = settings.settings.computers.cloud
        let provider = settings.cloudProvider
        let city = provider.regions.first { $0.id == cloud.region }?.city ?? cloud.region
        HStack(spacing: DS.Space.s2) {
            PulseDot(color: settings.cloudConnection.isConnected ? DS.Color.dataValid : DS.Color.warning, pulsing: false)
            chip(provider.name, account)
            dot
            chip(city, nil)
            dot
            chip("US$ \(cloud.dailyCapUSD)", String(localized: "per day", bundle: .module))
            dot
            chip("US$ \(cloud.monthlyCapUSD)", String(localized: "per month", bundle: .module))
            dot
            chip("\(cloud.maxComputers)", cloud.maxComputers == 1 ? String(localized: "computer at once", bundle: .module) : String(localized: "computers at once", bundle: .module))
            Spacer(minLength: DS.Space.s2)
            if !settings.cloudConnection.isConnected {
                DSButton(.computersCloudConnect, id: .computersCloudConnect, "Connect \(provider.name)…", variant: .primary, size: .xs)
            }
            DSButton(.computersCloudEdit, id: .computersCloudEdit, "Edit", variant: .ghost, size: .xs)
        }
        .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2_5)
        .cloudTile()
        .a11y(.computersCloudSummary, kind: "group", value: settings.cloudConnection.summary)
    }

    private var account: String? {
        if case .connected(let account) = settings.cloudConnection { return account }
        return String(localized: "Signed out", bundle: .module)
    }

    private var dot: some View { Text(verbatim: "·").dsFont(DS.Font.small).foregroundStyle(DS.Color.textQuaternary) }

    private func chip(_ strong: String, _ rest: String?) -> some View {
        HStack(spacing: DS.Space.s1) {
            Text(verbatim: strong).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            if let rest { Text(verbatim: rest).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary) }
        }
        .lineLimit(1)
    }
}

/// Gasto: hoje e no mês contra o limite, as VMs ligadas agora, e a tabela das VMs (ligadas com Stop, terminadas com o custo).
struct CloudSpendView: View {
    let settings: SettingsModel

    private var snapshot: CloudSnapshot { settings.cloudSnapshot }

    var body: some View {
        let now = Date()
        let cloud = settings.settings.computers.cloud
        let finished = snapshot.records.filter { $0.endedAt != nil }.prefix(8)
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("Spending", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary).padding(.leading, DS.Space.s0_5)
            HStack(spacing: DS.Space.s2) {
                kpi(String(localized: "Today", bundle: .module), snapshot.todayUSD, cap: Double(cloud.dailyCapUSD))
                kpi(String(localized: "This month", bundle: .module), snapshot.monthUSD, cap: Double(cloud.monthlyCapUSD))
                onNow
            }
            .a11y(.computersCloudSpend, kind: "group", value: String(format: "%.4f", snapshot.monthUSD))
            VStack(spacing: 0) {
                header
                if snapshot.hosts.isEmpty && finished.isEmpty {
                    Text("No cloud computers have run yet. Each one shows here with what it cost.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.s3)
                }
                ForEach(snapshot.hosts) { host in
                    row(live: true, shape: host.shape, region: host.region, started: host.startedAt, seconds: now.timeIntervalSince(host.startedAt),
                        cost: host.hourlyUSD * now.timeIntervalSince(host.startedAt) / 3600, hostID: host.id)
                        .a11y(.computersCloudHost(host.id), kind: "row", label: host.id, value: host.shape)
                }
                ForEach(Array(finished), id: \.hostID) { record in
                    row(live: false, shape: record.shape ?? "VM", region: record.region ?? "", started: record.startedAt,
                        seconds: (record.endedAt ?? now).timeIntervalSince(record.startedAt), cost: record.costUSD(now: now), hostID: record.hostID)
                        .a11y(.computersCloudRecord(record.hostID), kind: "row", label: record.hostID, value: String(format: "%.4f", record.costUSD(now: now)))
                }
            }
            .cloudTile()
            .a11y(.computersCloudHosts, kind: "list", value: "\(snapshot.hosts.count)")
            Text("Estimates from AWS on-demand prices (VM, public IP and disk). Your AWS bill is the final word.", bundle: .module)
                .dsFont(DS.Font.micro).foregroundStyle(DS.Color.textQuaternary).padding(.horizontal, DS.Space.s0_5)
        }
    }

    private func kpi(_ title: String, _ value: Double, cap: Double) -> some View {
        let share = cap > 0 ? min(1, value / cap) : 0
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: Self.money(value)).dsFont(DS.Font.metric).foregroundStyle(DS.Color.textPrimary).monospacedDigit()
            Spacer(minLength: 0)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.secondary)
                    Capsule().fill(share >= 0.9 ? DS.Color.destructive : share >= 0.6 ? DS.Color.warning : DS.Color.dataValid)
                        .frame(width: max(CloudMetrics.barHeight, proxy.size.width * share))
                }
            }
            .frame(height: CloudMetrics.barHeight)
            Text(verbatim: String(localized: "of \(Self.money(cap))", bundle: .module)).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, minHeight: CloudMetrics.kpiTile, alignment: .topLeading)
        .cloudTile()
    }

    private var onNow: some View {
        let hourly = snapshot.hosts.reduce(0) { $0 + $1.hourlyUSD }
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text("On now", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: snapshot.hosts.count == 1 ? String(localized: "1 VM", bundle: .module) : String(localized: "\(snapshot.hosts.count) VMs", bundle: .module))
                .dsFont(DS.Font.metric).foregroundStyle(DS.Color.textPrimary).monospacedDigit()
            Spacer(minLength: 0)
            Text(verbatim: snapshot.hosts.isEmpty
                ? String(localized: "Nothing running, nothing billing.", bundle: .module)
                : String(localized: "\(Self.money(hourly))/h · goes off 5 min after its agent ends", bundle: .module))
                .dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, minHeight: CloudMetrics.kpiTile, alignment: .topLeading)
        .cloudTile()
    }

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            Color.clear.frame(width: CloudMetrics.colState)
            Text("Machine", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("Started", bundle: .module).frame(width: CloudMetrics.colStarted, alignment: .leading)
            Text("Time", bundle: .module).frame(width: CloudMetrics.colTime, alignment: .trailing)
            Text("Cost", bundle: .module).frame(width: CloudMetrics.colCost, alignment: .trailing)
            Color.clear.frame(width: CloudMetrics.colAction)
        }
        .dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
        .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: DSMetrics.hairline) }
    }

    private func row(live: Bool, shape: String, region: String, started: Date, seconds: TimeInterval, cost: Double, hostID: String) -> some View {
        HStack(spacing: DS.Space.s2) {
            Text(live ? "On" : "Ended", bundle: .module)
                .dsFont(DS.Font.micro).foregroundStyle(live ? DS.Color.dataValid : DS.Color.textTertiary)
                .padding(.horizontal, DS.Space.s1_5).padding(.vertical, DS.Space.s0_5)
                .background(RoundedRectangle(cornerRadius: DS.Radius.xs + 1).fill(live ? DS.Color.dataValid.opacity(0.12) : DS.Color.secondary))
                .frame(width: CloudMetrics.colState, alignment: .leading)
            HStack(spacing: DS.Space.s1) {
                Text(verbatim: shape).dsFont(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: "· \(region)").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: started.formatted(Calendar.current.isDateInToday(started) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                .frame(width: CloudMetrics.colStarted, alignment: .leading)
            Text(verbatim: Self.duration(seconds)).dsFont(DS.Font.small).monospacedDigit().foregroundStyle(DS.Color.textSecondary)
                .frame(width: CloudMetrics.colTime, alignment: .trailing)
            Text(verbatim: Self.money(cost)).dsFont(DS.Font.small).monospacedDigit().foregroundStyle(DS.Color.textPrimary)
                .frame(width: CloudMetrics.colCost, alignment: .trailing)
            Group {
                if live {
                    DSButton(.computersCloudStopHost, id: .computersCloudHostStop(hostID), "Stop", variant: .ghost, size: .xs, argument: .select(hostID))
                } else {
                    Color.clear
                }
            }
            .frame(width: CloudMetrics.colAction, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
        .overlay(alignment: .top) { DS.Color.border.opacity(0.6).frame(height: DSMetrics.hairline) }
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 && value > 0 ? 3 : (value == 0 ? 0 : 2))))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
