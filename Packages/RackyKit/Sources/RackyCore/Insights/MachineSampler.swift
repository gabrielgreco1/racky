import Darwin
import Foundation
import IOKit

/// Matemática pura do monitor (testável sem tocar no kernel).
public enum MachineMath {
    public struct CPUTicks: Sendable, Equatable {
        public var user: UInt64
        public var system: UInt64
        public var idle: UInt64
        public var nice: UInt64
        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user; self.system = system; self.idle = idle; self.nice = nice
        }
        var busy: UInt64 { user &+ system &+ nice }
        var total: UInt64 { busy &+ idle }
    }

    /// Fração ocupada entre duas leituras de ticks. `nil` se o contador não avançou (ou recuou).
    public static func cpu(from a: CPUTicks, to b: CPUTicks) -> (total: Double, user: Double, system: Double)? {
        guard b.total > a.total, b.user >= a.user, b.system >= a.system, b.idle >= a.idle else { return nil }
        let dt = Double(b.total - a.total)
        return (Double(b.busy - a.busy) / dt, Double((b.user - a.user) + (b.nice - a.nice)) / dt, Double(b.system - a.system) / dt)
    }

    /// Bytes por segundo entre dois contadores de 64 bits; contador que recuou (interface reiniciada) vira 0.
    public static func rate(from a: UInt64, to b: UInt64, seconds: Double) -> Double {
        guard seconds > 0, b >= a else { return 0 }
        return Double(b - a) / seconds
    }

    /// Percentual de UM núcleo a partir de tempo de CPU consumido (ns) e tempo de parede (ns).
    public static func cpuPercent(cpuNanos: UInt64, previous: UInt64, wallNanos: UInt64) -> Double {
        guard wallNanos > 0, cpuNanos >= previous else { return 0 }
        return Double(cpuNanos - previous) / Double(wallNanos) * 100
    }

    /// Nome do app a partir do caminho do executável: `/Applications/Foo.app/Contents/MacOS/Foo Helper` → `Foo`.
    public static func appName(path: String) -> String? {
        // O `.app` mais externo vence (helpers ficam em `Foo.app/Contents/Frameworks/…Helper.app`).
        guard let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }), bundle.count > 4 else { return nil }
        return String(bundle.dropLast(4))
    }

    /// Agrupa processos por app e ordena.
    public static func group(_ processes: [(name: String, app: String?, cpu: Double, memory: UInt64)]) -> [AppUsage] {
        var map: [String: AppUsage] = [:]
        for p in processes {
            let key = p.app ?? p.name
            var entry = map[key] ?? AppUsage(name: key, cpuPercent: 0, memoryBytes: 0, processCount: 0)
            entry.cpuPercent += p.cpu
            entry.memoryBytes += p.memory
            entry.processCount += 1
            map[key] = entry
        }
        return Array(map.values)
    }

    /// Interfaces físicas que contam para "rede" (ignora loopback, túneis e interfaces internas da Apple).
    public static func includesInterface(_ name: String) -> Bool {
        guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { return false }
        return true
    }
}

