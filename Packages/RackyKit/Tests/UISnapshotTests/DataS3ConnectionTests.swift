import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Conectar o Amazon S3 pela área Data com um S3 falso: o formulário testa e salva, a chave secreta vai para o cofre, o explorer lista
/// buckets e pastas ao abrir, a pasta pagina pelo token e a prévia lê CSV. Remover apaga o segredo. Nada sai da máquina.
@MainActor
@Suite(.serialized) struct DataS3ConnectionTests {
    nonisolated final class Server: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
            var body = ""
            if status != 200 {
                body = "<Error><Code>InvalidAccessKeyId</Code><Message>The AWS Access Key Id you provided does not exist in our records.</Message></Error>"
            } else if url.host == "s3.us-east-1.amazonaws.com" {
                body = "<ListAllMyBucketsResult><Buckets><Bucket><Name>scrapes-raw</Name></Bucket><Bucket><Name>archive</Name></Bucket></Buckets></ListAllMyBucketsResult>"
            } else if query["list-type"] == "2" {
                let prefix = query["prefix"] ?? ""
                if prefix.isEmpty {
                    body = "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>books/</Prefix></CommonPrefixes></ListBucketResult>"
                } else if query["continuation-token"] == "T1" {
                    body = "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated><Contents><Key>books/c.json</Key><Size>7</Size><LastModified>2026-10-22T10:00:00.000Z</LastModified></Contents></ListBucketResult>"
                } else {
                    body = "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextContinuationToken>T1</NextContinuationToken><CommonPrefixes><Prefix>books/2026/</Prefix></CommonPrefixes><Contents><Key>books/a.csv</Key><Size>24</Size><LastModified>2026-10-22T10:00:00.000Z</LastModified></Contents><Contents><Key>books/b.parquet</Key><Size>900</Size></Contents></ListBucketResult>"
                }
            } else if url.path == "/books/a.csv" {
                body = "title,price\nDune,9.5\n\"Hello, World\",3\n"
            }
            let code = status
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func make() async throws -> (DataHubController, ActionRegistry, Server, SecretVault, RackyStore, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-s3-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        let hub = DataHubController(datasets: DatasetsController(), demo: false)
        let server = Server()
        hub.s3Transport = { request in server.handle(request) }
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        await hub.attach(store: store, vault: vault)
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try hub.register(in: registry)
        return (hub, registry, server, vault, store, home)
    }

