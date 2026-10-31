import RackyPlatform
import RackyProtocol
import RackyTerminalCore
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Uma sessão de PTY: processo (grupo próprio), ring, rastreador de bytes, emulador headless, cold log e clientes anexados.
///
/// O I/O do PTY é dirigido por `DispatchSource` na fila serial `queue` (nunca no pool cooperativo nem no main).
/// O parse do emulador roda na fila dele (`HeadlessEmulatorHost`); o stream para os clientes não espera por ele.
// SAFETY: todo estado mutável é confinado à fila serial `queue`; os campos `let` são imutáveis e `Sendable`.
final class PTYSession: @unchecked Sendable {
    static let frameBytes = ProtocolLimits.coalesceBytes
    static let maxPendingInput = 4 << 20
    static let idleAfter: DispatchTimeInterval = .seconds(2)

    let id: SessionID
    private let request: CreateRequest
    private let queue: DispatchQueue
    private let emulator: HeadlessEmulatorHost
    private let coldLog: ColdLog?
    private let hub: EventHub
    /// Número de clientes anexados, legível de qualquer thread (decide quem responde a consultas, AR-105).
    // LOCK: contador simples, sem I/O sob o lock.
    private let attachedCount = Mutex(0)

    // Estado confinado a `queue`.
    private var ring: RingBuffer
    private var tracker = VTTracker()
    private var index = ReplayIndex()
    private var master: Int32
    private let pid: pid_t
    private var state = SessionState.running
    private var exit: ExitInfo?
    private var cwd: String
    private var title: String?
    private let startedAt = Date()
    private var lastOutputAt: Date?
    private var inputBytes = InputByteCounts()
    private var attached: [ObjectIdentifier: ClientOutbox] = [:]
    private var pending: [UInt8] = []
    private var pendingStartSeq: UInt64 = 0
    private var cooldownActive = false
    private var idleArmed = false
    private var idleEmitted = true
    private var readSource: (any DispatchSourceRead)?
    private var readSuspended = false
    private var writeSource: (any DispatchSourceWrite)?
    private var writeSourceRunning = false
    private var processSource: (any DispatchSourceProcess)?
    private var pendingInput: [UInt8] = []
    private var killRequested = false
    private var currentCols: UInt16
    private var currentRows: UInt16
    private var sourcesAlive = 0
    private var masterReleased = false

    var pgid: pid_t { pid }

    init(request: CreateRequest, spawned: SpawnedPTY, coldLog: ColdLog?, hub: EventHub) {
        id = request.sessionID
        self.request = request
        self.hub = hub
        self.coldLog = coldLog
        master = spawned.master
        pid = spawned.pid
        cwd = request.cwd
        ring = RingBuffer(capacity: request.ringBytes)
        queue = DispatchQueue(label: "app.racky.ptyd.session.\(request.sessionID)")
        currentCols = request.cols
        currentRows = request.rows
        let box = WeakSession()
        emulator = HeadlessEmulatorHost(
            cols: Int(request.cols), rows: Int(request.rows),
            allowReplies: { (box.session?.attachedCount.withLock { $0 } ?? 1) == 0 },
            reply: { bytes in box.session?.writeInput(bytes, origin: .terminalReply) },
            onDrained: { box.session?.emulatorDrained() })
        box.session = self
        coldLog?.update(pid: spawned.pid, exit: nil)
    }

