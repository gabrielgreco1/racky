import AppKit
import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

// O que os computadores terminados deixaram no Mac (o `work/` do run): a seção "Left on disk" da página Computers, Keep / Delete now e
// a varredura que apaga o que venceu (a escolha de cada run fica no `box.json`; ver `RunLeftovers`).

extension LeftoversPolicy {
    /// Texto do botão do card e do menu.
    var labelKey: LocalizedStringKey {
        switch self {
        case .keep: "Keep files"
        case .whenDone: "Delete when done"
        case .days7: "Delete in 7 days"
        case .days30: "Delete in 30 days"
        }
    }

    var label: String {
        switch self {
        case .keep: String(localized: "Keep files", bundle: .module)
        case .whenDone: String(localized: "Delete when done", bundle: .module)
        case .days7: String(localized: "Delete in 7 days", bundle: .module)
        case .days30: String(localized: "Delete in 30 days", bundle: .module)
        }
    }
}

extension RunLeftover {
    /// `Deletes in 5 days`, `Deletes soon`, `Kept` ou, num run de antes da escolha, `No deadline`.
    func status(now: Date = Date()) -> String {
        guard let policy else { return String(localized: "No deadline", bundle: .module) }
        guard policy != .keep, let due else { return String(localized: "Kept", bundle: .module) }
        let days = Int(ceil(due.timeIntervalSince(now) / 86_400))
        if days <= 0 { return String(localized: "Deletes soon", bundle: .module) }
        return days == 1 ? String(localized: "Deletes tomorrow", bundle: .module) : String(localized: "Deletes in \(days) days", bundle: .module)
    }

    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

extension ComputersController {
    /// Relê os runs terminados fora da main (medir pastas grandes leva segundos).
    func refreshLeftovers() async {
        guard let orchestrator, !leftoversLoading else { return }
        leftoversLoading = true
        defer { leftoversLoading = false }
        let root = orchestrator.runsRoot
        let active = await orchestrator.scheduler.activeRunRoots()
        // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
        leftovers = await Task.detached(priority: .utility) { RunLeftovers.list(runsRoot: root, active: active) }.value
    }

