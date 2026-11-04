import RackyCore
import RackyProtocol
import AppKit
import Foundation

extension AgentsController {
    /// `select(<nome>)` ou, sem argumento, o agente aberto.
    private func target(_ arg: ActionArgument, _ id: ActionID) throws -> String {
        if arg.kind == .select, let raw = arg.value, !raw.isEmpty { return raw }
        guard let selectedName else { throw ActionError.failed(id, message: String(localized: "Open an agent first.", bundle: .module)) }
        return selectedName
    }

    /// O texto do argumento: `set(<texto>)`, ou `select(<valor>)` quando o controle é um segmento ou um combobox.
    private func text(_ arg: ActionArgument, _ id: ActionID) throws -> String {
        guard arg.kind == .set || arg.kind == .select, let v = arg.value else { throw ActionError.failed(id, message: "expected set(<text>)") }
        return v
    }

    /// Ações do agente aberto (03 §24.4). O argumento `set(<campo>=<valor>)`, `select(<id>)`… é o mesmo que a UI manda.
    func register(in registry: ActionRegistry) throws {
        let needsAgent: ActionRegistry.Enablement = { [unowned self] in
            selectedName == nil ? .disabled(reason: String(localized: "Open an agent first.", bundle: .module)) : .enabled
        }
        try registry.register(.agentsOpen) { [unowned self] arg in
            let name = try target(arg, .agentsOpen)
            try await open(name)
            return name
        }
        try registry.register(.agentsNew) { [unowned self] arg in
            let mode = arg.value.flatMap(AgentCreateMode.init(rawValue:)) ?? .scratch
            openCreate(.agent, mode)
            return mode.rawValue
        }
        try registry.register(.agentsNewSkill) { [unowned self] arg in
            let mode = arg.value.flatMap(AgentCreateMode.init(rawValue:)) ?? .scratch
            openCreate(.skill, mode)
            return mode.rawValue
        }
        try registry.register(.agentsSetField, enablement: needsAgent) { [unowned self] arg in
            let raw = try text(arg, .agentsSetField)
            guard let eq = raw.firstIndex(of: "=") else { throw ActionError.failed(.agentsSetField, message: "expected set(<field>=<value>)") }
            let name = try target(.press, .agentsSetField)
            try setField(name, field: String(raw[..<eq]), value: String(raw[raw.index(after: eq)...]))
            return raw
        }
        try registry.register(.agentsDelete, enablement: needsAgent) { [unowned self] arg in
            // `press` só pergunta; `select(<nome>)` apaga de verdade.
            guard arg.kind == .select, let name = arg.value, !name.isEmpty else {
                confirmingDelete = selectedName
                return "confirm"
            }
            try delete(name)
            return name
        }
        try registry.register(.agentsNewSession) { [unowned self] arg in
            let name = try target(arg, .agentsNewSession)
            startSession(name)
            return name
        }
        try registry.register(.agentsRegenerateAvatar, enablement: needsAgent) { [unowned self] arg in
            let name = try target(arg, .agentsRegenerateAvatar)
            try regenerateAvatar(name)
            return "\(agent(name)?.avatar.variant ?? 0)"
        }
        try registry.register(.agentsSetPhoto, enablement: needsAgent) { [unowned self] arg in
            let name = try target(.press, .agentsSetPhoto)
            let url: URL
            if arg.kind == .select, let path = arg.value, !path.isEmpty {
                url = URL(fileURLWithPath: path)
            } else if let picked = await pickFile(["png", "jpg", "jpeg", "heic", "webp"]) {
                url = picked
            } else {
                return "cancelled"
            }
            do { try setPhoto(name, from: url) } catch AgentStoreError.photoTooLarge {
                throw ActionError.failed(.agentsSetPhoto, message: String(localized: "That photo is over 5 MB.", bundle: .module))
            } catch AgentStoreError.unsupportedPhoto {
                throw ActionError.failed(.agentsSetPhoto, message: String(localized: "Use a PNG, JPEG, HEIC or WebP photo.", bundle: .module))
            }
            return url.lastPathComponent
        }
        try registry.register(.agentsAddAttachment, enablement: needsAgent) { [unowned self] arg in
            let name = try target(.press, .agentsAddAttachment)
            var parts = (arg.kind == .set || arg.kind == .select ? arg.value ?? "" : "").split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if arg.kind != .set, arg.kind != .select {
                guard let picked = await pickFile([]) else { return "cancelled" }
                parts = ["file", picked.lastPathComponent, picked.path]
            }
            guard parts.count == 3, let kind = AgentAttachmentKind(rawValue: parts[0]), !parts[2].isEmpty else {
                throw ActionError.failed(.agentsAddAttachment, message: "expected set(<kind>|<title>|<reference>)")
            }
            try addAttachment(name, kind: kind, title: parts[1], reference: parts[2])
            return parts[2]
        }
        try registry.register(.agentsRemoveAttachment, enablement: needsAgent) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) else { throw ActionError.failed(.agentsRemoveAttachment, message: "expected select(<id>)") }
            try removeAttachment(try target(.press, .agentsRemoveAttachment), id: id)
            return raw
        }
        try registry.register(.agentsSetVariable, enablement: needsAgent) { [unowned self] arg in
            let raw = try text(arg, .agentsSetVariable)
            guard let eq = raw.firstIndex(of: "=") else { throw ActionError.failed(.agentsSetVariable, message: "expected set(<ENV>=<secret>)") }
            try setVariable(try target(.press, .agentsSetVariable), envName: String(raw[..<eq]).trimmingCharacters(in: .whitespaces), secretName: String(raw[raw.index(after: eq)...]))
            return String(raw[..<eq])
        }
        try registry.register(.agentsRemoveVariable, enablement: needsAgent) { [unowned self] arg in
            guard arg.kind == .select, let env = arg.value else { throw ActionError.failed(.agentsRemoveVariable, message: "expected select(<ENV>)") }
            try removeVariable(try target(.press, .agentsRemoveVariable), envName: env)
            return env
        }
        try registry.register(.agentsAddSite, enablement: needsAgent) { [unowned self] arg in
            let host = try text(arg, .agentsAddSite)
            try addSite(try target(.press, .agentsAddSite), host: host)
            return host
        }
        try registry.register(.agentsRemoveSite, enablement: needsAgent) { [unowned self] arg in
            guard arg.kind == .select, let host = arg.value else { throw ActionError.failed(.agentsRemoveSite, message: "expected select(<host>)") }
            try removeSite(try target(.press, .agentsRemoveSite), host: host)
            return host
        }
        try registry.register(.agentsMemoryAdd, enablement: needsAgent) { [unowned self] arg in
            let parts = try text(arg, .agentsMemoryAdd).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            try await addMemory(title: parts.first ?? "", body: parts.count > 1 ? parts[1] : "")
            return "\(memoryEntries.count)"
        }
        try registry.register(.agentsMemoryEdit, enablement: needsAgent) { [unowned self] arg in
            let parts = try text(arg, .agentsMemoryEdit).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let id = Int64(parts[0]) else { throw ActionError.failed(.agentsMemoryEdit, message: "expected set(<id>|<title>|<text>)") }
            try await editMemory(id: id, title: parts[1], body: parts[2])
            return parts[0]
        }
        try registry.register(.agentsMemoryDelete, enablement: needsAgent) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let id = Int64(raw) else { throw ActionError.failed(.agentsMemoryDelete, message: "expected select(<id>)") }
            try await deleteMemory(id: id)
            return raw
        }
        try registry.register(.agentsMemorySearch, enablement: needsAgent) { [unowned self] arg in
            await search(try text(arg, .agentsMemorySearch))
            return "\(visibleMemory.count)"
        }
        try registry.register(.agentsAddToSession) { [unowned self] arg in
            guard arg.kind == .select || arg.kind == .set, let raw = arg.value, !raw.isEmpty else {
                throw ActionError.failed(.agentsAddToSession, message: "expected select(<name>) or set(<name>|<session>)")
            }
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            try await addToSession(parts[0], parts.count > 1 ? UUID(uuidString: parts[1]) : nil)
            return parts[0]
        }
        try registry.register(.agentsInsertInPrompt) { [unowned self] arg in
            let name = try target(arg, .agentsInsertInPrompt)
            guard insertInComposer(name) else {
                throw ActionError.failed(.agentsInsertInPrompt, message: String(localized: "Open the new session composer first.", bundle: .module))
            }
            return name
        }
    }
}
