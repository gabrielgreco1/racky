import Foundation
import RackyCore
import RackyProtocol
import RackyStore

// Amazon S3 como conexão de verdade: formulário, cliente (chaves do cofre ou perfil do AWS CLI), explorer (conexão → buckets → pastas,
// lidas só ao abrir), pasta com paginação e prévia de arquivos. Só leitura. Fica separado de `DataHubConnections` (Prefect).

/// Como o S3 autentica e onde fica. O segredo (chave secreta e token) fica no cofre; aqui só o que não é segredo.
nonisolated public struct S3Settings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case keys, profile }
    public var mode: Mode
    public var region: String
    /// Só este bucket (para chaves que não podem listar todos).
    public var bucket: String?
    /// Nome do perfil no AWS CLI (modo `profile`).
    public var profile: String?
    /// ID da chave de acesso (modo `keys`); não é segredo.
    public var accessKeyID: String?

    public init(mode: Mode, region: String, bucket: String? = nil, profile: String? = nil, accessKeyID: String? = nil) {
        self.mode = mode; self.region = region; self.bucket = bucket; self.profile = profile; self.accessKeyID = accessKeyID
    }
}

/// O que o formulário do S3 manda.
struct S3ConnectForm: Decodable {
    var name: String?
    var mode: S3Settings.Mode
    var region: String?
    var bucket: String?
    var accessKey: String?
    var secret: String?
    var sessionToken: String?
    var profile: String?
}

/// Nomes já listados de um nível do explorer (buckets, ou as pastas dentro de um prefixo).
struct S3Level: Equatable {
    var names: [String] = []
    var loaded = false
    var error: String?
}

/// Uma linha da pasta: subpasta ou objeto.
struct S3Entry: Identifiable, Equatable {
    var id: String { key }
    var name: String
    /// Chave inteira (ou o prefixo, no caso de pasta).
    var key: String
    var folder: Bool
    var size: Int64 = 0
    var modified: Date?
}

/// Uma pasta aberta: a página atual e os tokens de continuação de cada página (para voltar).
struct S3FolderState: Equatable {
    var entries: [S3Entry] = []
    var tokens: [String?] = [nil]
    var page = 0
    var hasNext = false
    var loading = false
    var loaded = false
    var error: String?
}

extension DataHubController {
    static let s3PageSize = 100

    func isLiveS3(_ connection: String?) -> Bool { saved.contains { $0.id == connection && $0.kind == .s3 } }

    // MARK: Cliente

    func s3Client(_ id: String) async throws -> S3Client {
        if let client = s3Clients[id] { return client }
        guard let entry = saved.first(where: { $0.id == id }), let settings = entry.s3 else { throw S3Client.Failure.notFound(id) }
        let client = try await buildS3Client(id: id, settings: settings, secretID: entry.secretID, keys: nil)
        s3Clients[id] = client
        return client
    }

    /// `keys`: chaves recém-digitadas (ainda não estão no cofre). Sem elas, as chaves vêm do cofre.
    func buildS3Client(id: String, settings: S3Settings, secretID: UUID?, keys: AWSCredentials?) async throws -> S3Client {
        switch settings.mode {
        case .keys:
            var found = keys
            if found == nil, let keyID = settings.accessKeyID, let secretID, let vault, let value = try? await vault.reveal(id: secretID),
               let json = try? JSONSerialization.jsonObject(with: Data(value.text.utf8)) as? [String: String], let secret = json["secret"] {
                found = AWSCredentials(accessKeyID: keyID, secretAccessKey: secret, sessionToken: json["token"])
            }
            guard let credentials = found else {
                throw S3Client.Failure.credentials(String(localized: "The saved keys are missing from this Mac's secure vault. Remove the connection and add it again.", bundle: .module))
            }
            return S3Client(region: settings.region, credentials: { credentials }, transport: s3Transport)
        case .profile:
            let provider = AWSProfileCredentials(profile: settings.profile ?? "", runner: s3Runner)
            s3Providers[id] = provider
            return S3Client(region: settings.region, credentials: { try await provider.credentials() }, transport: s3Transport)
        }
    }

    /// Roda uma leitura; com perfil do CLI, se a AWS recusar as credenciais em cache, pede novas e tenta uma vez mais.
    func s3Run<T: Sendable>(_ id: String, _ operation: (S3Client) async throws -> T) async throws -> T {
        let client = try await s3Client(id)
        do {
            return try await operation(client)
        } catch let failure as S3Client.Failure {
            guard case .auth = failure, let provider = s3Providers[id] else { throw failure }
            await provider.invalidate()
            return try await operation(client)
        }
    }