    /// Liga as fontes de leitura e de término. Chamado uma vez, logo depois do `init`.
    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            source.setEventHandler { [self] in masterReadable() }
            source.setCancelHandler { [self] in sourceCancelled() }
            sourcesAlive += 1
            readSource = source
            source.resume()
            let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            process.setEventHandler { [self] in processExited() }
            processSource = process
            process.resume()
        }
    }

    // MARK: Acesso de fora (async, sempre via fila)

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    func summary() async -> SessionSummary { await onQueue { self.makeSummary() } }
    var isRunning: Bool { get async { await onQueue { self.state == .running } } }

    private func makeSummary() -> SessionSummary {
        SessionSummary(
            sessionID: id, pid: pid, pgid: pid, argv0: request.argv.first ?? "", cwd: cwd, state: state, startedAt: startedAt,
            exit: exit, lastOutputAt: lastOutputAt, title: title, endSeq: ring.endSeq, inputBytesByOrigin: inputBytes)
    }

    func textSnapshot(lines: Int) async -> String {
        await emulator.textSnapshot(lines: lines)
    }

    func emulatorModes() async -> (alt: Bool, bracketedPaste: Bool, appCursor: Bool) {
        await emulator.publicModes()
    }

    // MARK: Input, resize, sinais

    func writeInput(_ bytes: [UInt8], origin: InputOrigin) {
        queue.async { [self] in
            guard state == .running, master >= 0 else { return }
            inputBytes.add(bytes.count, origin: origin)
            guard pendingInput.count + bytes.count <= Self.maxPendingInput else { return }
            pendingInput.append(contentsOf: bytes)
            drainInput()
        }
    }

    private func drainInput() {
        while !pendingInput.isEmpty, master >= 0 {
            let count = pendingInput.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if count > 0 {
                pendingInput.removeFirst(count)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                armWriteSource()
                return
            } else {
                pendingInput.removeAll()
                return
            }
        }
        disarmWriteSource()
    }

    private func armWriteSource() {
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
            source.setEventHandler { [self] in drainInput() }
            source.setCancelHandler { [self] in sourceCancelled() }
            sourcesAlive += 1
            writeSource = source
        }
        if !writeSourceRunning {
            writeSourceRunning = true
            writeSource?.resume()
        }
    }

    private func disarmWriteSource() {
        if writeSourceRunning {
            writeSourceRunning = false
            writeSource?.suspend()
        }
    }

    func resize(cols: UInt16, rows: UInt16) async -> Result<Void, DaemonError> {
        await onQueue {
            guard self.state == .running else { return .failure(DaemonError(.sessionExited, "session exited")) }
            self.applySize(cols: cols, rows: rows)
            return .success(())
        }
    }

    private func applySize(cols: UInt16, rows: UInt16, ptyOnly: Bool = false) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        if master >= 0 { _ = ioctl(master, TIOCSWINSZ, &size) }
        if !ptyOnly {
            currentCols = cols
            currentRows = rows
            emulator.resize(cols: Int(cols), rows: Int(rows))
        }
    }

    func signal(_ number: Int32, target: SignalTarget) async -> Result<Void, DaemonError> {
        await onQueue {
            guard self.state == .running else { return .failure(DaemonError(.sessionExited, "session exited")) }
            var group = self.pid
            if target == .foreground, self.master >= 0 {
                let foreground = tcgetpgrp(self.master)
                if foreground > 0 { group = foreground }
            }
            killpg(group, number)
            return .success(())
        }
    }

    func kill(mode: KillMode) async -> Result<Void, DaemonError> {
        await onQueue {
            guard self.state == .running else { return .failure(DaemonError(.sessionExited, "session exited")) }
            self.killRequested = true
            switch mode {
            case .force:
                killpg(self.pid, SIGKILL)
            case .graceful:
                killpg(self.pid, SIGHUP)
                killpg(self.pid, SIGTERM)
                self.queue.asyncAfter(deadline: .now() + .seconds(5)) { [self] in stillAliveCheck() }
            }
            return .success(())
        }
    }

    private func stillAliveCheck() {
        // O grupo ainda tem algum membro vivo (o líder ou filhos que ignoraram HUP/TERM).
        if killpg(pid, 0) == 0 { emit(.stillAlive) }
    }

    // MARK: Leitura do PTY e ingestão

    private func masterReadable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(master, &buffer, buffer.count)
        if count > 0 {
            ingest(Array(buffer[0 ..< count]))
            if emulator.pendingBytes > HeadlessEmulatorHost.highWater, !readSuspended {
                readSuspended = true
                readSource?.suspend()
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF/EIO: ninguém mais segura o slave. A saída do processo fecha a sessão.
            readSource?.cancel()
            readSource = nil
        }
    }

    private func emulatorDrained() {
        queue.async { [self] in
            if readSuspended, emulator.pendingBytes < HeadlessEmulatorHost.lowWater {
                readSuspended = false
                readSource?.resume()
            }
        }
    }

    private func ingest(_ bytes: [UInt8]) {
        let start = ring.endSeq
        var marks: [EmulatorMark] = []
        if index.wantsCheckpoint(at: start, parserIsNormal: tracker.isNormal) {
            index.recordCheckpoint(seq: start, state: tracker.state)
            marks.append(EmulatorMark(offset: 0, key: start))
        }
        tracker.feed(bytes, startSeq: start)
        for cut in tracker.takeCuts() {
            index.recordCut(cut)
            marks.append(EmulatorMark(offset: cut.seq >= start ? Int(cut.seq - start) : 0, key: cut.seq))
        }
        for event in tracker.takeEvents() { handle(event) }
        ring.append(bytes)
        index.prune(ringStart: ring.startSeq)
        emulator.pruneCursors(below: ring.startSeq)
        emulator.feed(bytes, marks: marks)
        coldLog?.append(bytes)
        lastOutputAt = Date()
        idleEmitted = false
        armIdleTimer()
        if pending.isEmpty { pendingStartSeq = start }
        pending.append(contentsOf: bytes)
        scheduleFlush()
    }

    private func handle(_ event: TrackerEvent) {
        switch event {
        case .title(let text):
            title = text
            emit(.title(TitleEvent(text: text)))
        case .cwd(let path):
            cwd = path
            emit(.cwd(CwdEvent(path: path)))
        case .prompt(let phase, let status):
            if let mapped = PromptPhase(rawValue: String(phase)) { emit(.prompt(PromptEvent(phase: mapped, exitStatus: status))) }
        case .bell: emit(.bell)
        case .altScreen(let on): emit(.altScreen(AltScreenEvent(on: on)))
        case .modes(let bracketedPaste, let appCursor, let mouse):
            emit(.modes(ModesEvent(bracketedPaste: bracketedPaste, appCursor: appCursor, mouse: mouse)))
        }
    }

    private func emit(_ payload: EventPayload) {
        hub.dispatch(DaemonEvent(sessionID: id, payload: payload), attached: Array(attached.values))
    }

    // MARK: Coalescência (até 16 ms ou 64 KiB por frame)

    private func scheduleFlush() {
        if pending.count >= Self.frameBytes {
            flushPending()
        } else if !cooldownActive {
            // Borda de subida: o primeiro byte depois de silêncio sai na hora (latência de eco); o resto agrupa.
            flushPending()
            cooldownActive = true
            queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
                cooldownActive = false
                flushPending()
            }
        }
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        var offset = 0
        while offset < pending.count {
            let take = min(Self.frameBytes, pending.count - offset)
            let frame = Frame.output(OutputFrame(sessionID: id, seq: pendingStartSeq + UInt64(offset), bytes: Data(pending[offset ..< offset + take])))
            for outbox in attached.values { outbox.enqueue(frame) }
            offset += take
        }
        pending.removeAll(keepingCapacity: true)
    }

    private func armIdleTimer() {
        guard !idleArmed else { return }
        idleArmed = true
        queue.asyncAfter(deadline: .now() + Self.idleAfter) { [self] in
            idleArmed = false
            guard state == .running, !idleEmitted, let last = lastOutputAt else { return }
            if Date().timeIntervalSince(last) >= 1.9 {
                idleEmitted = true
                emit(.idle(IdleEvent(since: last)))
            } else {
                armIdleTimer()
            }
        }
    }

    // MARK: Término do processo

    private func processExited() {
        guard state == .running else { return }
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        guard reaped == pid else { return }
        // Drena o que o filho escreveu antes de sair.
        var buffer = [UInt8](repeating: 0, count: 65536)
        while master >= 0 {
            let count = read(master, &buffer, buffer.count)
            if count > 0 { ingest(Array(buffer[0 ..< count])) } else { break }
        }
        flushPending()
        var info = ExitInfo(at: Date())
        if status & 0x7f == 0 {
            info.code = (status >> 8) & 0xff
        } else {
            info.signal = status & 0x7f
        }
        exit = info
        state = .exited
        if readSource != nil {
            if readSuspended { readSource?.resume() }
            readSource?.cancel()
            readSource = nil
        }
        disarmWriteSource()
        writeSource?.resume()  // fonte suspensa precisa ser retomada antes do cancel
        writeSource?.cancel()
        writeSource = nil
        processSource?.cancel()
        processSource = nil
        masterReleased = true
        closeMasterIfIdle()
        pendingInput.removeAll()
        coldLog?.update(pid: pid, exit: info)
        emit(.exit(info))
    }

    private func sourceCancelled() {
        sourcesAlive -= 1
        closeMasterIfIdle()
    }

    /// O fd só fecha depois que todas as fontes GCD que o usam foram canceladas.
    private func closeMasterIfIdle() {
        guard masterReleased, sourcesAlive == 0, master >= 0 else { return }
        close(master)
        master = -1
    }

    // MARK: Attach

    private enum AttachOutcome {
        case done(resumed: Bool)
        case needEmulator
    }

    /// Anexa `outbox`. A resposta `attachSnapshot` e os bytes do replay vão como `ReplayJob` na fila do cliente.
    func attach(_ outbox: ClientOutbox, request attach: AttachRequest, requestID: RequestID) async -> Result<Void, DaemonError> {
        let prepared: (sameSize: Bool, running: Bool) = await onQueue {
            let running = self.state == .running
            let same = self.currentCols == attach.cols && self.currentRows == attach.rows
            if running, !same { self.applySize(cols: attach.cols, rows: attach.rows) }
            return (same, running)
        }
        for attempt in 0 ..< 4 {
            let allowMissing = attempt == 3
            let outcome: AttachOutcome = await onQueue {
                self.tryAttach(outbox, attach, requestID: requestID, allowMissingCursor: allowMissing)
            }
            switch outcome {
            case .done(let resumed):
                if prepared.running, prepared.sameSize, !resumed, attach.cols > 1 { forceRedraw() }
                return .success(())
            case .needEmulator:
                await emulator.barrier()
            }
        }
        return .failure(DaemonError(.internal, "attach did not converge"))
    }

    private func tryAttach(_ outbox: ClientOutbox, _ attach: AttachRequest, requestID: RequestID, allowMissingCursor: Bool) -> AttachOutcome {
        flushPending()
        let end = ring.endSeq
        let start: UInt64
        var preamble: [UInt8] = []
        var isResume = false
        if case .sinceSeq(let since) = attach.mode, since >= ring.startSeq, since <= end {
            start = since
            isResume = true
        } else {
            let point = index.choose(ringStart: ring.startSeq)
            if let point {
                let cursor = emulator.cursor(forKey: point.seq)
                if cursor == nil, !allowMissingCursor { return .needEmulator }
                start = point.seq
                preamble = (point.kind == .checkpoint ? [0x1b, 0x63] : []) + point.state.preamble(cursor: cursor)
            } else {
                start = ring.startSeq
                preamble = [0x1b, 0x63]
            }
        }
        let snapshot = AttachSnapshot(sessionID: id, startSeq: start, endSeq: end, modesPreamble: Data(preamble), resumed: isResume)
        let key = ObjectIdentifier(outbox)
        if attached[key] == nil { attachedCount.withLock { $0 += 1 } }
        attached[key] = outbox
        outbox.beginReplay(ReplayJob(reply: .attachSnapshot(id: requestID, snapshot), sessionID: id, startSeq: start, bytes: ring.read(from: start, to: end)))
        return .done(resumed: isResume)
    }

    /// `cols-1` e, 50 ms depois, `cols`: dois `SIGWINCH` que fazem os TUIs redesenharem. Só o PTY muda de largura;
    /// o emulador headless mantém o tamanho real para não reflowar o conteúdo.
    private func forceRedraw() {
        queue.async { [self] in
            guard state == .running, currentCols > 1 else { return }
            let cols = currentCols
            let rows = currentRows
            applySize(cols: cols - 1, rows: rows, ptyOnly: true)
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                guard state == .running else { return }
                // O tamanho de agora, não o de 50 ms atrás: um resize nesse meio-tempo (aba abrindo, split) era desfeito e o PTY
                // voltava à largura antiga, com o TUI desenhando na largura errada até o próximo resize.
                applySize(cols: currentCols, rows: currentRows, ptyOnly: true)
            }
        }
    }

    func detach(_ outbox: ClientOutbox) {
        queue.async { [self] in
            if attached.removeValue(forKey: ObjectIdentifier(outbox)) != nil { attachedCount.withLock { $0 -= 1 } }
            outbox.removeOutput(for: id)
        }
    }

    // MARK: Encerramento

    /// Remove ring e cold log (sessão encerrada ou daemon descartando); devolve os clientes que estavam anexados.
    func forget() async -> [ClientOutbox] {
        let outboxes: [ClientOutbox] = await onQueue {
            let all = Array(self.attached.values)
            self.attached.removeAll()
            self.attachedCount.withLock { $0 = 0 }
            return all
        }
        coldLog?.remove()
        return outboxes
    }

    func attachedOutboxes() async -> [ClientOutbox] { await onQueue { Array(self.attached.values) } }

    func announceGone() async {
        let outboxes = await attachedOutboxes()
        hub.dispatch(DaemonEvent(sessionID: id, payload: .sessionGone), attached: outboxes)
    }

    func finishColdLog() async { await coldLog?.finish() }
}

/// Referência fraca para fechar o ciclo emulador → sessão sem retenção.
// SAFETY: `session` só é escrito uma vez, no `init` da sessão, antes de o emulador receber dados.
private final class WeakSession: @unchecked Sendable {
    weak var session: PTYSession?
}
