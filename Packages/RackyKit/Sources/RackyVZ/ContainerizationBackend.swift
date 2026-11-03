import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import RackyCore
import RackyDocker
import Synchronization

// Backend real: Virtualization.framework via apple/containerization 0.52.1. Todas as VMs vivem NESTE processo (limite do framework).
// Precisa do entitlement `com.apple.security.virtualization` no binário que o hospeda e de macOS 26 (vmnet compartilhada).

@available(macOS 26, *)
public actor ContainerizationBackend: VZBackend {
    private let manager: ContainerManager
    /// Cria as VMs; cada container ganha um embrulho com o balão de memória (VZBalloon).
    private let vmm: VZVirtualMachineManager
    /// A alocação de IPs é do actor (sem passar pelo `ContainerManager`, que copiaria o estado através de awaits): sempre síncrona.
    private var network: VmnetNetwork
    private let paths: VZPaths
    private let subnetText: String
    private var live: [String: ContainerizationVM] = [:]

    public init(paths: VZPaths, assets: VZReadyAssets) throws {
        self.paths = paths
        // Sem `init_on_free=1` (medido em 02/11): o kernel zera toda a memória no boot e cada VM nasce ocupando o teto inteiro no Mac.
        // O ajuste do balão lê a memória da VM a cada 3 s por um exec curto; com o log do vminitd em `info`, cada um grava três
        // linhas no bootlog. `warning` mantém erros e as mensagens do kernel (o OOM de 02/11 foi achado por elas).
        var commandLine = Kernel.CommandLine(debug: false, panic: 0)
        commandLine.setAgentLogLevel(level: .warning)
        let kernel = Kernel(path: assets.kernel, platform: .linuxArm, commandline: commandLine)
        let initfs = Mount.block(format: "ext4", source: assets.initfs.path, destination: "/", options: ["ro"])
        let network = try VmnetNetwork()
        self.network = network
        subnetText = "\(network.subnet)"
        manager = try ContainerManager(kernel: kernel, initfs: initfs, root: paths.store, network: nil)
        vmm = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)
    }

    public var internalSubnet: String { subnetText }

    public func boot(_ plan: VZVMPlan, image: VZBootImage) async throws -> any RunningVM {
        let fm = FileManager.default
        var interface: (any Containerization.Interface)?
        let directory = paths.containerDirectory(plan.vmID)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let rootfsURL = directory.appendingPathComponent("rootfs.ext4")
            try Self.clone(image.templateRootfs, to: rootfsURL)
            let rootfs = Mount.block(format: "ext4", source: rootfsURL.path, destination: "/", options: [])
            let containerImage = try await manager.imageStore.get(reference: image.reference)
            let imageEnvironment = (try await containerImage.config(for: .current).config?.env) ?? []
            let environment = Self.merge(imageEnvironment, plan.environment)
            let capabilities = try plan.capabilities.map { try CapabilityName(rawValue: $0) }
            let resources = VMResources(cpus: plan.cpus, memoryInBytes: plan.memoryBytes + VMResources.guestMemoryOverhead)
            interface = try network.createInterface(plan.vmID)
            guard let nic = interface, let gateway = nic.ipv4Gateway else { throw VZError.bootFailed("no vmnet interface") }
            let imageConfig = try await containerImage.config(for: .current).config
            let balloon = VZBalloonHandle()
            let container = try LinuxContainer(plan.vmID, rootfs: rootfs, vmm: VZBalloonVMM(base: vmm, handle: balloon), vm: resources) { config in
                if let imageConfig { config.process = .init(from: imageConfig) }
                config.interfaces = [nic]
                config.dns = .init(nameservers: [gateway.description])
                config.bootLog = BootLog.file(path: directory.appendingPathComponent("bootlog.log"))
                config.cpus = plan.cpus
                config.memoryInBytes = plan.memoryBytes
                config.hostname = plan.hostname
                config.useInit = plan.useInit
                config.sysctl = plan.sysctl
                config.process.workingDirectory = plan.workingDirectory
                config.process.environmentVariables = environment
                config.process.noNewPrivileges = plan.noNewPrivileges
                if !plan.capabilities.isEmpty { config.process.capabilities = LinuxCapabilities(capabilities: capabilities) }
                if let pids = plan.pidsMax { config.unified["pids.max"] = "\(pids)" }
                for tmpfs in plan.tmpfs {
                    config.mounts.append(.any(type: "tmpfs", source: "tmpfs", destination: tmpfs.destination, options: tmpfs.options))
                }
                for share in plan.shares {
                    config.mounts.append(.share(source: share.hostPath, destination: share.guestPath, options: share.readOnly ? ["ro"] : []))
                }
            }
            do {
                try await container.create()
                try await container.start()
            } catch {
                try? await container.stop()
                throw error
            }
            let vm = ContainerizationVM(
                vmID: plan.vmID, container: container, baseEnvironment: environment, ipAddress: container.interfaces.first.map { "\($0.ipv4Address.address)" },
                rootfs: rootfsURL, balloon: balloon, memoryBytes: resources.memoryInBytes, release: { [weak self] id in await self?.release(id) })
            live[plan.vmID] = vm
            if ProcessInfo.processInfo.environment["RACKY_VZ_DEV_NO_BALLOON"] != "1" { vm.startReclaiming() }
            return vm
        } catch let error as VZError {
            release(plan.vmID)
            throw error
        } catch {
            release(plan.vmID)
            throw VZError.bootFailed("\(error)")
        }
    }

    /// Libera rede e pasta da VM (depois de parada, ou de um boot que falhou).
    func release(_ id: String) {
        live[id] = nil
        try? network.releaseInterface(id)
        try? FileManager.default.removeItem(at: paths.containerDirectory(id))
    }

    /// Para todas as VMs (fim do app).
    public func stopAll() async {
        for vm in Array(live.values) { await vm.stop() }
    }

    // MARK: Utilitários

    /// `KEY=VALUE`: o segundo conjunto vence, a ordem do primeiro se mantém (um `getenv` pega o primeiro duplicado, então não repete).
    static func merge(_ base: [String], _ overrides: [String]) -> [String] {
        var order: [String] = []
        var values: [String: String] = [:]
        for entry in base + overrides {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            if values[key] == nil { order.append(key) }
            values[key] = String(entry[entry.index(after: equals)...])
        }
        return order.map { "\($0)=\(values[$0] ?? "")" }
    }

    /// Clone APFS (copy-on-write, instantâneo) do template; cai para cópia comum se o volume não suporta.
    static func clone(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/// Uma VM de computador em execução sobre `LinuxContainer`.
@available(macOS 26, *)
final class ContainerizationVM: RunningVM {
    let vmID: String
    let ipAddress: String?
    private let container: LinuxContainer
    private let baseEnvironment: [String]
    private let release: @Sendable (String) async -> Void
    private let stopped = Mutex(false)
    /// O disco da VM: identifica o processo do framework que roda esta VM, para o desligamento forçado.
    private let rootfs: URL
    private let balloon: VZBalloonHandle
    private let memoryBytes: UInt64
    private let reclaimer = Mutex<Task<Void, Never>?>(nil)

    init(vmID: String, container: LinuxContainer, baseEnvironment: [String], ipAddress: String?, rootfs: URL, balloon: VZBalloonHandle,
         memoryBytes: UInt64, release: @escaping @Sendable (String) async -> Void) {
        self.vmID = vmID
        self.rootfs = rootfs
        self.balloon = balloon
        self.memoryBytes = memoryBytes
        self.container = container
        self.baseEnvironment = baseEnvironment
        self.ipAddress = ipAddress
        self.release = release
    }

    func startProcess(_ request: VZExecRequest) async throws -> any ComputerExecSession {
        guard let user = VZUser.resolve(request.user) else { throw VZError.unavailable("unknown user \(request.user ?? "")") }
        let (stream, continuation) = AsyncThrowingStream<DockerStreamFrame, any Error>.makeStream()
        let stdin = request.attachStdin ? StdinPipe() : nil
        let environment = ContainerizationBackend.merge(baseEnvironment, request.environment)
        let process = try await container.exec("x-\(UUID().uuidString.lowercased())") { config in
            config.arguments = request.command
            config.environmentVariables = environment
            if let directory = request.workingDirectory { config.workingDirectory = directory }
            config.user = ContainerizationOCI.User(uid: user.uid, gid: user.gid, umask: nil, additionalGids: [], username: "")
            if user.uid != 0 {
                // Como `docker exec -u agent`: sem capacidade nenhuma e sem ganhar privilégio.
                config.capabilities = LinuxCapabilities(capabilities: [])
                config.noNewPrivileges = true
            } else if request.systemAdmin {
                config.capabilities = LinuxCapabilities(capabilities: [.sysAdmin, .dacOverride, .chown, .fowner])
            }
            config.stdout = FrameWriter(kind: .stdout, continuation: continuation)
            config.stderr = FrameWriter(kind: .stderr, continuation: continuation)
            if let stdin { config.stdin = stdin }
        }
        do { try await process.start() } catch {
            try? await process.delete()
            continuation.finish(throwing: error)
            throw error
        }
        let done = AtomicFlag()
        let exit = Task<Int, any Error> {
            defer { continuation.finish() }
            let status = try await process.wait()
            _ = done.setOnce()
            try? await process.delete()
            return Int(status.exitCode)
        }
        return ContainerizationProcess(frames: stream, stdin: stdin, process: process, exit: exit, done: done)
    }

    func dialVsock(port: UInt32) async throws -> FileHandle { try await container.dialVsock(port: port) }

    func copyIn(from source: URL, to guestPath: String) async throws {
        try await container.copyIn(from: source, to: URL(fileURLWithPath: guestPath))
    }

    func copyOut(from guestPath: String, to destination: URL) async throws {
        try await container.copyOut(from: URL(fileURLWithPath: guestPath), to: destination)
    }

    /// Ajusta o balão a cada poucos segundos (VZBalloonPolicy). Lê o `/proc/meminfo` da VM por um exec curto de root.
    func startReclaiming(every interval: Duration = .seconds(3)) {
        let task = Task { [weak self] in
            var current: UInt64?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                current = await self.adjustBalloon(current: current ?? self.memoryBytes)
            }
        }
        reclaimer.withLock { $0?.cancel(); $0 = task }
    }

    /// Um passo do ajuste; devolve o tamanho em vigor depois dele.
    func adjustBalloon(current: UInt64) async -> UInt64 {
        guard balloon.isAttached,
              let out = try? await run(VZExecRequest(command: ["cat", "/proc/meminfo"], user: "root"), timeout: .seconds(10)),
              let info = VZBalloonPolicy.parse(out.stdoutString) else { return current }
        let next = VZBalloonPolicy.next(current: current, configured: memoryBytes, info: info)
        if next != current {
            await balloon.setTarget(bytes: next)
            if ProcessInfo.processInfo.environment["RACKY_VZ_DEV_BALLOON_LOG"] == "1" {
                FileHandle.standardError.write(Data("balloon \(vmID): \(current >> 20) -> \(next >> 20) MiB of \(memoryBytes >> 20)\n".utf8))
            }
        }
        return next
    }

    func stop() async {
        guard stopped.withLock({ let first = !$0; $0 = true; return first }) else { return }
        reclaimer.withLock { $0?.cancel(); $0 = nil }
        let container = container
        // VM travada não responde ao desligamento educado; sem prazo, ela seguia ligada (e o registro preso) para sempre.
        if await !VZForceStop.finishes(within: .seconds(30), { try? await container.stop() }) {
            await VZForceStop.killVM(holding: rootfs)
        }
        await release(vmID)
    }
}