    /// A frase que o usuário vê para um erro do S3 ou do AWS CLI.
    func s3Message(_ error: Error, listingBuckets: Bool = false) -> String {
        if case S3Client.Failure.accessDenied = error, listingBuckets {
            return String(localized: "These credentials cannot list buckets. Enter a bucket name to connect to just that one.", bundle: .module)
        }
        if let failure = error as? S3Client.Failure { return failure.description }
        if let failure = error as? AWSCredentialsFailure { return failure.description }
        return error.localizedDescription
    }

    // MARK: Conectar

    func saveS3(_ arg: ActionArgument) async throws -> String {
        guard arg.kind == .set, let raw = arg.value, let form = try? JSONDecoder().decode(S3ConnectForm.self, from: Data(raw.utf8)) else {
            throw ActionError.failed(.dataConnectSave, message: "expected set({\"name\",\"mode\",\"region\",\"bucket\",\"accessKey\",\"secret\",\"sessionToken\",\"profile\"})")
        }
        guard await saveS3Connection(form) else { throw ActionError.failed(.dataConnectSave, message: connectError ?? "") }
        return "saved"
    }

    /// Testa as credenciais (lista os buckets, ou lê 1 item do bucket) e, se valerem, salva: a chave secreta e o token vão para o cofre.
    func saveS3Connection(_ form: S3ConnectForm) async -> Bool {
        guard connecting == .s3 else { connectError = String(localized: "This connection type is not available yet.", bundle: .module); return false }
        func clean(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var bucket = clean(form.bucket)
        if bucket.hasPrefix("s3://") { bucket.removeFirst(5) }
        bucket = bucket.split(separator: "/").first.map(String.init) ?? ""
        let region = clean(form.region).isEmpty ? "us-east-1" : clean(form.region)
        var settings = S3Settings(mode: form.mode, region: region, bucket: bucket.isEmpty ? nil : bucket)
        var keys: AWSCredentials?
        switch form.mode {
        case .keys:
            let keyID = clean(form.accessKey), secret = clean(form.secret), token = clean(form.sessionToken)
            guard !keyID.isEmpty, !secret.isEmpty else {
                connectError = String(localized: "Enter the access key ID and the secret access key.", bundle: .module)
                return false
            }
            settings.accessKeyID = keyID
            keys = AWSCredentials(accessKeyID: keyID, secretAccessKey: secret, sessionToken: token.isEmpty ? nil : token)
        case .profile:
            let profile = clean(form.profile)
            guard !profile.isEmpty else { connectError = String(localized: "Enter the AWS CLI profile name.", bundle: .module); return false }
            settings.profile = profile
        }
        let id = "conn-\(UUID().uuidString.lowercased().prefix(8))"
        connectBusy = true
        defer { connectBusy = false }
        let client: S3Client
        do {
            client = try await buildS3Client(id: id, settings: settings, secretID: nil, keys: keys)
            try await client.check(bucket: settings.bucket)
        } catch {
            connectError = s3Message(error, listingBuckets: settings.bucket == nil)
            s3Providers[id] = nil
            return false
        }
        var secretID: UUID?
        if let keys, let vault {
            var payload = ["secret": keys.secretAccessKey]
            if let token = keys.sessionToken { payload["token"] = token }
            let value = (try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)) ?? ""
            let title = clean(form.name).isEmpty ? DataConnectionKind.s3.title : clean(form.name)
            secretID = try? await vault.create(NewSecret(
                name: "\(title) · \(DataConnectionKind.s3.title) connection (\(id))", value: value, kind: .envVar, delivery: .sidecarOnly,
                note: String(localized: "Data connection credential: only Racky reads it, never an agent's terminal.", bundle: .module))).id
        }
        let name = clean(form.name).isEmpty ? (settings.bucket ?? DataConnectionKind.s3.title) : clean(form.name)
        let address = settings.bucket.map { "s3://\($0) · \(region)" } ?? "Amazon S3 · \(region)"
        saved.append(SavedConnection(id: id, kind: .s3, name: name, url: address, auth: .none, secretID: secretID, s3: settings))
        s3Clients[id] = client
        try? await store?.setUIState(Self.savedKey, saved)
        rebuildConnections()
        connecting = nil
        connectError = nil
        showingConnect = false
        expanded.insert(id)
        if let bucket = settings.bucket {
            expanded.insert("\(id)/\(bucket)/")
            open(.folder(connection: id, path: [bucket]))
        } else {
            await loadS3Level(id)
        }
        return true
    }

