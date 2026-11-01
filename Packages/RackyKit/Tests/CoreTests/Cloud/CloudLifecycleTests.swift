import Foundation
import RackyPlatform
import Testing

@testable import RackyCore

@Suite("BK-12 - tags, reaper, teto de gasto e gerente de hosts (provedor falso)")
struct CloudLifecycleTests {
    // MARK: Tags

    @Test func tagsRoundTripAndFilterIsOwnerScoped() throws {
        let tags = RackyTags(owner: "install-1", host: "h1", run: "run-9", created: CloudFixture.noon, expires: CloudFixture.noon.addingTimeInterval(3600), provider: .aws)
        let dictionary = tags.dictionary
        #expect(dictionary["racky:managed"] == "true" && dictionary["racky:owner"] == "install-1" && dictionary["racky:provider"] == "aws")
        #expect(RackyTags(dictionary) == tags)
        #expect(RackyTags.filter(owner: "install-1") == ["racky:managed": "true", "racky:owner": "install-1"])
        #expect(RackyTags(["Name": "other"]) == nil && RackyTags(["racky:managed": "false", "racky:owner": "x"]) == nil)
    }

    // MARK: Reaper

    private func host(_ id: String, tags: [String: String], state: CloudHostState = .running) -> CloudHost {
        CloudHost(id: id, provider: .fake, region: "us-east-1", shape: CloudFixture.small, state: state, launchedAt: CloudFixture.noon, tags: tags, hourlyUSD: 0.08)
    }

    private func ownTags(_ id: String, owner: String = "install-1", created: Date, expires: Date) -> [String: String] {
        RackyTags(owner: owner, host: id, created: created, expires: expires, provider: .fake).dictionary
    }

    @Test func reaperTerminatesExpiredAndOrphansButNeverForeignOrUnmanaged() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let now = CloudFixture.noon
        let old = now.addingTimeInterval(-3600), recent = now.addingTimeInterval(-60), future = now.addingTimeInterval(7200)
        await provider.inject(host("expired", tags: ownTags("expired", created: old, expires: now.addingTimeInterval(-1))))
        await provider.inject(host("orphan", tags: ownTags("orphan", created: old, expires: future)))
        await provider.inject(host("known", tags: ownTags("known", created: old, expires: future)))
        await provider.inject(host("fresh", tags: ownTags("fresh", created: recent, expires: future)))  // dentro da carência: pode estar sendo registrado
        await provider.inject(host("foreign", tags: ownTags("foreign", owner: "someone-else", created: old, expires: now.addingTimeInterval(-1))))
        await provider.inject(host("untagged", tags: ["Name": "web-server"]))
        await provider.inject(host("gone", tags: ownTags("gone", created: old, expires: now.addingTimeInterval(-1)), state: .terminated))

