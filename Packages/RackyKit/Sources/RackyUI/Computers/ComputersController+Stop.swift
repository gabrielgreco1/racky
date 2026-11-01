import RackyCore
import RackyProtocol
import Foundation

extension ComputersController {
    /// `computer.stop` (03 §16.3): confirma e remove o computador (o run folder e o perfil ficam). Entra pela linha do popover da status bar.
    func registerStop(in registry: ActionRegistry) throws {
        try registry.register(
            .computerStop,
            enablement: { [unowned self] in
                model.rows.isEmpty ? .disabled(reason: String(localized: "No computers yet.", bundle: .module)) : .enabled
            }
        ) { [unowned self] arg in
            guard arg.kind == .select, let name = arg.value, let row = model.rows.first(where: { $0.id == name }) else {
                throw ActionError.failed(.computerStop, message: String(localized: "No such computer.", bundle: .module))
            }
            guard let overlays else { throw ActionError.failed(.computerStop, message: "Computers are not available") }
            pendingStop = name
            let dialog = ConfirmationModel.stopComputer(name: name, inUse: row.snapshot.state == .inUse)
            if overlays.present(.confirmation(dialog), from: nil) { return "confirming" }
            pendingStop = nil
            return "busy"
        }
        try registry.register(.dialogStopComputerCancel) { [unowned self] _ in
            pendingStop = nil
            overlays?.dismiss(.action)
            return nil
        }
        try registry.register(.dialogStopComputerConfirm) { [unowned self] _ in
            guard let name = pendingStop else { throw ActionError.failed(.dialogStopComputerConfirm, message: "Nothing to stop") }
            pendingStop = nil
            overlays?.dismiss(.action)
            guard let orchestrator else { throw ActionError.failed(.computerStop, message: "Computers are not available") }
            let stopped = await orchestrator.scheduler.archiveComputers(names: [name])
            model.setBatches(await orchestrator.batches())
            await model.refresh()
            return "stopped \(stopped.count)"
        }
    }
}

extension ConfirmationModel {
    /// `Stop "<computer>"?` (03 §16.3).
    static func stopComputer(name: String, inUse: Bool) -> ConfirmationModel {
        ConfirmationModel(
            name: "confirmStopComputer", rootID: .overlayConfirmStopComputer, title: String(localized: "Stop computer \"\(name)\"?", bundle: .module),
            message: inUse
                ? String(localized: "Claude Code is using it right now.", bundle: .module)
                : String(localized: "Claude Code keeps running on your Mac. The browser session is saved in the computer's profile.", bundle: .module),
            confirmTitle: "Stop Computer", confirmAction: .dialogStopComputerConfirm, confirmID: .overlayConfirmStopComputerConfirm,
            cancelAction: .dialogStopComputerCancel, cancelID: .overlayConfirmStopComputerCancel, destructive: true, symbol: "stop.circle")
    }
}