    /// Tira o que a conexão deixou em memória (a remoção em si e o cofre são de `removeConnection`).
    func forgetS3(_ id: String) {
        for (key, task) in s3Tasks where key.contains(id) { task.cancel() }
        s3Clients[id] = nil
        s3Providers[id] = nil
        s3Tree = s3Tree.filter { !($0.key == id || $0.key.hasPrefix("\(id)/")) }
        s3Folders = s3Folders.filter { $0.key.connectionID != id }
        s3Previews = s3Previews.filter { !$0.key.hasPrefix("\(id)|") }
    }

    // MARK: Explorer

    /// Uma tarefa por chave: quem pede de novo enquanto ela roda espera a mesma.
    private func s3Once(_ key: String, _ work: @escaping @MainActor () async -> Void) async {
        if let task = s3Tasks[key] { await task.value; return }
        let task = Task { await work() }
        s3Tasks[key] = task
        await task.value
        s3Tasks[key] = nil
    }

    /// O nó do explorer foi aberto: lê o que tem dentro (buckets de uma conexão, pastas de um bucket ou prefixo).
    func s3Expanded(_ node: String) {
        let connection = String(node.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard isLiveS3(connection) else { return }
        Task { await loadS3Level(node) }
    }

    /// `conexão`, `conexão/bucket/` ou `conexão/bucket/a/b/`.
    private func s3Location(_ node: String) -> (connection: String, bucket: String?, prefix: String) {
        let parts = node.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let bucket = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (parts[0], bucket, parts.count > 2 ? parts[2] : "")
    }

    func loadS3Level(_ node: String, force: Bool = false) async {
        let place = s3Location(node)
        guard isLiveS3(place.connection), s3Tree[node]?.loaded != true || force else { return }
        // Com um bucket só, a conexão já mostra ele (não há o que listar).
        if place.bucket == nil, saved.first(where: { $0.id == place.connection })?.s3?.bucket != nil { return }
        await s3Once("tree:\(node)") { [self] in
            var level = s3Tree[node] ?? S3Level()
            do {
                if let bucket = place.bucket {
                    let page = try await s3Run(place.connection) { try await $0.list(bucket: bucket, prefix: place.prefix, delimiter: "/", maxKeys: 200) }
                    level.names = page.prefixes.map { Self.leaf($0, under: place.prefix) }
                } else {
                    level.names = try await s3Run(place.connection) { try await $0.listBuckets() }.map(\.name).sorted()
                }
                level.error = nil
            } catch {
                level.error = s3Message(error, listingBuckets: place.bucket == nil)
            }
            level.loaded = true
            s3Tree[node] = level
            rebuildConnections()
        }
    }

    /// "books/2026-10-21/" dentro de "books/" → "2026-10-21".
    static func leaf(_ prefix: String, under parent: String) -> String {
        var name = String(prefix.dropFirst(parent.count))
        if name.hasSuffix("/") { name.removeLast() }
        return name
    }

    func s3RootChildren(_ entry: SavedConnection) -> [DataNode] {
        guard let settings = entry.s3 else { return [] }
        if let bucket = settings.bucket { return [s3BucketNode(entry.id, bucket)] }
        let level = s3Tree[entry.id]
        var nodes = (level?.names ?? []).map { s3BucketNode(entry.id, $0) }
        if let error = level?.error { nodes.append(DataNode(id: "\(entry.id)/!error", kind: .file, name: error)) }
        return nodes
    }

    private func s3BucketNode(_ connection: String, _ bucket: String) -> DataNode {
        s3Node(connection, bucket, prefix: "", name: bucket, kind: .bucket)
    }

    private func s3Node(_ connection: String, _ bucket: String, prefix: String, name: String, kind: DataNode.Kind) -> DataNode {
        let id = "\(connection)/\(bucket)/\(prefix)"
        let level = s3Tree[id]
        var children = (level?.names ?? []).map { s3Node(connection, bucket, prefix: "\(prefix)\($0)/", name: $0, kind: .folder) }
        if let error = level?.error { children.append(DataNode(id: "\(id)!error", kind: .file, name: error)) }
        return DataNode(id: id, kind: kind, name: name, children: children, lazy: level?.loaded != true)
    }

    // MARK: Pasta

    /// Pasta de um bucket (`path` = bucket + pastas): prefixo no S3.
    static func s3Prefix(_ path: [String]) -> String {
        let folders = path.dropFirst()
        return folders.isEmpty ? "" : folders.joined(separator: "/") + "/"
    }

    /// Lê uma página da pasta (a primeira, ou `page` quando se navega).
    func loadS3Folder(_ object: DataObject, page: Int? = nil, force: Bool = false) async {
        guard case .folder(let connection, let path) = object, isLiveS3(connection), let bucket = path.first else { return }
        let existing = s3Folders[object]
        if page == nil, existing?.loaded == true, !force { return }
        let prefix = Self.s3Prefix(path)
        await s3Once("folder:\(object.key)") { [self] in
            var state = s3Folders[object] ?? S3FolderState()
            let target = min(max(page ?? state.page, 0), state.tokens.count - 1)
            state.loading = true
            state.error = nil
            s3Folders[object] = state
            do {
                let token = state.tokens[target]
                let result = try await s3Run(connection) {
                    try await $0.list(bucket: bucket, prefix: prefix, delimiter: "/", continuationToken: token, maxKeys: Self.s3PageSize)
                }
                state.entries = result.prefixes.map { S3Entry(name: Self.leaf($0, under: prefix), key: $0, folder: true) }
                    + result.objects.filter { $0.key != prefix }.map {
                        S3Entry(name: String($0.key.dropFirst(prefix.count)), key: $0.key, folder: false, size: $0.size, modified: $0.lastModified)
                    }
                state.page = target
                state.hasNext = result.nextToken != nil
                state.tokens = Array(state.tokens.prefix(target + 1))
                if let next = result.nextToken { state.tokens.append(next) }
            } catch {
                state.error = s3Message(error)
            }
            state.loaded = true
            state.loading = false
            s3Folders[object] = state
        }
    }

    /// `data.s3Page`: página seguinte ou anterior da pasta ativa.
    func s3PageAction(_ arg: ActionArgument) async throws -> String {
        guard let active, case .folder(let connection, _) = active, isLiveS3(connection) else {
            throw ActionError.failed(.dataS3Page, message: String(localized: "Open an S3 folder first.", bundle: .module))
        }
        let state = s3Folders[active] ?? S3FolderState()
        switch arg.value {
        case "next": guard state.hasNext else { return "\(state.page + 1)" }; await loadS3Folder(active, page: state.page + 1)
        case "prev": guard state.page > 0 else { return "\(state.page + 1)" }; await loadS3Folder(active, page: state.page - 1)
        default: throw ActionError.failed(.dataS3Page, message: "expected select(next|prev)")
        }
        return "\((s3Folders[active]?.page ?? 0) + 1)"
    }

    // MARK: Prévia

    static func s3PreviewKey(_ connection: String, _ bucket: String, _ key: String) -> String { "\(connection)|\(bucket)|\(key)" }

    /// Lê os primeiros 256 KB de um arquivo de dados (CSV, JSON, JSON Lines, texto); outros formatos só mostram os metadados.
    func loadS3Preview(connection: String, bucket: String, entry: S3Entry) async {
        let cacheKey = Self.s3PreviewKey(connection, bucket, entry.key)
        if let preview = s3Previews[cacheKey], preview.content != nil, !isFailed(preview.content) { return }
        await s3Once("preview:\(cacheKey)") { [self] in
            var preview = S3Preview(key: entry.key, size: entry.size, modified: entry.modified, content: nil, truncated: false, loading: true)
            s3Previews[cacheKey] = preview
            if S3PreviewParser.format(of: entry.name) == .other {
                preview.content = .metadataOnly
            } else if entry.size == 0 {
                preview.content = .text("")
            } else {
                do {
                    let chunk = try await s3Run(connection) { try await $0.preview(bucket: bucket, key: entry.key) }
                    preview.truncated = (chunk.total ?? Int64(chunk.data.count)) > Int64(chunk.data.count)
                    preview.content = S3PreviewParser.parse(chunk.data, name: entry.name, truncated: preview.truncated)
                } catch {
                    preview.content = .failed(s3Message(error))
                }
            }
            preview.loading = false
            s3Previews[cacheKey] = preview
        }
    }

    private func isFailed(_ content: S3PreviewContent?) -> Bool {
        if case .failed = content { return true }
        return false
    }
}
