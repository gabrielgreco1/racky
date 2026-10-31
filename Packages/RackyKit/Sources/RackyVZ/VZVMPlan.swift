import Foundation
import RackyDocker

public enum VZPlanError: Error, Equatable, LocalizedError, Sendable {
    /// Volume nomeado (`volume:/destino`): o runtime nativo só tem pastas do Mac (virtiofs) e tmpfs.
    case namedVolume(String)
    case malformedBind(String)

    public var errorDescription: String? {
        switch self {
        case .namedVolume(let value): "named volumes aren't supported by the built-in computer runtime (\(value))"
        case .malformedBind(let value): "malformed bind mount: \(value)"
        }
    }
}

/// A VM de um computador, em tipos próprios (sem apple/containerization): é o que o mapeamento `ContainerSpec` -> VM produz e o que o
/// backend de VM consome. Existe separado para o mapeamento ser testável em qualquer macOS e para os testes usarem uma VM falsa.
///
/// O que cada campo do Docker virou (docs/rebuild/vz-runtime.md):
///
///     Docker (`ContainerSpec`)            VM
///     ------------------------------------------------------------------------------
///     resources.memoryBytes / cpus        memória e vCPUs da VM (cpus arredonda para cima)
///     resources.pidsLimit                 cgroup `pids.max` do container
///     tmpfs[dest] = "rw,nosuid,size=…"    montagem tmpfs com as mesmas opções (uid/gid/mode vão no option string)
///     binds "host:dest[:ro]"              compartilhamento virtiofs (pasta do Mac)
///     named (volumes)                     não suportado: erro
///     capAdd + CapDrop ALL                bounding/effective/permitted = só as capacidades listadas
///     noNewPrivileges, useInit            iguais (processo init + `no_new_privs`)
///     environment, workingDirectory       iguais; hostname igual
///     readOnlyRootfs                      NÃO aplicado: o rootfs é um clone privado descartado no fim e a VM já é a fronteira
///     publishedPorts                      ponte TCP no Mac -> vsock (ver `VZPortBridge`)
///     labels / healthcheck / network      registro próprio (`VZRegistry`) / a admin API responde / vmnet compartilhada
public struct VZVMPlan: Sendable, Equatable {
    public struct Tmpfs: Sendable, Equatable {
        public var destination: String
        /// Sem o `rw` (padrão do tmpfs); ex.: `["nosuid", "size=1g", "mode=1777"]`.
        public var options: [String]
        public init(destination: String, options: [String]) { self.destination = destination; self.options = options }
    }

    public struct Share: Sendable, Equatable {
        public var hostPath: String
        public var guestPath: String
        public var readOnly: Bool
        public init(hostPath: String, guestPath: String, readOnly: Bool) { self.hostPath = hostPath; self.guestPath = guestPath; self.readOnly = readOnly }
    }

    /// Nome da VM no disco e no registro (`ab-<computerId8>`).
    public var vmID: String
    public var hostname: String
    public var cpus: Int
    public var memoryBytes: UInt64
    public var environment: [String]
    public var workingDirectory: String
    /// Nomes sem o prefixo `CAP_` (`NET_ADMIN`).
    public var capabilities: [String]
    public var noNewPrivileges: Bool
    public var useInit: Bool
    public var pidsMax: Int?
    public var tmpfs: [Tmpfs]
    public var shares: [Share]
    public var stopTimeoutSeconds: Int
    /// sysctls da VM. O padrão desliga o IPv6: a vmnet dá um endereço ULA e uma rota default que não levam a lugar nenhum, e o proxy
    /// (que tenta o AAAA primeiro) falhava de forma intermitente; o computador do Docker também não tem IPv6.
    public var sysctl: [String: String] = ["net.ipv6.conf.all.disable_ipv6": "1", "net.ipv6.conf.default.disable_ipv6": "1"]

    public init(
        vmID: String, hostname: String, cpus: Int, memoryBytes: UInt64, environment: [String], workingDirectory: String, capabilities: [String],
        noNewPrivileges: Bool, useInit: Bool, pidsMax: Int?, tmpfs: [Tmpfs], shares: [Share], stopTimeoutSeconds: Int
    ) {
        self.vmID = vmID; self.hostname = hostname; self.cpus = cpus; self.memoryBytes = memoryBytes; self.environment = environment
        self.workingDirectory = workingDirectory; self.capabilities = capabilities; self.noNewPrivileges = noNewPrivileges; self.useInit = useInit
        self.pidsMax = pidsMax; self.tmpfs = tmpfs; self.shares = shares; self.stopTimeoutSeconds = stopTimeoutSeconds
    }

    /// Mapeia a especificação do container (a mesma do Docker, vinda de `ComputerProvisioner.containerSpec`) para a VM.
    public init(spec: ContainerSpec, vmID: String) throws {
        // Pai antes de filho (`/run/racky` antes de `/run/racky/logs`): a montagem aninhada precisa do diretório do pai.
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        var tmpfs: [Tmpfs] = spec.tmpfs.map { destination, options in
            Tmpfs(destination: destination, options: options.split(separator: ",").map(String.init).filter { $0 != "rw" })
        }
        var shares: [Share] = []
        for bind in spec.binds {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3, parts[0].hasPrefix("/"), parts[1].hasPrefix("/") else { throw VZPlanError.malformedBind(bind) }
            shares.append(Share(hostPath: parts[0], guestPath: parts[1], readOnly: parts.count == 3 && parts[2].split(separator: ",").contains("ro")))
        }
        if let named = spec.named.first { throw VZPlanError.namedVolume(named) }
        tmpfs.sort { (depth($0.destination), $0.destination) < (depth($1.destination), $1.destination) }
        shares.sort { (depth($0.guestPath), $0.guestPath) < (depth($1.guestPath), $1.guestPath) }

        let cpus = max(1, Int((spec.resources.cpus ?? 1).rounded(.up)))
        let memory = UInt64(max(spec.resources.memoryBytes ?? (1 << 30), 256 << 20))
        // `CapDrop ALL` + `CapAdd`: sobra só a lista. Sem `CapDrop ALL`, usa as padrão do runtime (nunca acontece nos computadores).
        self.init(
            vmID: vmID, hostname: spec.hostname ?? "computer", cpus: cpus, memoryBytes: memory, environment: spec.environment,
            workingDirectory: spec.workingDirectory ?? "/", capabilities: spec.hardening.dropAllCapabilities ? spec.capAdd : [],
            noNewPrivileges: spec.hardening.noNewPrivileges, useInit: spec.hardening.useInit,
            pidsMax: spec.resources.pidsLimit.map(Int.init), tmpfs: tmpfs, shares: shares, stopTimeoutSeconds: spec.stopTimeoutSeconds ?? 5)
    }
}
