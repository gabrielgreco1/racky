import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Settings › Computers › Proxies (03 §14.2, P13): lista, padrão global, formulário, teste e importação do CLI antigo.
/// Cada controle é uma ação `proxy.*`; a senha vai para o Vault e nunca volta para a tela.
struct ProxiesSettingsBlock: View {
    @Bindable var model: SettingsModel

    private func pid(_ key: String) -> A11yID { .settings("computers", "proxy\(key)") }

    private var defaultSelection: String { model.defaultProxyID?.uuidString ?? "none" }

    private var defaultEntries: [DSMenuEntry] {
        [.item(DSMenuItem("none", String(localized: "None (direct)", bundle: .module)))]
            + model.proxies.map { .item(DSMenuItem($0.id.uuidString, $0.name, detail: Self.endpoint($0), detailMono: true)) }
    }

    static func endpoint(_ proxy: ProxyProfile) -> String { "\(proxy.host):\(proxy.port)" }

    var body: some View {
        SettingsBlock(title: "Proxies") {
            SettingsRow(title: "Default proxy for computers", help: "Used when a session or request doesn't choose one.") {
                DSCombobox(id: .settings("computers", "defaultProxy"), selection: defaultSelection, entries: defaultEntries, action: .proxySetDefault)
            }
            VStack(spacing: .zero) {
                if model.proxies.isEmpty && model.proxyDraft?.isNew != true {
                    Text("No proxies. Computers connect directly.", bundle: .module)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.profileRowHeight, alignment: .leading)
                        .padding(.horizontal, DS.Space.s3)
                        .a11y(pid("Empty"), kind: "text", label: "No proxies. Computers connect directly.")
                }
                ForEach(model.proxies) { proxy in
                    ProxyRow(model: model, proxy: proxy)
                    if model.proxyDraft?.id == proxy.id { ProxyForm(model: model) }
                }
                if model.proxyDraft?.isNew == true { ProxyForm(model: model) }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border, lineWidth: DSMetrics.hairline))
            .opacity(model.proxies.isEmpty && model.proxyDraft == nil ? 0.9 : 1)
            HStack(spacing: DS.Space.s2) {
                DSButton(.proxyAdd, id: .settingsComputersProxiesAdd, "Add Proxy", variant: .outline, symbol: "plus")
                if model.zyteImportAvailable {
                    DSButton(.proxyImportFromCLI, id: pid("ImportCLI"), "Import from racky CLI…", variant: .outline)
                }
            }
            if model.zyteImportArmed {
                ConfirmStrip(
                    text: "Read the Zyte API key from your racky CLI settings? The file isn't changed.",
                    confirm: DSButton(
                        .proxyImportFromCLI, id: pid("ImportCLIConfirm"), "Import", variant: .primary, argument: .select("confirm")))
            }
        }
    }
}

/// Aviso de confirmação inline (03 §14.2): texto e o botão que confirma; o clique no botão original reabre a pergunta.
private struct ConfirmStrip: View {
    let text: LocalizedStringKey
    let confirm: DSButton

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            Text(text, bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
            Spacer(minLength: DS.Space.s2)
            confirm
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.fg5))
    }
}

private struct ProxyRow: View {
    let model: SettingsModel
    let proxy: ProxyProfile

    private var idString: String { proxy.id.uuidString }
    private var isDefault: Bool { model.defaultProxyID == proxy.id }
    private var armed: Bool { model.proxyDeleteArmed == proxy.id }
    private func pid(_ name: String) -> A11yID { .settings("computers", "proxy\(name)-\(idString)") }

    private var typeLabel: String {
        proxy.preset == .zyte ? "Zyte" : proxy.scheme.rawValue.uppercased()
    }

    private func iconButton(_ action: ActionID, _ id: A11yID, _ symbol: String, _ name: String, argument: String, destructive: Bool = false, active: Bool = false)
        -> some View
    {
        ActionButton(action, id: id, argument: .select(argument), tooltip: name) { Image(systemName: symbol) }
            .buttonStyle(DSIconButtonStyle(.header, destructive: destructive, active: active))
            .accessibilityLabel(Text(verbatim: name))
    }

    var body: some View {
        VStack(spacing: .zero) {
            HStack(spacing: DS.Space.s2) {
                Text(verbatim: proxy.name)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                DSBadge(typeLabel, variant: .mono)
                Text(verbatim: ProxiesSettingsBlock.endpoint(proxy) + (proxy.geo?.country.map { " · \($0.uppercased())" } ?? ""))
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDefault { DSBadge(String(localized: "Default", bundle: .module), variant: .mono) }
                Spacer(minLength: DS.Space.s2)
                iconButton(.proxyEdit, pid("Edit"), "pencil", String(localized: "Edit", bundle: .module), argument: idString, active: model.proxyDraft?.id == proxy.id)
                iconButton(.proxyTest, pid("Test"), "bolt.horizontal", String(localized: "Test connection", bundle: .module), argument: idString)
                iconButton(.proxyDelete, pid("Delete"), "trash", String(localized: "Delete…", bundle: .module), argument: idString, destructive: true)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(minHeight: SettingsMetrics.profileRowHeight)
            if armed {
                ConfirmStrip(
                    text: "Delete this proxy? Its credential leaves the Vault.",
                    confirm: DSButton(.proxyDelete, id: pid("DeleteConfirm"), "Delete", variant: .destructive, argument: .select("\(idString):confirm")))
            }
        }
        .a11y(.settingsComputersProxiesRow(idString), kind: "row", label: proxy.name)
    }
}

/// Formulário do proxy: nome, preset, tipo, host, porta, usuário, senha (Vault, mascarada) e país opcional.
private struct ProxyForm: View {
    @Bindable var model: SettingsModel