    @Test func connectBrowseAndPreviewWithAccessKeys() async throws {
        let (hub, registry, server, vault, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        _ = try await registry.perform(.dataConnectStart, .select("s3"))
        #expect(hub.connecting == .s3)
        let form = #"{"name":"Raw scrapes","mode":"keys","region":"us-east-1","bucket":"","accessKey":"AKIATEST","secret":"s3cret-key","sessionToken":"tok123","profile":""}"#
        _ = try await registry.perform(.dataConnectSave, .set(form))
        let saved = try #require(hub.saved.first)
        #expect(saved.kind == .s3 && saved.name == "Raw scrapes" && saved.s3?.accessKeyID == "AKIATEST" && saved.secretID != nil)

        // O segredo está no cofre e não no estado do app.
        let stored = try #require(try await store.uiState(DataHubController.savedKey, as: [SavedConnection].self))
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
        #expect(!json.contains("s3cret-key") && !json.contains("tok123"))
        #expect(try await vault.reveal(id: try #require(saved.secretID)).text.contains("s3cret-key"))
        // O teste usou ListBuckets, assinado e com o token de sessão; o segredo não viaja.
        let first = try #require(server.requests.first)
        #expect(first.value(forHTTPHeaderField: "x-amz-security-token") == "tok123")
        #expect(first.value(forHTTPHeaderField: "Authorization")?.contains("s3cret-key") == false)

        // Explorer: buckets (lidos ao conectar), depois as pastas do bucket só ao abrir.
        #expect(hub.connection(saved.id)?.children.map(\.name) == ["archive", "scrapes-raw"])
        let bucketNode = "\(saved.id)/scrapes-raw/"
        hub.toggle(bucketNode)
        await hub.loadS3Level(bucketNode)
        let bucket = try #require(hub.connection(saved.id)?.children.first { $0.name == "scrapes-raw" })
        #expect(bucket.children.map(\.name) == ["books"])

        // Pasta: subpasta e arquivos reais; a página 2 vem pelo token.
        let folder = DataObject.folder(connection: saved.id, path: ["scrapes-raw", "books"])
        _ = try await registry.perform(.dataOpen, .select(folder.key))
        await hub.loadS3Folder(folder)
        var state = try #require(hub.s3Folders[folder])
        #expect(state.entries.map(\.name) == ["2026", "a.csv", "b.parquet"] && state.hasNext && state.page == 0)
        #expect(state.entries[1].size == 24 && state.entries[1].modified != nil)
        _ = try await registry.perform(.dataS3Page, .select("next"))
        state = try #require(hub.s3Folders[folder])
        #expect(state.entries.map(\.name) == ["c.json"] && !state.hasNext && state.page == 1)
        _ = try await registry.perform(.dataS3Page, .select("prev"))
        #expect(hub.s3Folders[folder]?.page == 0 && hub.s3Folders[folder]?.entries.count == 3)

        // Prévia: CSV vira grade (aspas e vírgula dentro do campo); parquet só mostra metadados.
        let csv = try #require(hub.s3Folders[folder]?.entries.first { $0.name == "a.csv" })
        await hub.loadS3Preview(connection: saved.id, bucket: "scrapes-raw", entry: csv)
        let preview = try #require(hub.s3Previews[DataHubController.s3PreviewKey(saved.id, "scrapes-raw", csv.key)])
        guard case .grid(let grid) = preview.content else { Issue.record("expected a grid"); return }
        #expect(grid.columns.map(\.name) == ["title", "price"] && grid.rows == [["Dune", "9.5"], ["Hello, World", "3"]])
        let parquet = try #require(hub.s3Folders[folder]?.entries.first { $0.name == "b.parquet" })
        let before = server.requests.count
        await hub.loadS3Preview(connection: saved.id, bucket: "scrapes-raw", entry: parquet)
        #expect(hub.s3Previews[DataHubController.s3PreviewKey(saved.id, "scrapes-raw", parquet.key)]?.content == .metadataOnly)
        #expect(server.requests.count == before)

        // Remover tira a conexão e apaga o segredo.
        let secretID = try #require(saved.secretID)
        _ = try await registry.perform(.dataConnectionRemove, .select(saved.id))
        #expect(hub.saved.contains { $0.id == saved.id }, "o primeiro clique só pede confirmação")
        _ = try await registry.perform(.dataConnectionRemove, .select("\(saved.id)|confirm"))
        #expect(hub.saved.isEmpty && hub.connection(saved.id) == nil && hub.s3Folders.isEmpty && hub.s3Previews.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await vault.reveal(id: secretID) }
    }

    @Test func profileModeUsesTheCLIAndShowsTheLoginHintWhenExpired() async throws {
        let (hub, registry, server, _, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        nonisolated final class Calls: @unchecked Sendable { var count = 0; var expired = true }
        let calls = Calls()
        hub.s3Runner = { arguments in
            calls.count += 1
            #expect(arguments.starts(with: ["configure", "export-credentials", "--profile", "rti"]))
            if calls.expired { return AWSCLIResult(status: 255, stdout: Data(), stderr: "The SSO session associated with this profile has expired") }
            return AWSCLIResult(status: 0, stdout: Data(#"{"Version":1,"AccessKeyId":"ASIAPROF","SecretAccessKey":"x","SessionToken":"y","Expiration":"2099-01-01T00:00:00Z"}"#.utf8), stderr: "")
        }
        _ = try await registry.perform(.dataConnectStart, .select("s3"))
        let form = #"{"name":"","mode":"profile","region":"us-east-1","bucket":"","accessKey":"","secret":"","sessionToken":"","profile":"rti"}"#
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(form)) }
        #expect(hub.saved.isEmpty && hub.connectError?.contains("aws sso login --profile rti") == true)
        #expect(server.requests.isEmpty)

        calls.expired = false
        _ = try await registry.perform(.dataConnectSave, .set(form))
        let saved = try #require(hub.saved.first)
        #expect(saved.s3?.mode == .profile && saved.s3?.profile == "rti" && saved.secretID == nil)
        #expect(server.requests.first?.value(forHTTPHeaderField: "Authorization")?.contains("Credential=ASIAPROF/") == true)
    }

    @Test func aSingleBucketConnectsWithoutListingBucketsAndAnErrorShowsInTheForm() async throws {
        let (hub, registry, server, _, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        _ = try await registry.perform(.dataConnectStart, .select("s3"))
        server.status = 403
        let bad = #"{"name":"","mode":"keys","region":"us-east-1","bucket":"s3://scrapes-raw/books","accessKey":"AKIABAD","secret":"nope","sessionToken":"","profile":""}"#
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(bad)) }
        #expect(hub.saved.isEmpty && hub.connectError?.contains("does not exist in our records") == true)

        server.status = 200
        _ = try await registry.perform(.dataConnectSave, .set(bad))
        let saved = try #require(hub.saved.first)
        #expect(saved.s3?.bucket == "scrapes-raw" && saved.name == "scrapes-raw")
        // Nenhuma chamada de ListBuckets (host sem bucket); a pasta do bucket abre sozinha.
        #expect(!server.requests.contains { $0.url?.host == "s3.us-east-1.amazonaws.com" })
        #expect(hub.connection(saved.id)?.children.map(\.name) == ["scrapes-raw"])
        #expect(hub.active == .folder(connection: saved.id, path: ["scrapes-raw"]))
    }

    @Test func demoConnectionsStayDemo() async throws {
        let hub = DataHubController(datasets: DatasetsController(), demo: true)
        #expect(!hub.isLiveS3(DataHubFixtures.bucket))
        #expect(hub.connection(DataHubFixtures.bucket)?.kind == .s3)
    }
}

/// Leitura da prévia: CSV com aspas, JSON Lines, JSON de objetos, texto e binário.
struct S3PreviewParserTests {
    @Test func csvHandlesQuotesAndDropsTheCutLine() {
        let text = "a,b\n1,\"x,\"\"y\"\"\"\n2,par"
        guard case .grid(let grid) = S3PreviewParser.parse(Data(text.utf8), name: "t.csv", truncated: true) else { Issue.record("grid"); return }
        #expect(grid.columns.map(\.name) == ["a", "b"] && grid.rows == [["1", "x,\"y\""]])
    }

