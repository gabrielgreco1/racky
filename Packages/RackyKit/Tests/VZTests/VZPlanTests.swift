import Foundation
import RackyCore
import RackyDocker
import Testing

@testable import RackyVZ

/// Mapeamento `ContainerSpec` (a mesma do Docker) -> VM, sem subir nada.
@Suite struct VZPlanTests {
    static func request(display: ComputerDisplay = .headless) -> ComputerProvisionRequest {
        let labels = ComputerLabels(owner: "racky", computerID: "01234567-89ab-cdef-0123-456789abcdef", computerName: "scout")
        return ComputerProvisionRequest(
            labels: labels, image: "racky-computer", display: display, token: "t", config: EgressConfigFile(internalSubnet: "192.168.64.0/24"),
            secrets: BoxSecretFiles(root: URL(fileURLWithPath: "/tmp/x")), runDirectory: URL(fileURLWithPath: "/tmp/run/scout"))
    }

    static func plan(display: ComputerDisplay = .headless) throws -> VZVMPlan {
        let spec = VZComputerProvisioning.containerSpec(
            request(display: display), work: URL(fileURLWithPath: "/tmp/run/scout/work"), logs: URL(fileURLWithPath: "/tmp/run/scout/logs"),
            taskSecrets: URL(fileURLWithPath: "/tmp/boxes/c/work"))
        return try VZVMPlan(spec: spec, vmID: "ab-01234567-aaaa")
    }

    @Test func resourcesRoundCpusUpAndKeepTheDockerMemoryCeiling() throws {
        let headless = try Self.plan(display: .headless)
        #expect(headless.cpus == 2)  // 1,75 -> 2
        #expect(headless.memoryBytes == 5 << 29)  // 2,5 GiB
        let http = try Self.plan(display: .http)
        #expect(http.cpus == 1)  // 0,75 -> 1
        #expect(http.memoryBytes == 1 << 30)
        #expect(try Self.plan(display: .desktop).cpus == 3)  // 2,75 -> 3
        #expect(headless.pidsMax == 1536)
    }

    @Test func tmpfsKeepsUidModeAndSizeButDropsRw() throws {
        let plan = try Self.plan()
        let byPath = Dictionary(uniqueKeysWithValues: plan.tmpfs.map { ($0.destination, $0.options) })
        #expect(byPath["/tmp"] == ["nosuid", "size=1g", "mode=1777"])
        #expect(byPath["/home/agent"] == ["nosuid", "size=256m", "uid=10001", "gid=10001", "mode=0755"])
        #expect(byPath["/run/racky"] == ["nosuid", "noexec", "size=64m", "uid=10003", "gid=10003", "mode=0700"])
        #expect(plan.tmpfs.allSatisfy { !$0.options.contains("rw") })
    }

    @Test func bindsBecomeVirtiofsSharesAndKeepReadOnly() throws {
        let plan = try Self.plan()
        let shares = Dictionary(uniqueKeysWithValues: plan.shares.map { ($0.guestPath, $0) })
        #expect(shares["/work"]?.hostPath == "/tmp/run/scout/work")
        #expect(shares["/work"]?.readOnly == false)
        #expect(shares["/run/abx-secrets"]?.readOnly == true)
        #expect(shares["/run/abx-secrets"]?.hostPath == "/tmp/boxes/c/work")
        #expect(shares["/run/racky/logs"]?.hostPath == "/tmp/run/scout/logs")
    }

    @Test func parentMountsComeBeforeNestedOnes() throws {
        let plan = try Self.plan()
        // `/run/racky/logs` (share) vive dentro do tmpfs `/run/racky`: o backend monta todos os tmpfs antes dos shares, e cada lista
        // fica em ordem de profundidade.
        let tmpfs = plan.tmpfs.map(\.destination)
        #expect(tmpfs == tmpfs.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) })
        #expect(tmpfs.contains("/run/racky"))
        let shares = plan.shares.map(\.guestPath)
        #expect(shares == shares.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) })
    }

    @Test func hardeningMapsToCapabilitiesAndFlags() throws {
        let plan = try Self.plan()
        #expect(plan.capabilities == ["NET_ADMIN", "SETUID", "SETGID", "SETPCAP", "KILL"])
        #expect(plan.noNewPrivileges)
        #expect(plan.useInit)
        #expect(plan.hostname == "computer")
        #expect(plan.workingDirectory == "/work")
        #expect(plan.stopTimeoutSeconds == 5)
    }

    @Test func environmentCarriesProxyVariablesAndTheVMOnlyOnes() throws {
        let plan = try Self.plan()
        #expect(plan.environment.contains("RACKY_ADMIN_BIND=127.0.0.1"))
        #expect(plan.environment.contains("RACKY_VSOCK_PORT=8791"))
        #expect(plan.environment.contains("HTTPS_PROXY=http://127.0.0.1:3128"))
        #expect(plan.environment.contains("RACKY_DISPLAY=browser"))
        #expect(plan.environment.contains("DISPLAY=:99"))
    }

    @Test func namedVolumesAndMalformedBindsAreRejected() {
        var spec = ContainerSpec(name: "x", image: "i")
        spec.named = ["ab-prof-1:/profile"]
        #expect(throws: VZPlanError.namedVolume("ab-prof-1:/profile")) { try VZVMPlan(spec: spec, vmID: "x") }
        spec.named = []
        spec.binds = ["relative:/work"]
        #expect(throws: VZPlanError.malformedBind("relative:/work")) { try VZVMPlan(spec: spec, vmID: "x") }
    }

    @Test func usersResolveLikeTheImage() {
        #expect(VZUser.resolve("agent") == VZUser(uid: 10001, gid: 10001))
        #expect(VZUser.resolve("egress") == VZUser(uid: 10003, gid: 10003))
        #expect(VZUser.resolve(nil) == VZUser(uid: 0, gid: 0))
        #expect(VZUser.resolve("root") == VZUser(uid: 0, gid: 0))
        #expect(VZUser.resolve("1000:2000") == VZUser(uid: 1000, gid: 2000))
        #expect(VZUser.resolve("nobody") == nil)
    }
}