    private func pid(_ key: String) -> A11yID { .settings("computers", "proxy\(key)") }

    private func bind(_ keyPath: WritableKeyPath<ProxyDraft, String>) -> Binding<String> {
        Binding(get: { model.proxyDraft?[keyPath: keyPath] ?? "" }, set: { value in model.updateProxyDraft { $0[keyPath: keyPath] = value } })
    }

    private var draft: ProxyDraft { model.proxyDraft ?? ProxyDraft() }
    private var isZyte: Bool { draft.preset == .zyte }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
            SettingsRow(title: "Name", help: nil) {
                DSTextField("zyte-us", text: bind(\.name), id: pid("Name"), compact: true)
            }
            SettingsRow(title: "Preset", help: "A preset only fills in the fields below.") {
                DSSegmented(
                    [.init(ProxyPreset.custom.rawValue, "Custom"), .init(ProxyPreset.zyte.rawValue, "Zyte")], selection: draft.preset.rawValue,
                    action: .proxyPreset, id: pid("Preset"))
            }
            SettingsRow(title: "Type", help: nil) {
                DSSegmented(
                    [.init(ProxyScheme.http.rawValue, "HTTP"), .init(ProxyScheme.https.rawValue, "HTTPS"), .init(ProxyScheme.socks5.rawValue, "SOCKS5")],
                    selection: draft.scheme.rawValue, action: .proxyScheme, id: pid("Scheme"))
            }
            SettingsRow(title: "Host", help: nil) {
                DSTextField("proxy.example.com", text: bind(\.host), id: pid("Host"), compact: true, mono: true)
            }
            SettingsRow(title: "Port", help: nil) {
                DSTextField("8080", text: bind(\.port), id: pid("Port"), compact: true, mono: true)
            }
            if !isZyte {
                SettingsRow(title: "Username", help: "Optional.") {
                    DSTextField("None", text: bind(\.username), id: pid("Username"), compact: true, mono: true)
                }
            }
            SettingsRow(title: isZyte ? "API key" : "Password", helpText: draft.isNew ? "Stored in the Vault." : "Stored in the Vault. Leave empty to keep it.") {
                ProxySecretField(text: bind(\.password), id: pid("Password"), placeholder: draft.isNew ? "" : "Saved")
            }
            SettingsRow(title: "Country", help: "Optional. Two letters, like us.") {
                DSTextField("Any", text: bind(\.country), id: pid("Country"), compact: true, mono: true)
            }
            if let error = draft.error {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small)
                }
                .foregroundStyle(DS.Color.destructive)
                .a11y(pid("Error"), kind: "text", label: error)
            }
            HStack(spacing: DS.Space.s2) {
                DSButton(.proxySave, id: pid("Save"), draft.isNew ? "Add" : "Save", variant: .primary)
                DSButton(.proxyCancel, id: pid("Cancel"), "Cancel", variant: .ghost)
                Spacer(minLength: DS.Space.s2)
                testStatus
                DSButton(.proxyTest, id: .settingsComputersProxiesTest, "Test connection", variant: .outline, loading: model.proxyTest == .running ? "Testing…" : nil)
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.fg5)
        .a11y(pid("Form"), kind: "container", label: draft.name)
    }

    @ViewBuilder private var testStatus: some View {
        if case .result(let result) = model.proxyTest {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: result.ok ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: DS.Space.s3))
                Text(verbatim: result.summary).dsFont(DS.Font.small).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(result.ok ? DS.Color.success : DS.Color.destructive)
            .dsTooltip(result.summary)
            .a11y(pid("TestResult"), kind: "text", label: result.summary)
        }
    }
}

/// Campo de senha mascarado com a mesma moldura dos demais campos (02 §12.10).
private struct ProxySecretField: View {
    @Binding var text: String
    let id: A11yID
    let placeholder: LocalizedStringKey
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder, bundle: .module).foregroundStyle(DS.Color.textQuaternary).allowsHitTesting(false).accessibilityHidden(true)
            }
            SecureField(text: $text) { EmptyView() }
                .textFieldStyle(.plain)
                .focused($focused)
        }
        .dsFont(DS.Font.monoPane)
        .foregroundStyle(DS.Color.textPrimary)
        .dsFieldChrome(focused: focused, invalid: false, disabled: !isEnabled, height: DSMetrics.fieldHeightComposer)
        .a11y(id, kind: "textfield", value: text.isEmpty ? "" : "••••••", action: nil)
    }
}