/// stdout/stderr do processo como frames (a mesma forma do multiplex do Docker).
@available(macOS 26, *)
struct FrameWriter: Writer {
    let kind: DockerStreamKind
    let continuation: AsyncThrowingStream<DockerStreamFrame, any Error>.Continuation
    func write(_ data: Data) throws { continuation.yield(DockerStreamFrame(kind: kind, data: data)) }
    func close() throws {}
}

/// stdin escrito aos poucos (`writeInput`) e fechado por `closeInput`.
@available(macOS 26, *)
final class StdinPipe: ReaderStream {
    private let source: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        (source, continuation) = AsyncStream<Data>.makeStream()
    }

    func stream() -> AsyncStream<Data> { source }
    func write(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
}

@available(macOS 26, *)
final class ContainerizationProcess: ComputerExecSession {
    let frames: AsyncThrowingStream<DockerStreamFrame, any Error>
    private let stdin: StdinPipe?
    private let process: LinuxProcess
    private let exit: Task<Int, any Error>
    private let done: AtomicFlag

    init(frames: AsyncThrowingStream<DockerStreamFrame, any Error>, stdin: StdinPipe?, process: LinuxProcess, exit: Task<Int, any Error>, done: AtomicFlag) {
        self.frames = frames
        self.stdin = stdin
        self.process = process
        self.exit = exit
        self.done = done
    }

    func writeInput(_ data: Data) async throws { stdin?.write(data) }
    func closeInput() async { stdin?.finish() }
    func finalExitCode() async throws -> Int { try await exit.value }

    /// Sem wrapper de grupo (o `VZGroupedExecSession` cuida do grupo): SIGTERM e, depois de `grace`, SIGKILL no processo.
    func terminateGroup(grace: Duration) async throws {
        try? await process.kill(.term)
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if done.isSet { return }
        }
        try? await process.kill(.kill)
    }
}
