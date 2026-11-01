import Foundation

/// Leitura de um bucket do Amazon S3 pela API REST com assinatura SigV4. Só lê (ListBuckets, ListObjectsV2, HEAD, GET com Range):
/// nenhuma chamada muda o bucket. As credenciais vêm de uma closure (chaves fixas ou o perfil do AWS CLI, que renova sozinho).
public struct S3Client: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// Chave, assinatura ou token recusados (ou vencidos).
        case auth(String)
        case accessDenied(String)
        case notFound(String)
        case region(String)
        case http(Int, String)
        case unreachable(String)
        case decoding
        /// Perfil do AWS CLI sem credenciais (mensagem já pronta).
        case credentials(String)

        public var description: String {
            switch self {
            case .auth(let why): "AWS refused the credentials: \(why)"
            case .accessDenied(let why): "Access denied: \(why)"
            case .notFound(let what): "Not found: \(what)"
            case .region(let why): "Wrong region: \(why)"
            case .http(let code, let why): why.isEmpty ? "S3 answered HTTP \(code)." : "S3 answered HTTP \(code): \(why)"
            case .unreachable(let why): "Could not reach S3: \(why)"
            case .decoding: "S3 answered something that is not the S3 API."
            case .credentials(let why): why
            }
        }
    }

    public struct Bucket: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var created: Date?
        public init(name: String, created: Date? = nil) { self.name = name; self.created = created }
    }

    public struct Object: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var size: Int64
        public var lastModified: Date?
        public var etag: String?
        public init(key: String, size: Int64, lastModified: Date? = nil, etag: String? = nil) {
            self.key = key; self.size = size; self.lastModified = lastModified; self.etag = etag
        }
    }

    /// Uma página de `ListObjectsV2`: "pastas" (CommonPrefixes, com o prefixo inteiro) e objetos; `nextToken` se há mais.
    public struct ListPage: Sendable, Equatable {
        public var prefixes: [String]
        public var objects: [Object]
        public var nextToken: String?
        public init(prefixes: [String], objects: [Object], nextToken: String?) { self.prefixes = prefixes; self.objects = objects; self.nextToken = nextToken }
    }

    public struct ObjectInfo: Sendable, Equatable {
        public var size: Int64
        public var lastModified: Date?
        public var contentType: String?
        public var etag: String?
    }

    /// Começo de um objeto (para a prévia). `total` é o tamanho inteiro quando o servidor diz.
    public struct Chunk: Sendable, Equatable {
        public var data: Data
        public var total: Int64?
        public var contentType: String?
    }

    /// Região de cada bucket já descoberta (compartilhada entre cópias do client).
    final class RegionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var regions: [String: String] = [:]
        subscript(bucket bucket: String) -> String? {
            get { lock.lock(); defer { lock.unlock() }; return regions[bucket] }
            set { lock.lock(); regions[bucket] = newValue; lock.unlock() }
        }
    }

    /// Região padrão da conexão.
    public let region: String
    let credentials: @Sendable () async throws -> AWSCredentials
    let transport: Transport
    let now: @Sendable () -> Date
    let regions = RegionCache()

    public init(
        region: String, credentials: @escaping @Sendable () async throws -> AWSCredentials, transport: Transport? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.region = region.isEmpty ? "us-east-1" : region
        self.credentials = credentials
        self.now = now
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable("no HTTP response") }
            return (data, http)
        }
    }

    // MARK: Chamadas

    /// As credenciais valem e o S3 responde: com um bucket, lê 1 item dele; sem, lista os buckets.
    public func check(bucket: String? = nil) async throws {
        if let bucket, !bucket.isEmpty {
            _ = try await list(bucket: bucket, prefix: "", maxKeys: 1)
        } else {
            _ = try await listBuckets()
        }
    }

    public func listBuckets() async throws -> [Bucket] {
        let (data, _) = try await send(method: "GET", bucket: nil, key: "", query: [])
        guard let root = XMLTree.parse(data), root.name == "ListAllMyBucketsResult" else { throw Failure.decoding }
        return Self.parseBuckets(root)
    }

    public func list(bucket: String, prefix: String, delimiter: String? = "/", continuationToken: String? = nil, maxKeys: Int = 200) async throws -> ListPage {
        var query: [(String, String)] = [("list-type", "2"), ("encoding-type", "url"), ("max-keys", "\(maxKeys)")]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        let (data, _) = try await send(method: "GET", bucket: bucket, key: "", query: query)
        guard let root = XMLTree.parse(data), root.name == "ListBucketResult" else { throw Failure.decoding }
        return Self.parseList(root)
    }

    public func head(bucket: String, key: String) async throws -> ObjectInfo {
        let (_, response) = try await send(method: "HEAD", bucket: bucket, key: key, query: [])
        return ObjectInfo(
            size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate),
            contentType: response.value(forHTTPHeaderField: "Content-Type"), etag: response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    /// `GET` com `Range: bytes=<início>-<fim>` (sem `range`: o objeto inteiro). A prévia pede os primeiros 256 KB.
    public func get(bucket: String, key: String, range: ClosedRange<Int64>? = nil) async throws -> Chunk {
        var headers: [String: String] = [:]
        if let range { headers["range"] = "bytes=\(range.lowerBound)-\(range.upperBound)" }
        let (data, response) = try await send(method: "GET", bucket: bucket, key: key, query: [], headers: headers)
        var total = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "")
        // `Content-Range: bytes 0-262143/1048576`: o tamanho inteiro vem depois da barra.
        if let content = response.value(forHTTPHeaderField: "Content-Range"), let slash = content.lastIndex(of: "/"), let n = Int64(content[content.index(after: slash)...]) { total = n }
        return Chunk(data: data, total: total, contentType: response.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Os primeiros `limit` bytes de um objeto.
    public func preview(bucket: String, key: String, limit: Int64 = 262_144) async throws -> Chunk {
        try await get(bucket: bucket, key: key, range: 0 ... (limit - 1))
    }

    // MARK: Pedido

    /// Endereço do pedido. Bucket de nome DNS simples: `bucket.s3.<região>.amazonaws.com`; com ponto no nome (o certificado não cobre)
    /// ou sem bucket: `s3.<região>.amazonaws.com/<bucket>/…`.
    static func endpoint(bucket: String?, key: String, region: String) -> (host: String, path: String) {
        let domain = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        let base = "s3.\(region).\(domain)"
        let encodedKey = AWSSigV4.encode(key, keepSlash: true)
        guard let bucket else { return (base, "/") }
        if bucket.contains(".") || bucket.contains(where: \.isUppercase) { return (base, "/\(bucket)/\(encodedKey)") }
        return ("\(bucket).\(base)", "/\(encodedKey)")
    }

    func send(method: String, bucket: String?, key: String, query: [(String, String)], headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var region = bucket.flatMap { regions[bucket: $0] } ?? self.region
        var attempts = 0
        while true {
            let (data, response) = try await sendOnce(method: method, bucket: bucket, key: key, query: query, headers: headers, region: region)
            if (200 ..< 300).contains(response.statusCode) {
                if let bucket, let actual = response.value(forHTTPHeaderField: "x-amz-bucket-region") { regions[bucket: bucket] = actual }
                return (data, response)
            }
            // Região errada: o S3 diz a certa no cabeçalho `x-amz-bucket-region` (301, 400 ou 403) ou no corpo (Region / Endpoint).
            if let bucket, let correct = Self.redirectRegion(response, data), correct != region {
                guard attempts == 0 else { throw Failure.region("the bucket is in \(correct)") }
                attempts += 1
                regions[bucket: bucket] = correct
                region = correct
                continue
            }
            throw Self.failure(response, data, bucket: bucket, key: key)
        }
    }

    private func sendOnce(method: String, bucket: String?, key: String, query: [(String, String)], headers: [String: String], region: String) async throws -> (Data, HTTPURLResponse) {
        let creds: AWSCredentials
        do {
            creds = try await credentials()
        } catch let failure as Failure {
            throw failure
        } catch let failure as AWSCredentialsFailure {
            throw Failure.credentials(failure.description)
        } catch {
            throw Failure.credentials(error.localizedDescription)
        }
        let (host, path) = Self.endpoint(bucket: bucket, key: key, region: region)
        let signer = AWSSigV4(accessKeyID: creds.accessKeyID, secretAccessKey: creds.secretAccessKey, sessionToken: creds.sessionToken, region: region)
        let signed = signer.authorize(method: method, host: host, path: path, query: query, headers: headers, date: now())
        var text = "https://\(host)\(path)"
        if !query.isEmpty { text += "?" + query.map { "\(AWSSigV4.encode($0.0))=\(AWSSigV4.encode($0.1))" }.joined(separator: "&") }
        guard let url = URL(string: text) else { throw Failure.unreachable("bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        do {
            return try await transport(request)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    // MARK: Erros e região

    static func redirectRegion(_ response: HTTPURLResponse, _ body: Data) -> String? {
        guard response.statusCode >= 300 else { return nil }
        if let header = response.value(forHTTPHeaderField: "x-amz-bucket-region"), !header.isEmpty { return header }
        guard let root = XMLTree.parse(body), root.name == "Error" else { return nil }
        if let region = root.text(of: "Region"), !region.isEmpty { return region }
        // `<Endpoint>bucket.s3.eu-west-1.amazonaws.com</Endpoint>` (PermanentRedirect).
        if let endpoint = root.text(of: "Endpoint"), let match = endpoint.range(of: #"s3[.-]([a-z0-9-]+)\.amazonaws\.com"#, options: .regularExpression) {
            let part = String(endpoint[match]).dropFirst(3).replacingOccurrences(of: ".amazonaws.com", with: "")
            if part != "external-1", !part.isEmpty { return part }
        }
        return nil
    }

    static func failure(_ response: HTTPURLResponse, _ body: Data, bucket: String?, key: String) -> Failure {
        let root = XMLTree.parse(body)
        let code = root?.text(of: "Code") ?? ""
        let message = root?.text(of: "Message") ?? ""
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken", "TokenRefreshRequired", "AuthorizationHeaderMalformed", "InvalidSecurity", "RequestTimeTooSkewed":
            return .auth(message.isEmpty ? code : message)
        case "AccessDenied", "AllAccessDisabled":
            return .accessDenied(message.isEmpty ? code : message)
        case "NoSuchBucket": return .notFound(bucket ?? "bucket")
        case "NoSuchKey": return .notFound(key)
        case "PermanentRedirect": return .region(message)
        default: break
        }
        switch response.statusCode {
        case 401: return .auth(message)
        case 403: return .accessDenied(message)
        case 404: return .notFound(key.isEmpty ? (bucket ?? "bucket") : key)
        case 301: return .region(message)
        default: return .http(response.statusCode, message.isEmpty ? code : message)
        }
    }

    // MARK: Decodificação

    static func parseBuckets(_ root: XMLElementNode) -> [Bucket] {
        (root.child("Buckets")?.children(named: "Bucket") ?? []).compactMap { node in
            guard let name = node.text(of: "Name") else { return nil }
            return Bucket(name: name, created: node.text(of: "CreationDate").flatMap(Self.isoDate))
        }
    }

    static func parseList(_ root: XMLElementNode) -> ListPage {
        // `encoding-type=url`: chaves e prefixos chegam com `%XX` (e `+` para espaço).
        let urlEncoded = root.text(of: "EncodingType") == "url"
        func decode(_ text: String?) -> String? {
            guard let text else { return nil }
            return urlEncoded ? text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text : text
        }
        let prefixes = root.children(named: "CommonPrefixes").compactMap { decode($0.text(of: "Prefix")) }
        let objects = root.children(named: "Contents").compactMap { node -> Object? in
            guard let key = decode(node.text(of: "Key")) else { return nil }
            return Object(key: key, size: node.text(of: "Size").flatMap { Int64($0) } ?? 0, lastModified: node.text(of: "LastModified").flatMap(Self.isoDate),
                          etag: node.text(of: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        let truncated = root.text(of: "IsTruncated") == "true"
        return ListPage(prefixes: prefixes, objects: objects, nextToken: truncated ? root.text(of: "NextContinuationToken") : nil)
    }

    static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// `Last-Modified: Wed, 21 Oct 2026 07:28:00 GMT`.
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

// MARK: XML

/// Um elemento de XML (árvore pequena: as respostas do S3 cabem na memória). Evita o nome `XMLNode` (é do Foundation).
final class XMLElementNode {
    let name: String
    var text = ""
    var elements: [XMLElementNode] = []
    init(name: String) { self.name = name }

    func child(_ name: String) -> XMLElementNode? { elements.first { $0.name == name } }
    func children(named name: String) -> [XMLElementNode] { elements.filter { $0.name == name } }
    func text(of name: String) -> String? { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum XMLTree {
    /// Raiz do documento, ou `nil` se não for XML.
    static func parse(_ data: Data) -> XMLElementNode? {
        guard !data.isEmpty else { return nil }
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElementNode?
        var stack: [XMLElementNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLElementNode(name: elementName)
            if let parent = stack.last { parent.elements.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    }
}
