import Foundation

@testable import RackyCore

/// Relógio de teste que anda só quando o teste manda.
final class CloudTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    var reader: @Sendable () -> Date { { [self] in now } }
}

enum CloudFixture {
    /// 2026-10-20 12:00:00 UTC.
    static let noon = Date(timeIntervalSince1970: 1_792_497_600)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    static let access = CloudHostManager.Access(
        authorizedKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEFVVEhPUklaRURBVVRIT1JJWkVEQVVUSE9SSVpFRA racky",
        hostKey: CloudInit.HostKey(
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAFAKEFAKEFAKEFAKE\nFAKEFAKEFAKEFAKEFAKE\n-----END OPENSSH PRIVATE KEY-----",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhPU1RIT1NUSE9TVEhPU1RIT1NUSE9TVEhPU1RI"))
    static let large = HostShape(id: "c7g.4xlarge", vcpus: 16, memoryGiB: 32)
    static let small = HostShape(id: "c7g.large", vcpus: 2, memoryGiB: 4)

    static func manager(
        provider: FakeCloudProvider, clock: CloudTestClock, caps: SpendCaps = SpendCaps(), policy: DeadManPolicy = DeadManPolicy(),
        accepted: Bool = true, owner: String = "install-1"
    ) -> CloudHostManager {
        CloudHostManager(
            provider: provider, settings: .init(owner: owner, caps: caps, policy: policy, calendar: utc), clock: clock.reader,
            acceptedAUP: { _, _ in accepted })
    }
}
