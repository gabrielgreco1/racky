import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

// Telas do Amazon S3 de verdade: o formulário (chaves ou perfil do AWS CLI) e a pasta com objetos reais e prévia. Só leitura.

/// Pasta de um bucket do S3: subpastas e objetos (nome, tamanho, data), páginas pelo token de continuação, e a prévia do arquivo escolhido.
struct S3FolderView: View {
    let hub: DataHubController
    let object: DataObject
    let connection: String
    let path: [String]
    @State private var selected: String?

    private var state: S3FolderState { hub.s3Folders[object] ?? S3FolderState() }
    private var bucket: String { path.first ?? "" }

    var body: some View {
        let state = state
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: "s3://" + path.joined(separator: "/")).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    Spacer(minLength: DS.Space.s2)
                    RemoveConnectionControl(hub: hub, connection: connection, compact: true)
                }
                .padding(.horizontal, DS.Space.s4)
                .frame(height: DS.Space.s8 + DS.Space.s1)
                .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
                if let error = state.error {
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: DS.Space.s3))
                        Text(verbatim: error).dsFont(DS.Font.small).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(DS.Color.warning)
                    .padding(.horizontal, DS.Space.s4)
                    .padding(.vertical, DS.Space.s2)
                    .a11y(.dataS3Error, kind: "text", label: error)
                }
                if state.entries.isEmpty, state.error == nil {
                    Text(verbatim: state.loaded ? String(localized: "This folder is empty.", bundle: .module) : String(localized: "Reading the bucket…", bundle: .module))
                        .dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.entries) { entry in entryRow(entry) }
                        }
                    }
                }
                footer(state)
            }
            .frame(maxWidth: .infinity)
            if let selected, let entry = state.entries.first(where: { $0.key == selected && !$0.folder }) { preview(entry) }
        }
    }

    @ViewBuilder private func entryRow(_ entry: S3Entry) -> some View {
        if entry.folder {
            let target = DataObject.folder(connection: connection, path: path + [entry.name])
            ActionButton(.dataOpen, id: .dataFolderEntry(entry.name), argument: .select(target.key)) { row(entry) }.buttonStyle(.plain)
        } else {
            // lint-ui: allow buttons escolhe o arquivo para a prévia (estado local)
            Button {
                selected = entry.key
                Task { await hub.loadS3Preview(connection: connection, bucket: bucket, entry: entry) }
            } label: { row(entry) }
                .buttonStyle(.plain)
                .a11y(.dataFolderEntry(entry.name), kind: "row", label: entry.name)
        }
    }

    private func row(_ entry: S3Entry) -> some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: entry.folder ? "folder" : "doc").font(.system(size: DataMetrics.icon)).foregroundStyle(DS.Color.textSecondary).frame(width: DS.Space.s4)
            Text(verbatim: entry.name).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            Spacer(minLength: DS.Space.s2)
            Text(verbatim: entry.folder ? String(localized: "Folder", bundle: .module) : S3PreviewParser.label(of: entry.name)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(width: DatasetMetrics.colCount, alignment: .leading)
            Text(verbatim: entry.folder ? "–" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary).frame(width: DatasetMetrics.colCount, alignment: .trailing)
            Text(verbatim: entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(width: DatasetMetrics.colCount + DS.Space.s10, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.s4)
        .frame(height: DatasetMetrics.rowHeight)
        .background(selected == entry.key ? DS.Color.dataKey.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .contentShape(Rectangle())
    }

    private func footer(_ state: S3FolderState) -> some View {
        HStack(spacing: DS.Space.s2) {
            pageButton("chevron.left", id: .dataS3PagePrev, argument: "prev", enabled: state.page > 0 && !state.loading)
            pageButton("chevron.right", id: .dataS3PageNext, argument: "next", enabled: state.hasNext && !state.loading)
            Text(verbatim: String(localized: "Page \(state.page + 1)", bundle: .module)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            if state.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DatasetMetrics.footerHeight)
        .background(DS.Color.chrome)
        .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func pageButton(_ symbol: String, id: A11yID, argument: String, enabled: Bool) -> some View {
        ActionButton(.dataS3Page, id: id, argument: .select(argument)) {
            Image(systemName: symbol).font(.system(size: DS.Space.s2_5, weight: .semibold))
                .foregroundStyle(enabled ? DS.Color.textSecondary : DS.Color.textQuaternary)
                .frame(width: DS.Space.s6, height: DS.Space.s6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.borderStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Prévia

    private func preview(_ entry: S3Entry) -> some View {
        let current = hub.s3Previews[DataHubController.s3PreviewKey(connection, bucket, entry.key)]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: .zero) {
                Text(verbatim: entry.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) + (entry.modified.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(maxWidth: .infinity, minHeight: DS.Space.s8 + DS.Space.s1, alignment: .leading)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            switch current?.content {
            case .grid(let grid):
                DataGridView(grid: grid, footer: String(localized: "Preview · \(grid.rows.count) rows from the first 256 KB", bundle: .module))
            case .text(let text):
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: text).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary).textSelection(.enabled).padding(DS.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .metadataOnly:
                note(String(localized: "No preview for this kind of file. Name, size and date are above.", bundle: .module))
            case .failed(let message):
                note(message)
            case nil:
                note(String(localized: "Reading the file…", bundle: .module))
            }
        }
        .frame(width: DataMetrics.previewWidth)
        .overlay(alignment: .leading) { DS.Color.border.frame(width: ComputersMetrics.separator) }
        .a11y(.dataS3Preview, kind: "container", label: entry.name)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            .padding(DS.Space.s3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Formulário do Amazon S3: chaves de acesso ou perfil do AWS CLI. Testa antes de salvar; a chave secreta vai para o cofre.
struct S3ConnectFormView: View {
    let hub: DataHubController
    let kind: DataConnectionKind
    @State private var name = ""
    /// Abre no perfil do AWS CLI: em empresa o acesso costuma ser por SSO, e com "Access keys" selecionado o campo do perfil ficava
    /// escondido (a última rodada de testers não o achava).
    @State private var mode = S3Settings.Mode.profile
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var sessionToken = ""
    @State private var profile = ""
    @State private var region = "us-east-1"
    @State private var bucket = ""

    private var payload: String {
        let form: [String: String] = [
            "name": name, "mode": mode.rawValue, "region": region, "bucket": bucket, "accessKey": accessKey, "secret": secret,
            "sessionToken": sessionToken, "profile": profile,
        ]
        return (try? String(data: JSONSerialization.data(withJSONObject: form), encoding: .utf8)) ?? "{}"
    }

    private var ready: Bool { mode == .keys ? !accessKey.isEmpty && !secret.isEmpty : !profile.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s2_5) {
                DSDataLogo(kind.brand, size: DataMetrics.connectLogo, tile: true)
                VStack(alignment: .leading, spacing: .zero) {
                    Text(verbatim: kind.title).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    Text(verbatim: kind.tagline).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
            field("Name (optional)") { DSTextField("e.g. scrapes-raw", text: $name, id: .dataConnectName, compact: true) }
            field("Credentials") {
                HStack(spacing: .zero) {
                    choice(.keys, String(localized: "Access keys", bundle: .module))
                    choice(.profile, String(localized: "AWS CLI profile (SSO)", bundle: .module))
                }
                .padding(DSMetrics.segmentedPadding)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.fg6))
                .a11y(.dataConnectS3mode, kind: "segmented", value: mode.rawValue)
            }
            if mode == .keys {
                // Quem entra na AWS por SSO não tem chaves: a rodada de testers não achava o caminho.
                Text("Sign in to AWS with SSO? Run aws sso login --profile <name> in a terminal, then choose AWS CLI profile (SSO), type the profile name and click Test and connect.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s2) {
                    field("Access key ID") { DSTextField("AKIA…", text: $accessKey, id: .dataConnectAccessKey, compact: true, mono: true) }
                    field("Secret access key") { DSTextField("Secret access key", text: $secret, id: .dataConnectSecret, compact: true, secure: true) }
                }
                field("Session token (optional)") { DSTextField("For temporary credentials", text: $sessionToken, id: .dataConnectSessionToken, compact: true, secure: true) }
            } else {
                field("Profile name") { DSTextField("e.g. prod", text: $profile, id: .dataConnectProfile, compact: true, mono: true) }
                Text("Racky runs the AWS CLI to get the credentials. For an SSO profile, run aws sso login --profile <name> in a terminal first.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                field("Default region") { DSTextField("us-east-1", text: $region, id: .dataConnectRegion, compact: true, mono: true) }
                field("Bucket (optional)") { DSTextField("Only this bucket", text: $bucket, id: .dataConnectBucket, compact: true, mono: true) }
            }
            // No modo perfil não há chave guardada: o AWS CLI entrega credenciais temporárias a cada vez.
            Text(mode == .keys
                 ? "Racky only reads from S3. The secret key stays in this Mac's secure vault."
                 : "Racky only reads from S3. No key is stored: the AWS CLI hands Racky short-lived credentials each time.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            if let error = hub.connectError {
                HStack(spacing: DS.Space.s1_5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.Color.destructive)
                .a11y(.dataConnectError, kind: "text", label: error)
            }
            HStack(spacing: DS.Space.s2) {
                DSButton(.dataConnectStart, id: nil, "Back", variant: .ghost, size: .sm, symbol: "chevron.left", argument: .select("close"))
                Spacer(minLength: 0)
                if hub.connectBusy { ProgressView().controlSize(.small) }
                if !ready {
                    Label {
                        Text(mode == .keys ? "Fill in the access key and secret" : "Fill in the profile name", bundle: .module)
                    } icon: { Image(systemName: "info.circle") }
                        .dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                }
                DSButton(.dataConnectSave, id: .dataConnectSave, "Test and connect", variant: .primary, size: .sm, argument: .set(payload))
                    .disabled(!ready || hub.connectBusy)
            }
        }
        .a11y(.dataConnectForm, kind: "form", label: kind.title)
    }

    private func field(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(title, bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
            content()
        }
    }

    private func choice(_ value: S3Settings.Mode, _ title: String) -> some View {
        // lint-ui: allow buttons escolha local do formulário (estado da folha, sem ação de registro; o salvar passa pela ação)
        Button { mode = value } label: { Text(verbatim: title) }
            .buttonStyle(DSSegmentStyle(active: mode == value, fillWidth: true))
            .background {
                if mode == value { RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.textPrimary.opacity(0.16)) }
            }
            // Borda na opção ativa: só o fundo um pouco mais claro não deixava claro qual estava escolhida.
            .overlay {
                if mode == value { RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.textSecondary) }
            }
    }
}