        let report = try await HostReaper(provider: provider, owner: "install-1").sweep(knownHostIDs: ["known"], regions: ["us-east-1"], now: now)
        #expect(Set(report.terminated) == ["expired", "orphan"])
        #expect(report.reasons == ["expired": "expired", "orphan": "orphan"])
        #expect(Set(report.kept) == ["known", "fresh"])
        #expect(await provider.liveHostIDs == ["foreign", "fresh", "known", "untagged"], "de outro dono ou sem tag: intocados")
        let terminateCalls = await provider.calls.filter { $0.hasPrefix("terminate:") }
        #expect(Set(terminateCalls) == ["terminate:expired", "terminate:orphan"])
    }

    @Test func reaperReportsFailuresAndKeepsGoing() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let now = CloudFixture.noon
        for id in ["a", "b"] { await provider.inject(host(id, tags: ownTags(id, created: now.addingTimeInterval(-9999), expires: now.addingTimeInterval(-1)))) }
        await provider.setFailTerminate(["a"])
        let report = try await HostReaper(provider: provider, owner: "install-1").sweep(knownHostIDs: [], regions: ["us-east-1"], now: now)
        #expect(report.terminated == ["b"] && report.failures.keys.sorted() == ["a"])
    }

    @Test func reaperOnlyListsWithTheOwnerTagFilterAndOnlyInTheGivenRegions() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        var other = host("sp", tags: ownTags("sp", created: CloudFixture.noon.addingTimeInterval(-9999), expires: CloudFixture.noon.addingTimeInterval(-1)))
        other.region = "sa-east-1"
        await provider.inject(other)
        let report = try await HostReaper(provider: provider, owner: "install-1").sweep(knownHostIDs: [], regions: ["us-east-1"], now: CloudFixture.noon)
        #expect(report.terminated.isEmpty, "região não habilitada não é varrida")
    }

    // MARK: Gasto

    private func record(_ id: String, start: Double, end: Double? = nil, expires: Double, hourly: Double = 1) -> SpendRecord {
        SpendRecord(hostID: id, startedAt: CloudFixture.noon.addingTimeInterval(start), endedAt: end.map { CloudFixture.noon.addingTimeInterval($0) },
                    expiresAt: CloudFixture.noon.addingTimeInterval(expires), hourlyUSD: hourly)
    }

    @Test func ledgerAccruesAndProjectsWithinWindowsAcrossMidnight() throws {
        let day = try #require(CloudFixture.utc.dateInterval(of: .day, for: CloudFixture.noon))  // 20/10 00:00 a 21/10 00:00
        var ledger = SpendLedger()
        ledger.open(record("a", start: -2 * 3600, expires: 30 * 3600, hourly: 2))  // começou 10:00, vive até 18:00 do dia 21
        // até 12:00: 2 h x US$ 2
        #expect(abs(ledger.accrued(in: day, now: CloudFixture.noon) - 4) < 1e-9)
        // projetado no dia: 10:00 até 24:00 = 14 h x 2
        #expect(abs(ledger.projected(in: day, now: CloudFixture.noon) - 28) < 1e-9)
        ledger.close(hostID: "a", at: CloudFixture.noon.addingTimeInterval(3600))  // encerrado às 13:00
        #expect(abs(ledger.projected(in: day, now: CloudFixture.noon.addingTimeInterval(3600)) - 6) < 1e-9, "encerrado: projeção = acumulado")
    }

    @Test func guardDeniesWhenTheProjectionPassesDailyOrMonthlyCapAndNamesTheWindow() {
        let guardRail = SpendGuard(caps: SpendCaps(dailyUSD: 5, monthlyUSD: 100), calendar: CloudFixture.utc)
        var ledger = SpendLedger()
        // US$ 0,6/h por 8 h até 20:00 = 4,8 no dia: cabe
        #expect(guardRail.evaluate(newHost: record("h1", start: 0, expires: 8 * 3600, hourly: 0.6), ledger: ledger, now: CloudFixture.noon) == nil)
        ledger.open(record("h1", start: 0, expires: 8 * 3600, hourly: 0.6))
        // o segundo estoura os US$ 5 do dia mesmo cabendo no mês
        let denial = guardRail.evaluate(newHost: record("h2", start: 0, expires: 8 * 3600, hourly: 0.1), ledger: ledger, now: CloudFixture.noon)
        #expect(denial?.window == .daily && denial?.capUSD == 5 && (denial?.projectedUSD ?? 0) > 5)
        // sem teto = sem limite
        #expect(SpendGuard(caps: SpendCaps(), calendar: CloudFixture.utc).evaluate(newHost: record("x", start: 0, expires: 99 * 3600, hourly: 100), ledger: ledger, now: CloudFixture.noon) == nil)
        // mensal
        let monthly = SpendGuard(caps: SpendCaps(dailyUSD: nil, monthlyUSD: 3), calendar: CloudFixture.utc)
        #expect(monthly.evaluate(newHost: record("m", start: 0, expires: 8 * 3600, hourly: 0.6), ledger: SpendLedger(), now: CloudFixture.noon)?.window == .monthly)
    }

    @Test func breachUsesAccruedSpendNotProjection() {
        let guardRail = SpendGuard(caps: SpendCaps(dailyUSD: 5), calendar: CloudFixture.utc)
        var ledger = SpendLedger()
        ledger.open(record("a", start: -3600, expires: 8 * 3600, hourly: 2))  // acumulado 2
        #expect(guardRail.breach(ledger: ledger, now: CloudFixture.noon) == nil)
        #expect(guardRail.breach(ledger: ledger, now: CloudFixture.noon.addingTimeInterval(2 * 3600))?.window == .daily)  // 3 h x 2 = 6
    }

    // MARK: Gerente

    @Test func acquireTagsTheHostSendsCloudInitAndRecordsSpend() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader)
        let manager = CloudFixture.manager(provider: provider, clock: clock)
        let host = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.large, runID: "run-1", access: CloudFixture.access)
        let tags = try #require(RackyTags(host.tags))
        #expect(tags.owner == "install-1" && tags.run == "run-1" && tags.expires == CloudFixture.noon.addingTimeInterval(8 * 3600))
        #expect(host.hourlyUSD == 0.58 + 0.005 + 0.0033)
        #expect(await manager.activeHosts.map(\.id) == [host.id])
        #expect(await manager.ledger.records.count == 1)
    }

    @Test func nothingIsCreatedWhenTheAcceptableUseIsNotConfirmed() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader)
        let manager = CloudFixture.manager(provider: provider, clock: clock, accepted: false)
        await #expect(throws: CloudError.acceptableUseNotAccepted(provider: .fake, version: "2026-10-01")) {
            _ = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        }
        #expect(await provider.provisionCalls == 0)
    }

    @Test func spendCapBlocksCreationBeforeAnyCloudCall() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader)
        // c7g.4xlarge por 8 h ≈ US$ 4,7: teto diário de US$ 2 impede.
        let manager = CloudFixture.manager(provider: provider, clock: clock, caps: SpendCaps(dailyUSD: 2))
        do {
            _ = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.large, access: CloudFixture.access)
            Issue.record("deveria negar")
        } catch let CloudError.spendCapExceeded(denial) {
            #expect(denial.window == .daily && denial.capUSD == 2 && denial.projectedUSD > 2)
        }
        let calls = await provider.provisionCalls, live = await provider.liveHostIDs
        #expect(calls == 0 && live.isEmpty)
        // O pequeno cabe no mesmo teto (8 h x US$ 0,0808 ≈ 0,65), e um segundo grande já não.
        _ = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        #expect(await provider.provisionCalls == 1)
    }

    @Test func quotaIsCheckedBeforeProvisioning() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader, quotaVCPUs: 16)
        let manager = CloudFixture.manager(provider: provider, clock: clock)
        _ = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.large, access: CloudFixture.access)
        await #expect(throws: CloudError.quotaExceeded(region: "us-east-1", needed: 2, available: 0)) {
            _ = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        }
    }

    @Test func runningHostsAreTerminatedWhenAccruedSpendPassesTheCap() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader)
        let manager = CloudFixture.manager(provider: provider, clock: clock, caps: SpendCaps(dailyUSD: 5))
        let host = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)  // ≈ US$ 0,0808/h
        clock.advance(3 * 3600)  // 15:00: 3 h x 0,0808 = 0,24
        let before = await manager.enforceCaps()
        #expect(before == nil, "abaixo do teto de US$ 5")
        await manager.updateCaps(SpendCaps(dailyUSD: 0.2))  // o usuário baixou o teto no meio do run
        let result = try #require(await manager.enforceCaps())
        #expect(result.denial.window == .daily && result.terminated == [host.id])
        let live = await provider.liveHostIDs, active = await manager.activeHosts
        #expect(live.isEmpty && active.isEmpty)
        #expect(await manager.ledger.records.first?.endedAt != nil)
    }

    @Test func releaseTerminatesAndStopsTheMeter() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader)
        let manager = CloudFixture.manager(provider: provider, clock: clock)
        let host = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        clock.advance(1800)
        try await manager.releaseHost(id: host.id)
        #expect(await provider.liveHostIDs.isEmpty)
        let day = try #require(CloudFixture.utc.dateInterval(of: .day, for: CloudFixture.noon))
        clock.advance(10 * 3600)
        let spent = await manager.ledger.accrued(in: day, now: clock.now)
        #expect(abs(spent - 0.5 * host.hourlyUSD) < 1e-6, "parou de contar na liberação")
    }

    @Test func managerReapOrphansFromAPreviousAppRun() async throws {
        let clock = CloudTestClock(CloudFixture.noon)
        let provider = FakeCloudProvider(clock: clock.reader)
        let first = CloudFixture.manager(provider: provider, clock: clock)
        let leaked = try await first.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        // O app "reabre": gerente novo, sem memória do host.
        let reopened = CloudFixture.manager(provider: provider, clock: clock)
        clock.advance(3600)
        let report = try await reopened.reap(regions: ["us-east-1"])
        #expect(report.terminated == [leaked.id] && report.reasons[leaked.id] == "orphan")
        #expect(await provider.liveHostIDs.isEmpty)
    }

    // MARK: AWS (pelo CLI, sem rede)

    /// CLI falso: grava cada argv e responde pelo comando (`ec2 run-instances` etc.).
    final class FakeAWS: @unchecked Sendable {
        // SAFETY: só os testes usam; o lock protege as listas.
        let lock = NSLock()
        var calls: [[String]] = []
        var userData: String?
        func runner() -> AWSCLI.Runner {
            { _, args, _ in
                self.lock.withLock {
                    self.calls.append(args)
                    if let i = args.firstIndex(of: "--user-data"), args[i + 1].hasPrefix("file://") {
                        self.userData = try? String(contentsOfFile: String(args[i + 1].dropFirst(7)), encoding: .utf8)
                    }
                }
                let key = args.prefix(2).joined(separator: " ")
                let json: String = switch key {
                case "ssm get-parameter": #"{"Parameter":{"Value":"ami-1"}}"#
                case "ec2 describe-vpcs": #"{"Vpcs":[{"VpcId":"vpc-1"}]}"#
                case "ec2 describe-security-groups": #"{"SecurityGroups":[{"GroupId":"sg-1","IpPermissions":[{"IpProtocol":"tcp","FromPort":22,"IpRanges":[{"CidrIp":"9.9.9.9/32"}]}]}]}"#
                case "ec2 run-instances": #"{"Instances":[{"InstanceId":"i-1"}]}"#
                case "ec2 describe-instances": #"{"Reservations":[{"Instances":[{"InstanceId":"i-1","InstanceType":"t4g.medium","State":{"Name":"running"},"PublicIpAddress":"3.3.3.3","Tags":[{"Key":"racky:managed","Value":"true"}]}]}]}"#
                case "sts get-caller-identity": #"{"Account":"123","Arn":"arn:aws:sts::123:assumed-role/x"}"#
                default: "{}"
                }
                return ProcessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: Data(), truncated: false)
            }
        }
    }

    @Test func awsProvisionLaunchesALockedDownSelfTerminatingHost() async throws {
        let fake = FakeAWS()
        let aws = AWSProvider(
            cli: AWSCLI(profile: "racky", executable: URL(fileURLWithPath: "/bin/echo"), runner: fake.runner()), publicIP: { "1.2.3.4" }, sleep: { _ in })
        let tags = RackyTags(owner: "o", host: "h-1", created: CloudFixture.noon, expires: CloudFixture.noon, provider: .aws)
        let host = try await aws.provisionHost(HostRequest(
            region: "us-east-2", shape: AWSProvider.shape(forComputers: 1), tags: tags, userData: "#cloud-config\nsecret-host-key", maxLifetime: .seconds(60)))
        #expect(host.id == "i-1" && host.address == "3.3.3.3" && host.state == .running)
        let run = try #require(fake.calls.first { $0.starts(with: ["ec2", "run-instances"]) })
        let line = run.joined(separator: " ")
        #expect(line.contains("--instance-initiated-shutdown-behavior terminate"))
        #expect(line.contains("HttpTokens=required,HttpPutResponseHopLimit=1"))
        #expect(line.contains("DeleteOnTermination=true"))
        #expect(line.contains("ResourceType=volume,Tags=[") && line.contains("Key=racky:managed,Value=true"))
        #expect(line.contains("--client-token h-1") && line.contains("--profile racky"))
        // A chave do host vai por arquivo, nunca na linha de comando; e o arquivo some depois.
        #expect(!line.contains("secret-host-key") && fake.userData?.contains("secret-host-key") == true)
        // SSH só do IP atual: o antigo sai, o novo entra.
        #expect(fake.calls.contains { $0.starts(with: ["ec2", "revoke-security-group-ingress"]) && $0.contains("9.9.9.9/32") })
        #expect(fake.calls.contains { $0.starts(with: ["ec2", "authorize-security-group-ingress"]) && $0.contains("1.2.3.4/32") && $0.contains("22") })
    }

    @Test func awsSignedOutErrorsAskToConnectAgain() async {
        let cli = AWSCLI(profile: "racky", executable: URL(fileURLWithPath: "/bin/echo")) { _, _, _ in
            ProcessOutput(exitCode: 255, stdout: Data(), stderr: Data("Error when retrieving token from sso: Token has expired and refresh failed".utf8), truncated: false)
        }
        await #expect(throws: AWSCLI.Failure.self) { _ = try await cli.identity() }
        do { _ = try await cli.identity() } catch let error as AWSCLI.Failure {
            if case .signedOut = error {} else { Issue.record("expected signedOut, got \(error)") }
        } catch { Issue.record("\(error)") }
    }
}