    /// Apaga o que venceu agora e a cada 10 min (quem escolheu "Delete when done" espera no máximo isso).
    func startLeftoversSweep() {
        guard let orchestrator else { return }
        let root = orchestrator.runsRoot
        Task { [weak self] in
            while !Task.isCancelled {
                let active = await orchestrator.scheduler.activeRunRoots()
                // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
                let freed = await Task.detached(priority: .utility) { RunLeftovers.sweep(runsRoot: root, active: active) }.value
                if freed > 0 { self?.log.info("deleted \(freed) bytes left by finished computers") }
                await self?.refreshLeftovers()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    public func registerLeftovers(in registry: ActionRegistry) throws {
        func run(_ arg: ActionArgument, _ id: ActionID) throws -> RunFolder {
            guard let orchestrator, let key = arg.value, let run = RunLeftovers.run(key: key, runsRoot: orchestrator.runsRoot) else {
                throw ActionError.failed(id, message: String(localized: "That run is gone.", bundle: .module))
            }
            return run
        }
        try registry.register(.computerKeepLeftovers) { [unowned self] arg in
            let folder = try run(arg, .computerKeepLeftovers)
            RunLeftovers.keep(folder)
            await refreshLeftovers()
            return arg.value
        }
        try registry.register(.computersLeftoversShowAll) { [unowned self] _ in
            leftoversExpanded.toggle()
            return leftoversExpanded ? "all" : "top"
        }
        try registry.register(.computerCleanAllLeftovers) { [unowned self] _ in
            guard let orchestrator else { throw ActionError.failed(.computerCleanAllLeftovers, message: "computers aren't running") }
            let root = orchestrator.runsRoot
            let active = await orchestrator.scheduler.activeRunRoots()
            // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
            let freed = await Task.detached(priority: .utility) { RunLeftovers.cleanAll(runsRoot: root, active: active) }.value
            onLeftoversFreed(freed)
            await refreshLeftovers()
            return "\(freed)"
        }
        try registry.register(.computerDeleteLeftovers) { [unowned self] arg in
            let folder = try run(arg, .computerDeleteLeftovers)
            // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
            let freed = await Task.detached(priority: .utility) { RunLeftovers.delete(folder) }.value
            onLeftoversFreed(freed)
            await refreshLeftovers()
            return "\(freed)"
        }
    }
}

/// "Left on this Mac": o que os computadores terminados deixaram, os 4 maiores (ou todos), com a sessão, uma barra de tamanho, o prazo e
/// Keep / Delete; no topo o total e "Delete all" (menos os marcados Keep).
struct LeftoversSection: View {
    let controller: ComputersController
    /// As colunas que cabem: com o painel direito aberto, sessão e barra saem antes de cortar o nome.
    var columns = ComputersColumns.all
    static let preview = 4

    var body: some View {
        let items = controller.leftovers
        if !items.isEmpty {
            let shown = controller.leftoversExpanded ? items : Array(items.prefix(Self.preview))
            let largest = max(1, items.map(\.bytes).max() ?? 1)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Text("Left on this Mac", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
                    Spacer(minLength: DS.Space.s2)
                    Text(verbatim: String(
                        localized: "\(ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.bytes }, countStyle: .file)) in \(items.count) finished runs",
                        bundle: .module))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    DSButton(.computerCleanAllLeftovers, id: .computersLeftoversCleanAll, "Delete all", variant: .ghost, size: .xs)
                }
                .padding(.horizontal, DS.Space.s0_5)
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        row(item, largest: largest)
                            .overlay(alignment: .top) { if index > 0 { DS.Color.border.opacity(0.6).frame(height: DSMetrics.hairline) } }
                    }
                    if items.count > Self.preview {
                        ActionButton(.computersLeftoversShowAll, id: .computersLeftoversShowAll) {
                            HStack {
                                Text(controller.leftoversExpanded ? "Show the largest" : "Show all \(items.count)", bundle: .module)
                                    .dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                                Spacer(minLength: 0)
                                Text("largest first", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                            }
                            .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) { DS.Color.border.frame(height: DSMetrics.hairline) }
                    }
                }
                .cloudTile()
            }
            .a11y(.computersLeftovers, kind: "list", value: "\(items.count)")
        }
    }

    private func row(_ item: RunLeftover, largest: Int64) -> some View {
        let status = item.status()
        let soon = item.policy != nil && item.policy != .keep
        return HStack(spacing: DS.Space.s3) {
            Text(verbatim: item.computer).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: ComputersMetrics.colNameMin, maxWidth: .infinity, alignment: .leading)
            if columns.shows(.session) {
                Text(verbatim: item.session ?? "—").dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    .frame(width: ComputersMetrics.colSession, alignment: .leading)
            }
            if columns.shows(.age) {
                HStack(spacing: DS.Space.s2) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Color.secondary)
                            Capsule().fill(DS.Color.textQuaternary)
                                .frame(width: max(CloudMetrics.barHeight, proxy.size.width * CGFloat(item.bytes) / CGFloat(largest)))
                        }
                    }
                    .frame(height: CloudMetrics.barHeight)
                    Text(verbatim: item.size).dsFont(DS.Font.small).monospacedDigit().foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        .frame(width: ComputersMetrics.leftoversSize, alignment: .trailing)
                }
                .frame(width: ComputersMetrics.colMode + ComputersMetrics.leftoversSize)
            } else {
                Text(verbatim: item.size).dsFont(DS.Font.small).monospacedDigit().foregroundStyle(DS.Color.textSecondary)
            }
            Text(verbatim: status).dsFont(DS.Font.small).foregroundStyle(soon ? DS.Color.warning : DS.Color.textTertiary).lineLimit(1)
                .frame(width: ComputersMetrics.colState, alignment: .leading)
            HStack(spacing: DS.Space.s1) {
                if item.policy != .keep {
                    DSButton(.computerKeepLeftovers, id: .computersLeftoversRowKeep(item.key), "Keep", variant: .ghost, size: .xs, argument: .select(item.key))
                }
                DSButton(.computerDeleteLeftovers, id: .computersLeftoversRowDelete(item.key), "Delete", variant: .ghost, size: .xs, argument: .select(item.key))
            }
            .frame(width: ComputersMetrics.leftoversActions, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: ComputersMetrics.leftoversRow)
        .a11y(.computersLeftoversRow(item.key), kind: "row", label: item.computer, value: status)
    }
}
