import RackyCore
import RackyProtocol
import Foundation

extension SettingsModel {
    /// Registra as ações do Settings, de Agents e do `agent.openSettings` (03 §24.6). Cada controle da página dispara uma delas;
    /// `ctl ui action` usa as mesmas. Erros de validação voltam como `ActionError.failed` com a mensagem do campo.
    func registerActions(in registry: ActionRegistry) throws {
        func guarded(_ id: ActionID, _ body: () async throws -> String?) async throws -> String? {
            do { return try await body() } catch let error as SettingsError {
                switch error {
                case .invalid(let message): throw ActionError.failed(id, message: message)
                case .noStore: throw ActionError.failed(id, message: "The database isn't available.")
                }
            }
        }
        func flag(_ arg: ActionArgument, current: Bool) -> Bool {
            switch arg.value {
            case "on": true
            case "off": false
            default: !current
            }
        }
        func value(_ arg: ActionArgument, _ id: ActionID) throws -> String {
            guard let v = arg.value else { throw ActionError.failed(id, message: "expected a value") }
            return v
        }
        func provider(_ arg: ActionArgument, _ id: ActionID) throws -> TerminalProvider {
            guard let raw = arg.value, let p = TerminalProvider(rawValue: raw) else { throw ActionError.failed(id, message: "unknown agent") }
            return p
        }
        func uuid(_ arg: ActionArgument, _ id: ActionID) throws -> UUID {
            guard let raw = arg.value, let u = UUID(uuidString: raw) else { throw ActionError.failed(id, message: "expected a profile id") }
            return u
        }

        // Entrada e saída
        try registry.register(.appSettings) { [unowned self] _ in
            open()
            return section
        }
        try registry.register(.agentOpenSettings) { [unowned self] _ in
            open(section: "agents")
            return section
        }
        try registry.register(.settingsOpenSection) { [unowned self] arg in
            let id = try value(arg, .settingsOpenSection)
            guard select(id) else { throw ActionError.failed(.settingsOpenSection, message: "Unknown section \(id)") }
            open(section: id)  // fora de Settings (popover da status bar), abre a página já na seção
            return id
        }
        try registry.register(.settingsBack) { [unowned self] _ in
            close()
            return nil
        }

        // General
        func bool(_ id: ActionID, _ keyPath: WritableKeyPath<AppSettings.General, Bool>, name: String) throws {
            try registry.register(id) { [unowned self] arg in
                change(name) { $0.general[keyPath: keyPath] = flag(arg, current: $0.general[keyPath: keyPath]) }
                return settings.general[keyPath: keyPath] ? "on" : "off"
            }
        }
        try registry.register(
            .settingsGeneralAllowLoginItems,
            enablement: { [unowned self] in backgroundNeedsApproval ? .enabled : .disabled(reason: "Background agents are already allowed.") }
        ) { [unowned self] _ in
            openLoginItems()
            return nil
        }
        try bool(.settingsGeneralKeepAgentsRunning, \.keepAgentsRunning, name: "Keep agents running")
        try bool(.settingsGeneralResumeAgentsOnOpen, \.resumeAgentsOnOpen, name: "Resume agents on open")
        try bool(.settingsGeneralAskBeforeQuit, \.askBeforeQuit, name: "Ask before quitting")
        try bool(.settingsGeneralConfirmCloseTerminal, \.confirmCloseTerminal, name: "Confirm before closing a terminal")
        try bool(.settingsGeneralConfirmDeleteSession, \.confirmDeleteSession, name: "Confirm before deleting a session")

        try registry.register(.settingsGeneralBranchPrefix) { [unowned self] arg in
            guard let raw = arg.value, let mode = AppSettings.BranchPrefixMode(rawValue: raw) else {
                throw ActionError.failed(.settingsGeneralBranchPrefix, message: "expected gitUser, custom or none")
            }
            change("Branch prefix") { $0.general.branchPrefix = mode }
            if mode != .custom { clearError("general.branchPrefixCustom") }
            return mode.rawValue
        }
        try registry.register(
            .settingsGeneralBranchPrefixCustom,
            enablement: { [unowned self] in settings.general.branchPrefix == .custom ? .enabled : .disabled(reason: "Choose Custom to set a prefix.") }
        ) { [unowned self] arg in
            let text = try value(arg, .settingsGeneralBranchPrefixCustom)
            return try await guarded(.settingsGeneralBranchPrefixCustom) {
                switch SettingsValidation.branchPrefix(text) {
                case .failure(let error): throw fail("general.branchPrefixCustom", error)
                case .success(let prefix):
                    clearError("general.branchPrefixCustom")
                    change("Branch prefix") { $0.general.branchPrefixCustom = prefix }
                    return prefix
                }
            }
        }
        func folder(_ id: ActionID, _ keyPath: WritableKeyPath<AppSettings.General, String>, key: String, name: String) throws {
            try registry.register(id) { [unowned self] arg in
                let text = try value(arg, id)
                return try await guarded(id) {
                    switch SettingsValidation.folder(text) {
                    case .failure(let error): throw fail("general.\(key)", error)
                    case .success(let path):
                        clearError("general.\(key)")
                        change(name) { $0.general[keyPath: keyPath] = path }
                        return path
                    }
                }
            }
        }
        try folder(.settingsGeneralWorktreeFolder, \.worktreeFolder, key: "worktreeFolder", name: "Worktree folder")
        try folder(.settingsGeneralCleanSessionFolder, \.cleanSessionFolder, key: "cleanSessionFolder", name: "Clean session folder")
        try folder(.settingsGeneralProjectsFolder, \.projectsFolder, key: "projectsFolder", name: "Projects folder")
        try registry.register(.settingsPickPath) { [unowned self] arg in
            let which = try value(arg, .settingsPickPath)
            let (keyPath, key, name): (WritableKeyPath<AppSettings.General, String>, String, String) =
                switch which {
                case "worktreeFolder": (\.worktreeFolder, "worktreeFolder", "Worktree folder")
                case "cleanSessionFolder": (\.cleanSessionFolder, "cleanSessionFolder", "Clean session folder")
                case "projectsFolder": (\.projectsFolder, "projectsFolder", "Projects folder")
                default: throw ActionError.failed(.settingsPickPath, message: "unknown folder setting")
                }
            guard let path = await system.pickFolder(settings.general[keyPath: keyPath]) else { return "cancelled" }
            clearError("general.\(key)")
            change(name) { $0.general[keyPath: keyPath] = path }
            return path
        }
        try registry.register(.settingsResetConfirmations) { [unowned self] _ in
            change("confirmations") {
                $0.general.askBeforeQuit = true
                $0.general.confirmCloseTerminal = true
                $0.general.confirmDeleteSession = true
            }
            toasts?.show(kind: .success, title: String(localized: "Confirmations restored.", bundle: .module))
            return "restored"
        }
        // Storage: o que os computadores deixam, worktrees de sessões arquivadas e imagens antigas do computador.
        try registry.register(.settingsGeneralComputerLeftovers) { [unowned self] arg in
            guard let raw = arg.value, let policy = LeftoversPolicy(rawValue: raw) else {
                throw ActionError.failed(.settingsGeneralComputerLeftovers, message: "expected keep, whenDone, days7 or days30")
            }
            change("What computers leave behind") { $0.general.computerLeftovers = policy }
            return policy.rawValue
        }
        try bool(.settingsGeneralLeftoversOnCard, \.leftoversOnCard, name: "Choose on the approval card")
        func keepOrDelete(_ id: ActionID, _ keyPath: WritableKeyPath<AppSettings.General, AppSettings.KeepOrDelete>, name: String) throws {
            try registry.register(id) { [unowned self] arg in
                guard let raw = arg.value, let choice = AppSettings.KeepOrDelete(rawValue: raw) else {
                    throw ActionError.failed(id, message: "expected keep or delete")
                }
                change(name) { $0.general[keyPath: keyPath] = choice }
                return choice.rawValue
            }
        }
        try keepOrDelete(.settingsGeneralArchivedWorktrees, \.archivedWorktrees, name: "Worktrees of archived sessions")
        try keepOrDelete(.settingsGeneralOldComputerImages, \.oldComputerImages, name: "Old computer images")
        try registry.register(
            .settingsGeneralStorageCleanUp,
            enablement: { [unowned self] in storageMeasuring ? .disabled(reason: "Measuring…") : .enabled }
        ) { [unowned self] _ in
            let freed = await cleanUpStorage()
            let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            toasts?.show(kind: .success, title: freed > 0
                ? String(localized: "Freed \(size).", bundle: .module) : String(localized: "Nothing to clean up.", bundle: .module))
            return "\(freed)"
        }

        // Agents
        try registry.register(.settingsAgentsDefaultAgent) { [unowned self] arg in
            let p = try provider(arg, .settingsAgentsDefaultAgent)
            if p.isAgent, let info = agent(p), case .notInstalled = info.phase {
                throw ActionError.failed(.settingsAgentsDefaultAgent, message: "\(info.displayName) isn't installed.")
            }
            guard p.isAgent || p == .shell else { throw ActionError.failed(.settingsAgentsDefaultAgent, message: "unknown agent") }
            change("Default agent") { $0.agents.defaultAgent = p }
            return p.rawValue
        }
        try registry.register(.settingsAgentsDefaultProfile) { [unowned self] arg in
            // select(<provider>:<profileId>)
            let parts = try value(arg, .settingsAgentsDefaultProfile).split(separator: ":").map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]), TerminalProvider(rawValue: parts[0]) != nil else {
                throw ActionError.failed(.settingsAgentsDefaultProfile, message: "expected <provider>:<profileId>")
            }
            return try await guarded(.settingsAgentsDefaultProfile) {
                try await setDefaultProfile(id: id)
                return id.uuidString
            }
        }
        try registry.register(.settingsAgentsProfileNew) { [unowned self] arg in
            let p = try provider(arg, .settingsAgentsProfileNew)
            return try await guarded(.settingsAgentsProfileNew) {
                try await newProfile(provider: p)
                return editingProfileID?.uuidString
            }
        }
        try registry.register(.settingsAgentsProfileDuplicate) { [unowned self] arg in
            let id = try uuid(arg, .settingsAgentsProfileDuplicate)
            return try await guarded(.settingsAgentsProfileDuplicate) {
                try await duplicateProfile(id: id)
                return editingProfileID?.uuidString
            }
        }
        try registry.register(.settingsAgentsProfileEdit) { [unowned self] arg in
            let id = try uuid(arg, .settingsAgentsProfileEdit)
            return try await guarded(.settingsAgentsProfileEdit) {
                try toggleEditing(id: id)
                return editingProfileID?.uuidString ?? "closed"
            }
        }
        try registry.register(.settingsAgentsProfileDelete) { [unowned self] arg in
            let id = try uuid(arg, .settingsAgentsProfileDelete)
            return try await guarded(.settingsAgentsProfileDelete) {
                try await deleteProfile(id: id)
                return "deleted"
            }
        }
        let needsProfile: ActionRegistry.Enablement = { [unowned self] in
            editingProfile == nil ? .disabled(reason: "Open a profile to edit it.") : .enabled
        }
        try registry.register(.settingsAgentsProfileName, enablement: needsProfile) { [unowned self] arg in
            let text = try value(arg, .settingsAgentsProfileName).trimmingCharacters(in: .whitespaces)
            return try await guarded(.settingsAgentsProfileName) {
                try await editProfile(field: "agents.profileName") { profile in
                    guard !text.isEmpty else { throw SettingsError.invalid("Enter a name.") }
                    profile.name = text
                }
                return text
            }
        }
        try registry.register(.settingsAgentsProfilePermission, enablement: needsProfile) { [unowned self] arg in
            let mode = try value(arg, .settingsAgentsProfilePermission)
            return try await guarded(.settingsAgentsProfilePermission) {
                try await editProfile(field: "agents.profilePermission") { profile in
                    guard ProfileOptions.permissionChoices(for: profile.provider).contains(where: { $0.id == mode }) else {
                        throw SettingsError.invalid("\(mode) isn't a permission mode for \(AgentInfo.displayName(profile.provider)).")
                    }
                    profile.permissionMode = mode == "default" ? nil : mode
                }
                return mode
            }
        }
        try registry.register(.settingsAgentsProfileModel, enablement: needsProfile) { [unowned self] arg in
            let text = try value(arg, .settingsAgentsProfileModel).trimmingCharacters(in: .whitespaces)
            return try await guarded(.settingsAgentsProfileModel) {
                try await editProfile(field: "agents.profileModel") { profile in
                    guard !text.contains(where: \.isWhitespace) else { throw SettingsError.invalid("A model name has no spaces.") }
                    profile.model = text.isEmpty ? nil : text
                }
                return text
            }
        }
        try registry.register(.settingsAgentsProfileArgs, enablement: needsProfile) { [unowned self] arg in
            let text = try value(arg, .settingsAgentsProfileArgs)
            return try await guarded(.settingsAgentsProfileArgs) {
                try await editProfile(field: "agents.profileArgs") { profile in
                    switch ProfileOptions.validateExtraArgs(text, for: profile.provider) {
                    case .invalid(let message): throw SettingsError.invalid(message)
                    case .valid(let args): profile.extraArgs = args
                    }
                }
                return text
            }
        }
        try registry.register(.agentDetect) { [unowned self] arg in
            if arg.kind == .select {
                let p = try provider(arg, .agentDetect)
                guard AgentCatalog.providers.contains(p) else { throw ActionError.failed(.agentDetect, message: "unknown agent") }
                await refreshAgents(force: true, only: p)
            } else {
                await refreshAgents(force: true)
                await onDetectAll?()
            }
            return agents.map { "\($0.provider.rawValue)=\($0.statusText)" }.joined(separator: ", ")
        }
        try registry.register(.agentInstallHelp) { [unowned self] arg in
            // `gh` e Docker usam a mesma ação do onboarding (03 §24.6).
            if arg.value == "gh" || arg.value == "docker" {
                let url = arg.value == "gh" ? DiagnosticsEvaluator.ghInstallURL : DiagnosticsEvaluator.dockerInstallURL
                system.openURL(url)
                return url.absoluteString
            }
            let p = try provider(arg, .agentInstallHelp)
            guard let url = AgentInfo(provider: p).installURL else { throw ActionError.failed(.agentInstallHelp, message: "no install page") }
            system.openURL(url)
            return url.absoluteString
        }

        // Notifications (T2-04)
        func notificationFlag(_ id: ActionID, _ keyPath: WritableKeyPath<AppSettings.Notifications, Bool>, name: String) throws {
            try registry.register(id) { [unowned self] arg in
                change(name) { $0.notifications[keyPath: keyPath] = flag(arg, current: $0.notifications[keyPath: keyPath]) }
                attention?.refreshDock()
                return settings.notifications[keyPath: keyPath] ? "on" : "off"
            }
        }
        try notificationFlag(.settingsNotificationsNeedsInput, \.needsInput, name: "Agent needs input")
        try notificationFlag(.settingsNotificationsFinished, \.finished, name: "Agent finished")
        try notificationFlag(.settingsNotificationsFailed, \.failed, name: "Agent failed")
        try notificationFlag(.settingsNotificationsTerminalBell, \.terminalBell, name: "Terminal bell")
        try notificationFlag(.settingsNotificationsSuppressWhenVisible, \.suppressWhenVisible, name: "Suppress when visible")
        try notificationFlag(.settingsNotificationsDockBadge, \.dockBadge, name: "Dock badge")
        try registerProxyActions(in: registry)
        try registerCloudActions(in: registry)
        try registry.register(.settingsComputersDefaultSubagentMode) { [unowned self] arg in
            guard let raw = arg.value, let mode = SubagentComputersMode(rawValue: raw) else {
                throw ActionError.failed(.settingsComputersDefaultSubagentMode, message: "expected off, ask or full")
            }
            change("Subagent computers") { $0.computers.defaultSubagentMode = mode }
            return mode.rawValue
        }
        try registry.register(.settingsComputersDefaultSubagentHarness) { [unowned self] arg in
            guard let raw = arg.value, let harness = SubagentHarness(rawValue: raw) else {
                throw ActionError.failed(.settingsComputersDefaultSubagentHarness, message: "expected claude, codex, opencode or mixed")
            }
            change("Subagents run as") { $0.computers.defaultSubagentHarness = harness }
            return harness.rawValue
        }
        try registry.register(
            .settingsComputersForceDocker,
            enablement: { [unowned self] in
                runtimeInfo.nativeAvailable ? .enabled : .disabled(reason: runtimeInfo.unavailableReason ?? "Computers already use Docker on this Mac.")
            }
        ) { [unowned self] arg in
            change("Use Docker instead") { $0.computers.forceDocker = flag(arg, current: $0.computers.forceDocker) }
            // A checklist (onboarding, Diagnostics) muda de runtime junto: refaz as sondas.
            Task { [onDetectAll] in await onDetectAll?() }
            return settings.computers.forceDocker ? "on" : "off"
        }
        try registry.register(.settingsComputersGithubAccess) { [unowned self] arg in
            change("Git from computers") { $0.computers.githubAccess = flag(arg, current: $0.computers.githubAccess) }
            return settings.computers.githubAccess ? "on" : "off"
        }
        try registry.register(.settingsNotificationsSound) { [unowned self] arg in
            guard let raw = arg.value, let sound = AppSettings.NotificationSound(rawValue: raw) else {
                throw ActionError.failed(.settingsNotificationsSound, message: "expected system or none")
            }
            change("Notification sound") { $0.notifications.sound = sound }
            return sound.rawValue
        }
        try registry.register(
            .notificationsRequest,
            enablement: { [unowned self] in notificationAuthorization == .authorized ? .disabled(reason: "Notifications are on.") : .enabled }
        ) { [unowned self] _ in
            let result = await requestNotificationAuthorization()
            return result.rawValue
        }
        try registry.register(.appOpenSystemSettings) { [unowned self] arg in
            system.openSystemSettings(arg.value ?? "notifications")
            return arg.value ?? "notifications"
        }
        try registry.register(
            .settingsTestNotification,
            enablement: { [unowned self] in
                notificationAuthorization == .authorized ? .enabled : .disabled(reason: "Notifications are off for Racky.")
            }
        ) { [unowned self] _ in
            let result = await attention?.sendTest() ?? .notDetermined
            await refreshNotificationAuthorization()
            guard result == .authorized else {
                throw ActionError.failed(.settingsTestNotification, message: "Notifications are off for Racky.")
            }
            return "sent"
        }

        // Terminal
        try registry.register(.settingsTerminalFont) { [unowned self] arg in
            let family = try value(arg, .settingsTerminalFont)
            guard AppSettings.Terminal.fontFamilies.contains(family) else { throw ActionError.failed(.settingsTerminalFont, message: "unknown font") }
            change("Font") { $0.terminal.fontFamily = family }
            return family
        }
        try registry.register(.settingsTerminalSize) { [unowned self] arg in
            let range = AppSettings.Terminal.fontSizeRange
            let current = settings.terminal.fontSize
            let next: Int
            switch (arg.kind, arg.value) {
            case (.select, "inc"): next = min(current + 1, range.upperBound)
            case (.select, "dec"): next = max(current - 1, range.lowerBound)
            default:
                switch SettingsValidation.fontSize(try value(arg, .settingsTerminalSize)) {
                case .failure(let error): throw ActionError.failed(.settingsTerminalSize, message: error.message)
                case .success(let size): next = size
                }
            }
            change("Size") { $0.terminal.fontSize = next }
            return String(next)
        }
        try registry.register(.settingsTerminalTheme) { [unowned self] arg in
            let theme = try value(arg, .settingsTerminalTheme)
            guard theme == AppSettings.Terminal.defaultTheme else { throw ActionError.failed(.settingsTerminalTheme, message: "unknown theme") }
            change("Theme") { $0.terminal.theme = theme }
            return theme
        }
        try registry.register(.settingsTerminalCursor) { [unowned self] arg in
            guard let raw = arg.value, let style = AppSettings.CursorStyle(rawValue: raw) else {
                throw ActionError.failed(.settingsTerminalCursor, message: "expected block, bar or underline")
            }
            change("Cursor") { $0.terminal.cursor = style }
            return style.rawValue
        }
        try registry.register(.settingsTerminalCursorBlink) { [unowned self] arg in
            change("Cursor blink") { $0.terminal.cursorBlink = flag(arg, current: $0.terminal.cursorBlink) }
            return settings.terminal.cursorBlink ? "on" : "off"
        }
    }
}