/// Amostrador da máquina: CPU/memória (Mach), processos (libproc), disco (volume + IOKit) e rede (sysctl `NET_RT_IFLIST2`,
/// contadores de 64 bits). A abordagem de leitura é a documentada pela Apple; nada aqui precisa de privilégio.
public actor MachineSampler {
    private var previousTicks: MachineMath.CPUTicks?
    private var previousCoreTicks: [MachineMath.CPUTicks] = []
    private var previousNet: (down: UInt64, up: UInt64, at: Date)?
    private var previousDisk: (read: UInt64, write: UInt64, at: Date)?
    private var capacity: (total: Int, free: Int64, at: Date)?
    static let capacityTTL: TimeInterval = 30
    static let processTTL: TimeInterval = 2.5
    private var topCache: (cpu: [AppUsage], mem: [AppUsage], at: Date)?
    /// Quantas vezes os processos foram de fato enumerados (testes).
    public private(set) var processReads = 0
    private var previousProc: [Int32: UInt64] = [:]
    private var previousProcAt: Date?
    private var pathCache: [Int32: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)
    private let topCount: Int

    /// Leitura da capacidade do volume (total, livre). Injetável para o teste contar as chamadas.
    private let capacityReader: @Sendable () -> (total: Int, free: Int64)?

    public init(topCount: Int = 6, capacityReader: @escaping @Sendable () -> (total: Int, free: Int64)? = MachineSampler.readVolumeCapacity) {
        self.capacityReader = capacityReader
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(max(1, info.denom)))
        self.topCount = topCount
    }

    public func sample(now: Date = Date(), includeProcesses: Bool = true) -> MachineSnapshot {
        let (cpu, cores) = readCPU()
        let memory = readMemory()
        let disk = readDisk(now: now)
        let network = readNetwork(now: now)
        var byCPU: [AppUsage] = []
        var byMem: [AppUsage] = []
        if includeProcesses {
            // Enumerar todos os processos custa mais que o resto do tick: as listas "top" se renovam a cada 3 s, não a cada 1,5 s.
            if let cached = topCache, now.timeIntervalSince(cached.at) < Self.processTTL {
                (byCPU, byMem) = (cached.cpu, cached.mem)
            } else {
                processReads += 1
                let apps = readProcesses(now: now)
                byCPU = apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(topCount).map { $0 }
                byMem = apps.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(topCount).map { $0 }
                topCache = (byCPU, byMem, now)
            }
        }
        return MachineSnapshot(
            at: now, cpu: cpu, memory: memory, disk: disk, network: network, topByCPU: byCPU, topByMemory: byMem,
            thermal: Self.thermalName(ProcessInfo.processInfo.thermalState), uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            coreCount: cores)
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: CPU

    private func readCPU() -> (CPUSample?, Int) {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &load) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        var perCore: [Double] = []
        var cores = ProcessInfo.processInfo.activeProcessorCount
        var coreTicks: [MachineMath.CPUTicks] = []
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS, let infoArray {
            cores = Int(cpuCount)
            for i in 0..<Int(cpuCount) {
                let base = Int(CPU_STATE_MAX) * i
                coreTicks.append(.init(user: UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)])),
                                       system: UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)])),
                                       idle: UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)])),
                                       nice: UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)]))))
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: infoArray)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        if previousCoreTicks.count == coreTicks.count {
            perCore = zip(previousCoreTicks, coreTicks).map { MachineMath.cpu(from: $0, to: $1)?.total ?? 0 }
        }
        previousCoreTicks = coreTicks

        var loadavg = [Double](repeating: 0, count: 3)
        getloadavg(&loadavg, 3)
        guard kr == KERN_SUCCESS else { return (nil, cores) }
        let ticks = MachineMath.CPUTicks(user: UInt64(load.cpu_ticks.0), system: UInt64(load.cpu_ticks.1),
                                         idle: UInt64(load.cpu_ticks.2), nice: UInt64(load.cpu_ticks.3))
        defer { previousTicks = ticks }
        guard let previousTicks, let r = MachineMath.cpu(from: previousTicks, to: ticks) else { return (nil, cores) }
        return (CPUSample(total: r.total, user: r.user, system: r.system, perCore: perCore, load1: loadavg[0], load5: loadavg[1], load15: loadavg[2]), cores)
    }

    // MARK: Memória

    private func sysctlValue<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard sysctlbyname(name, buffer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return buffer.load(as: T.self)
    }

    private func readMemory() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(sysctlValue("hw.pagesize", as: Int32.self) ?? 16_384)
        let total = ProcessInfo.processInfo.physicalMemory
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        let used = min(total, app + wired + compressed)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let level = sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1
        let pressure: MemoryPressureLevel = level >= 4 ? .critical : (level >= 2 ? .warning : .normal)
        return MemorySample(totalBytes: total, usedBytes: used, appBytes: app, wiredBytes: wired, compressedBytes: compressed,
                            cachedBytes: cached, swapUsedBytes: hasSwap ? swap.xsu_used : 0, swapTotalBytes: hasSwap ? swap.xsu_total : 0,
                            pressure: pressure)
    }

    // MARK: Disco

    @Sendable public static func readVolumeCapacity() -> (total: Int, free: Int64)? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity else { return nil }
        return (total, values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private func readDisk(now: Date) -> DiskSample? {
        // Capacidade do volume muda devagar e `volumeAvailableCapacityForImportantUsage` faz uma ida e volta XPC síncrona ao CacheDelete:
        // a cada tick isso era o maior consumidor de CPU do app parado (T2-11). Relê a cada 30 s e reaproveita entre os ticks.
        let total: Int, free: Int64
        if let cached = capacity, now.timeIntervalSince(cached.at) < Self.capacityTTL {
            (total, free) = (cached.total, cached.free)
        } else {
            guard let read = capacityReader() else { return nil }
            (total, free) = (read.total, read.free)
            capacity = (total, free, now)
        }
        var readRate = 0.0
        var writeRate = 0.0
        if let io = Self.blockStorageCounters() {
            if let prev = previousDisk {
                let dt = now.timeIntervalSince(prev.at)
                readRate = MachineMath.rate(from: prev.read, to: io.read, seconds: dt)
                writeRate = MachineMath.rate(from: prev.write, to: io.write, seconds: dt)
            }
            previousDisk = (io.read, io.write, now)
        }
        return DiskSample(totalBytes: UInt64(max(0, total)), freeBytes: UInt64(max(0, free)), readBytesPerSec: readRate, writeBytesPerSec: writeRate)
    }

    /// Bytes lidos/escritos desde o boot, somados nos drivers de armazenamento de bloco (IOKit, só leitura).
    static func blockStorageCounters() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any] else { continue }
            found = true
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? (read, write) : nil
    }

    // MARK: Rede

    private func readNetwork(now: Date) -> NetworkSample? {
        guard let counters = Self.networkCounters() else { return nil }
        var down = 0.0
        var up = 0.0
        if let prev = previousNet {
            let dt = now.timeIntervalSince(prev.at)
            down = MachineMath.rate(from: prev.down, to: counters.down, seconds: dt)
            up = MachineMath.rate(from: prev.up, to: counters.up, seconds: dt)
        }
        previousNet = (counters.down, counters.up, now)
        return NetworkSample(downBytesPerSec: down, upBytesPerSec: up, totalDownBytes: counters.down, totalUpBytes: counters.up)
    }

    /// Soma dos contadores de 64 bits (`if_data64`) das interfaces físicas via socket de roteamento.
    static func networkCounters() -> (down: UInt64, up: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var down: UInt64 = 0
        var up: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let header = MemoryLayout<if_msghdr>.size
            while offset + header <= length {
                let h = base.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
                let len = Int(h.ifm_msglen)
                guard len > 0, offset + len <= length else { break }
                if Int32(h.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = base.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil, MachineMath.includesInterface(Self.string(name)) {
                        down &+= info.ifm_data.ifi_ibytes
                        up &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += len
            }
        }
        return (down, up)
    }

    // MARK: Processos

    private func readProcesses(now: Date) -> [AppUsage] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard n > 0 else { return [] }
        let wallNanos = previousProcAt.map { UInt64(max(0, now.timeIntervalSince($0)) * 1_000_000_000) } ?? 0
        var current: [Int32: UInt64] = [:]
        struct Row { var pid: Int32; var cpu: Double; var mem: UInt64 }
        var rows: [Row] = []
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }  // processo de outro usuário/sem permissão: fica de fora
            let ticks = ri.ri_user_time &+ ri.ri_system_time
            let nanos = ticks &* timebase.numer / timebase.denom
            current[pid] = nanos
            var cpu = 0.0
            if let prev = previousProc[pid] { cpu = MachineMath.cpuPercent(cpuNanos: nanos, previous: prev, wallNanos: wallNanos) }
            rows.append(Row(pid: pid, cpu: cpu, mem: ri.ri_phys_footprint))
        }
        previousProc = current
        previousProcAt = now
        pathCache = pathCache.filter { current[$0.key] != nil }

        // Só resolve nome/caminho dos candidatos ao topo (centenas de `proc_pidpath` por tick seriam desperdício).
        let wanted = Set(rows.sorted { $0.cpu > $1.cpu }.prefix(40).map(\.pid)).union(rows.sorted { $0.mem > $1.mem }.prefix(40).map(\.pid))
        var processes: [(name: String, app: String?, cpu: Double, memory: UInt64)] = []
        var rest = (cpu: 0.0, mem: UInt64(0))
        for row in rows {
            guard wanted.contains(row.pid) else { rest.cpu += row.cpu; rest.mem += row.mem; continue }
            let path = pathCache[row.pid] ?? Self.path(of: row.pid)
            pathCache[row.pid] = path
            let app = MachineMath.appName(path: path)
            let name = app ?? URL(fileURLWithPath: path).lastPathComponent
            processes.append((name.isEmpty ? "pid \(row.pid)" : name, app, row.cpu, row.mem))
        }
        return MachineMath.group(processes)
    }

    static func string(_ buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func path(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if len > 0 { return Self.string(buffer) }
        var name = [CChar](repeating: 0, count: 64)
        if proc_name(pid, &name, UInt32(name.count)) > 0 { return Self.string(name) }
        return ""
    }
}