    @Test func jsonLinesBecomeColumnsInOrder() {
        let text = "{\"id\":1,\"name\":\"a\"}\n{\"id\":2,\"name\":\"b\",\"ok\":true}\n"
        guard case .grid(let grid) = S3PreviewParser.parse(Data(text.utf8), name: "t.jsonl", truncated: false) else { Issue.record("grid"); return }
        #expect(grid.columns.map(\.name) == ["id", "name", "ok"] && grid.rows == [["1", "a", ""], ["2", "b", "true"]])
    }

    @Test func jsonArrayOfObjectsIsAGridAndOtherJSONIsText() {
        guard case .grid(let grid) = S3PreviewParser.parse(Data(#"[{"a":1},{"a":2}]"#.utf8), name: "x.json", truncated: false) else { Issue.record("grid"); return }
        #expect(grid.rows == [["1"], ["2"]])
        guard case .text(let text) = S3PreviewParser.parse(Data(#"{"a":{"b":1}}"#.utf8), name: "x.json", truncated: false) else { Issue.record("text"); return }
        #expect(text.contains("\"b\" : 1"))
    }

    @Test func textAndBinary() {
        #expect(S3PreviewParser.parse(Data("hello".utf8), name: "notes.txt", truncated: false) == .text("hello"))
        #expect(S3PreviewParser.parse(Data([0x50, 0x41, 0x52, 0x31]), name: "x.parquet", truncated: false) == .metadataOnly)
        #expect(S3PreviewParser.parse(Data([0x61, 0x00, 0x62]), name: "x.txt", truncated: false) == .metadataOnly)
    }
}
