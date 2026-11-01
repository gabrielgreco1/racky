import Foundation
import Testing

@testable import RackyCore

/// Cliente do Prefect contra um servidor falso: URL, autenticação, filtro e leitura dos runs (nada sai da máquina).
struct PrefectClientTests {
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    static let runJSON = """
    [{"id":"r1","name":"brave-otter","state_type":"RUNNING","state_name":"Running","deployment_id":"d1","flow_id":"f1",
      "work_pool_name":"data-ecs-pool","tags":["listings","us"],"start_time":"2026-10-22T20:00:00.123456+00:00",
      "expected_start_time":"2026-10-22T20:00:00+00:00","end_time":null,"total_run_time":42.5}]
    """

    @Test func apiURLAcceptsWhatPeopleType() {
        #expect(PrefectClient.apiURL(from: "prefect.example.com")?.absoluteString == "https://prefect.example.com/api")
        #expect(PrefectClient.apiURL(from: "https://prefect.example.com/api/")?.absoluteString == "https://prefect.example.com/api")
        #expect(PrefectClient.apiURL(from: "http://localhost:4200")?.absoluteString == "http://localhost:4200/api")
        #expect(PrefectClient.apiURL(from: "") == nil)
        #expect(PrefectClient.apiURL(from: "ftp://x") == nil)
    }

    @Test func flowRunsSendsTheFilterAndBasicAuthAndDecodes() async throws {
        let recorder = Recorder()
        let client = PrefectClient(baseURL: URL(string: "https://prefect.example.com/api")!, auth: .basic("admin:s3cret")) { request in
            recorder.requests.append(request)
            return (Data(Self.runJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let runs = try await client.flowRuns(states: [.running, .pending], limit: 50)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://prefect.example.com/api/flow_runs/filter" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(Data("admin:s3cret".utf8).base64EncodedString())")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let states = ((body["flow_runs"] as? [String: Any])?["state"] as? [String: Any]).flatMap { ($0["type"] as? [String: Any])?["any_"] as? [String] }
        #expect(states == ["RUNNING", "PENDING"] && body["limit"] as? Int == 50)
        let run = try #require(runs.first)
        #expect(run.id == "r1" && run.name == "brave-otter" && run.state == .running && run.workPool == "data-ecs-pool")
        #expect(run.tags == ["listings", "us"] && run.start != nil && run.end == nil && run.totalRunTime == 42.5)
    }

    @Test func apiKeyGoesAsBearerAndErrorsAreNamed() async throws {
        let recorder = Recorder()
        let unauthorized = PrefectClient(baseURL: URL(string: "https://api.prefect.cloud/api/accounts/a/workspaces/w")!, auth: .apiKey("pnu_x")) { request in
            recorder.requests.append(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: PrefectClient.Failure.unauthorized) { try await unauthorized.check() }
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer pnu_x")
        let notPrefect = PrefectClient(baseURL: URL(string: "https://example.com/api")!, auth: .none) { request in
            (Data("<html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: PrefectClient.Failure.decoding) { try await notPrefect.check() }
    }
}
