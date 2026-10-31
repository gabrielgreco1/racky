import Foundation
import Testing

@testable import RackyCore

/// S3: assinatura SigV4 contra os vetores publicados pela AWS, leitura do XML, troca de região e credenciais do AWS CLI.
/// Nada sai da máquina (o transporte é falso).
struct S3ClientTests {
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: SigV4

    /// Conjunto de testes do SigV4 da AWS ("get-vanilla"): chave, data e pedido conhecidos têm esta assinatura.
    @Test func getVanillaMatchesTheAWSTestSuite() {
        let signer = AWSSigV4(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", region: "us-east-1", service: "service", signsContentSHA: false)
        let headers = signer.authorize(method: "GET", host: "example.amazonaws.com", path: "/", date: Self.date("2015-08-30T12:36:00Z"))
        #expect(headers["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        #expect(headers["x-amz-date"] == "20150830T123600Z")
    }

    /// "get-vanilla-query-order-key-case": os parâmetros são ordenados antes de assinar.
    @Test func queryParametersAreSortedBeforeSigning() {
        let signer = AWSSigV4(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", region: "us-east-1", service: "service", signsContentSHA: false)
        let headers = signer.authorize(
            method: "GET", host: "example.amazonaws.com", path: "/", query: [("Param2", "value2"), ("Param1", "value1")], date: Self.date("2015-08-30T12:36:00Z"))
        #expect(headers["Authorization"]?.hasSuffix("Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500") == true)
    }

    /// Exemplos do guia do S3 (bucket `examplebucket`, chaves de exemplo): GET Object com Range e List Objects.
    @Test func s3DocumentationExamples() {
        let signer = AWSSigV4(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let date = Self.date("2013-05-24T00:00:00Z")
        let get = signer.authorize(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt", headers: ["Range": "bytes=0-9"], date: date)
        #expect(get["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        let list = signer.authorize(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/", query: [("max-keys", "2"), ("prefix", "J")], date: date)
        #expect(list["Authorization"]?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    @Test func sessionTokenIsSignedAndSent() {
        let signer = AWSSigV4(accessKeyID: "ASIA", secretAccessKey: "secret", sessionToken: "tok", region: "eu-west-1")
        let headers = signer.authorize(method: "GET", host: "s3.eu-west-1.amazonaws.com", path: "/", date: Self.date("2026-10-23T10:00:00Z"))
        #expect(headers["x-amz-security-token"] == "tok")
        #expect(headers["Authorization"]?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token") == true)
    }

    @Test func amzDateFormatsUTC() {
        #expect(AWSSigV4.amzDate(Date(timeIntervalSince1970: 0)) == "19700101T000000Z")
        #expect(AWSSigV4.amzDate(Self.date("2024-02-29T23:59:58Z")) == "20240229T235958Z")
    }

    // MARK: XML

    static let bucketsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Owner><ID>x</ID></Owner><Buckets>
    <Bucket><Name>scrapes-raw</Name><CreationDate>2026-01-02T03:04:05.000Z</CreationDate></Bucket>
    <Bucket><Name>other</Name><CreationDate>2025-12-31T00:00:00.000Z</CreationDate></Bucket>
    </Buckets></ListAllMyBucketsResult>
    """

    static let listXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>scrapes-raw</Name><Prefix>books/</Prefix><KeyCount>3</KeyCount>
    <MaxKeys>200</MaxKeys><Delimiter>/</Delimiter><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextContinuationToken>tok/1+2=</NextContinuationToken>
    <Contents><Key>books/run%201.csv</Key><LastModified>2026-10-22T10:00:00.000Z</LastModified><ETag>&quot;abc&quot;</ETag><Size>1234</Size></Contents>
    <Contents><Key>books/caf%C3%A9.jsonl</Key><LastModified>2026-10-22T11:00:00.000Z</LastModified><Size>99</Size></Contents>
    <CommonPrefixes><Prefix>books/2026-10-21/</Prefix></CommonPrefixes><CommonPrefixes><Prefix>books/a%20b/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """

    @Test func parsesListAllMyBuckets() throws {
        let root = try #require(XMLTree.parse(Data(Self.bucketsXML.utf8)))
        let buckets = S3Client.parseBuckets(root)
        #expect(buckets.map(\.name) == ["scrapes-raw", "other"])
        #expect(buckets.first?.created == Self.date("2026-01-02T03:04:05Z"))
    }

    @Test func parsesListObjectsV2WithFoldersObjectsAndToken() throws {
        let root = try #require(XMLTree.parse(Data(Self.listXML.utf8)))
        let page = S3Client.parseList(root)
        #expect(page.prefixes == ["books/2026-10-21/", "books/a b/"])
        #expect(page.objects.map(\.key) == ["books/run 1.csv", "books/café.jsonl"])
        #expect(page.objects.first?.size == 1234 && page.objects.first?.etag == "abc")
        #expect(page.nextToken == "tok/1+2=")
    }

    // MARK: Cliente

    static func response(_ url: URL, _ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    static let keys: @Sendable () async throws -> AWSCredentials = { AWSCredentials(accessKeyID: "AKIATEST", secretAccessKey: "topsecret", sessionToken: "sess") }

    @Test func listSendsASignedRequestWithPrefixDelimiterAndToken() async throws {
        let recorder = Recorder()
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            recorder.requests.append(request)
            return (Data(Self.listXML.utf8), Self.response(request.url!, 200))
        }, now: { Self.date("2026-10-23T10:00:00Z") })
        let page = try await client.list(bucket: "scrapes-raw", prefix: "books/", continuationToken: "abc")
        #expect(page.objects.count == 2)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.host == "scrapes-raw.s3.us-east-1.amazonaws.com")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
        #expect(query["list-type"] == "2" && query["prefix"] == "books/" && query["delimiter"] == "/" && query["continuation-token"] == "abc")
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIATEST/20261023/us-east-1/s3/aws4_request"))
        #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == "sess")
        // O segredo nunca viaja.
        #expect(!(request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("topsecret") })
    }

    @Test func dottedBucketsUsePathStyle() async throws {
        let recorder = Recorder()
        let client = S3Client(region: "eu-west-1", credentials: Self.keys, transport: { request in
            recorder.requests.append(request)
            return (Data(Self.listXML.utf8), Self.response(request.url!, 200))
        })
        _ = try await client.list(bucket: "my.bucket", prefix: "")
        #expect(recorder.requests.first?.url?.host == "s3.eu-west-1.amazonaws.com")
        #expect(recorder.requests.first?.url?.absoluteString.hasPrefix("https://s3.eu-west-1.amazonaws.com/my.bucket/?") == true)
    }

    @Test func listBucketsParsesAndChecks() async throws {
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            (Data(Self.bucketsXML.utf8), Self.response(request.url!, 200))
        })
        #expect(try await client.listBuckets().count == 2)
        try await client.check()
    }

    /// 301 com `x-amz-bucket-region`: refaz o pedido na região certa e lembra dela para o próximo.
    @Test func followsTheBucketRegionOnRedirect() async throws {
        let recorder = Recorder()
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            recorder.requests.append(request)
            if request.url?.host?.contains("eu-west-1") == true { return (Data(Self.listXML.utf8), Self.response(request.url!, 200)) }
            let body = "<Error><Code>PermanentRedirect</Code><Message>wrong endpoint</Message><Endpoint>b.s3.eu-west-1.amazonaws.com</Endpoint></Error>"
            return (Data(body.utf8), Self.response(request.url!, 301, ["x-amz-bucket-region": "eu-west-1"]))
        })
        _ = try await client.list(bucket: "b", prefix: "")
        #expect(recorder.requests.map { $0.url?.host } == ["b.s3.us-east-1.amazonaws.com", "b.s3.eu-west-1.amazonaws.com"])
        // A segunda assinatura usa a região nova.
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Authorization")?.contains("/eu-west-1/s3/aws4_request") == true)
        _ = try await client.list(bucket: "b", prefix: "x/")
        #expect(recorder.requests.count == 3 && recorder.requests.last?.url?.host == "b.s3.eu-west-1.amazonaws.com")
    }

    @Test func regionComesFromTheBodyWhenThereIsNoHeader() async throws {
        let recorder = Recorder()
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            recorder.requests.append(request)
            if request.url?.host?.contains("sa-east-1") == true { return (Data(Self.listXML.utf8), Self.response(request.url!, 200)) }
            let body = "<Error><Code>AuthorizationHeaderMalformed</Code><Message>the region us-east-1 is wrong; expecting sa-east-1</Message><Region>sa-east-1</Region></Error>"
            return (Data(body.utf8), Self.response(request.url!, 400))
        })
        _ = try await client.list(bucket: "b", prefix: "")
        #expect(recorder.requests.count == 2)
    }

    @Test func aRedirectLoopGivesUp() async throws {
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            let region = request.url?.host?.contains("eu-west-1") == true ? "us-east-1" : "eu-west-1"
            return (Data(), Self.response(request.url!, 301, ["x-amz-bucket-region": region]))
        })
        await #expect(throws: S3Client.Failure.self) { _ = try await client.list(bucket: "b", prefix: "") }
    }

    @Test func mapsErrorsToTypedFailures() async throws {
        func failing(_ status: Int, _ code: String) -> S3Client {
            S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
                (Data("<Error><Code>\(code)</Code><Message>m</Message></Error>".utf8), Self.response(request.url!, status))
            })
        }
        await #expect(throws: S3Client.Failure.auth("m")) { _ = try await failing(403, "InvalidAccessKeyId").listBuckets() }
        await #expect(throws: S3Client.Failure.auth("m")) { _ = try await failing(403, "ExpiredToken").listBuckets() }
        await #expect(throws: S3Client.Failure.accessDenied("m")) { _ = try await failing(403, "AccessDenied").listBuckets() }
        await #expect(throws: S3Client.Failure.notFound("b")) { _ = try await failing(404, "NoSuchBucket").list(bucket: "b", prefix: "") }
        await #expect(throws: S3Client.Failure.notFound("a.csv")) { _ = try await failing(404, "NoSuchKey").get(bucket: "b", key: "a.csv") }
        let down = S3Client(region: "us-east-1", credentials: Self.keys, transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: (any Error).self) { _ = try await down.listBuckets() }
        do { _ = try await down.listBuckets() } catch let failure as S3Client.Failure {
            if case .unreachable = failure {} else { Issue.record("expected unreachable, got \(failure)") }
        }
    }

    @Test func getAsksForARangeAndReadsTheTotalSize() async throws {
        let recorder = Recorder()
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            recorder.requests.append(request)
            return (Data("a,b\n1,2\n".utf8), Self.response(request.url!, 206, ["Content-Range": "bytes 0-262143/1048576", "Content-Type": "text/csv"]))
        })
        let chunk = try await client.preview(bucket: "b", key: "dir/my file.csv")
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=0-262143")
        #expect(recorder.requests.first?.url?.path == "/dir/my file.csv")
        #expect(recorder.requests.first?.url?.absoluteString.hasSuffix("/dir/my%20file.csv") == true)
        #expect(chunk.total == 1_048_576 && chunk.contentType == "text/csv" && String(decoding: chunk.data, as: UTF8.self) == "a,b\n1,2\n")
    }

    @Test func headReadsSizeAndDate() async throws {
        let client = S3Client(region: "us-east-1", credentials: Self.keys, transport: { request in
            #expect(request.httpMethod == "HEAD")
            return (Data(), Self.response(request.url!, 200, ["Content-Length": "42", "Content-Type": "application/json", "ETag": "\"e\"", "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"]))
        })
        let info = try await client.head(bucket: "b", key: "k.json")
        #expect(info.size == 42 && info.contentType == "application/json" && info.etag == "e" && info.lastModified == Self.date("2026-10-21T07:28:00Z"))
    }

    // MARK: AWS CLI

    @Test func parsesExportCredentialsJSON() throws {
        let json = #"{"Version":1,"AccessKeyId":"ASIAXYZ","SecretAccessKey":"sec","SessionToken":"tok","Expiration":"2026-10-23T15:00:00+00:00"}"#
        let creds = try AWSProfileCredentials.parse(Data(json.utf8))
        #expect(creds.accessKeyID == "ASIAXYZ" && creds.secretAccessKey == "sec" && creds.sessionToken == "tok")
        #expect(creds.expiration == Self.date("2026-10-23T15:00:00Z"))
        #expect(throws: AWSCredentialsFailure.unexpectedOutput) { _ = try AWSProfileCredentials.parse(Data("{}".utf8)) }
        // Chaves fixas do perfil (sem token nem validade) também servem.
        let plain = try AWSProfileCredentials.parse(Data(#"{"Version":1,"AccessKeyId":"AKIA","SecretAccessKey":"s"}"#.utf8))
        #expect(plain.sessionToken == nil && plain.expiration == nil)
    }

    final class Counter: @unchecked Sendable { var calls: [[String]] = [] }

    @Test func profileCredentialsAreCachedAndRefreshedWhenTheyExpire() async throws {
        let counter = Counter()
        let clock = Counter()
        nonisolated(unsafe) var now = Self.date("2026-10-23T10:00:00Z")
        _ = clock
        let provider = AWSProfileCredentials(profile: "rti", runner: { arguments in
            counter.calls.append(arguments)
            let json = #"{"Version":1,"AccessKeyId":"ASIA\#(counter.calls.count)","SecretAccessKey":"s","SessionToken":"t","Expiration":"2026-10-23T11:00:00Z"}"#
            return AWSCLIResult(status: 0, stdout: Data(json.utf8), stderr: "")
        }, now: { now })
        #expect(try await provider.credentials().accessKeyID == "ASIA1")
        #expect(try await provider.credentials().accessKeyID == "ASIA1")
        #expect(counter.calls.count == 1)
        #expect(counter.calls.first == ["configure", "export-credentials", "--profile", "rti", "--format", "process"])
        // Falta menos de um minuto para vencer: pede de novo.
        now = Self.date("2026-10-23T10:59:30Z")
        #expect(try await provider.credentials().accessKeyID == "ASIA2")
    }

    @Test func profileFailuresTellTheUserWhatToDo() async throws {
        let expired = AWSProfileCredentials(profile: "rti", runner: { _ in
            AWSCLIResult(status: 255, stdout: Data(), stderr: "Error loading SSO Token: The SSO session associated with this profile has expired or is otherwise invalid.")
        })
        do { _ = try await expired.credentials(); Issue.record("should fail") } catch let failure as AWSCredentialsFailure {
            #expect(failure == .sessionExpired(profile: "rti"))
            #expect(failure.description.contains("aws sso login --profile rti"))
        }
        let missing = AWSProfileCredentials(profile: "rti", runner: { _ in throw AWSCredentialsFailure.cliMissing })
        await #expect(throws: AWSCredentialsFailure.cliMissing) { _ = try await missing.credentials() }
        let bad = AWSProfileCredentials(profile: "--evil", runner: { _ in AWSCLIResult(status: 0, stdout: Data(), stderr: "") })
        await #expect(throws: AWSCredentialsFailure.invalidProfile) { _ = try await bad.credentials() }
    }

    @Test func aProfileFailureSurfacesAsACredentialsFailureFromTheClient() async throws {
        let provider = AWSProfileCredentials(profile: "rti", runner: { _ in throw AWSCredentialsFailure.cliMissing })
        let client = S3Client(region: "us-east-1", credentials: { try await provider.credentials() }, transport: { _ in Issue.record("no request without credentials"); throw URLError(.badURL) })
        do { _ = try await client.listBuckets(); Issue.record("should fail") } catch let failure as S3Client.Failure {
            #expect(failure == .credentials(AWSCredentialsFailure.cliMissing.description))
        }
    }
}
