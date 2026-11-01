import RackyCore
import RackyDesignSystem
import RackyProtocol
import Observation
import SwiftUI

extension ConfirmationModel {
    /// "Archive "<session>"?" (03 §16.2): para os terminais; pasta, worktree e branch ficam.
    static func archiveSession(name: String) -> ConfirmationModel {
        ConfirmationModel(
            name: "confirmArchive", rootID: .overlayConfirmArchive, title: String(localized: "Archive \"\(name)\"?", bundle: .module),
            message: String(localized: "Stops its terminals and computers. The folder, worktree and branch stay; you can restore it from Archived Sessions.", bundle: .module),
            confirmTitle: "Archive", confirmAction: .dialogArchiveConfirm, confirmID: .overlayConfirmArchiveConfirm,
            cancelAction: .dialogArchiveCancel, cancelID: .overlayConfirmArchiveCancel, destructive: false, symbol: "archivebox")
    }
}

/// Estado dos controles do diálogo "Delete session" (03 §16.5): o handler de cada ação grava aqui e o checkbox lê.
@MainActor @Observable
final class DeleteSessionState {
    let sessionID: UUID
    let title: String
    /// Sessão limpa com pasta criada pelo app: oferece "Move folder to Trash" e "Also delete run folders" (AC-1108).
    let managedFolder: Bool
    /// Sessão de worktree: o diálogo lista o que se perde e remove a pasta do worktree (06 §5.2).
    let isWorktree: Bool
    /// Branch do worktree (`nil` = sem branch, o checkbox `Keep the branch` não aparece).
    let branch: String?
    /// Leitura feita antes de abrir o diálogo (`GitService.inspectRemoval`); `nil` fora de worktree.
    let preview: SessionRemovalPreview?
    var keepBranch = false
    var trashFolder = true
    var deleteRuns = false
    var dontAsk = false

    init(
        sessionID: UUID, title: String, managedFolder: Bool, isWorktree: Bool = false, branch: String? = nil,
        preview: SessionRemovalPreview? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.managedFolder = managedFolder
        self.isWorktree = isWorktree
        self.branch = (branch ?? "").isEmpty ? nil : branch
        self.preview = preview
    }

    /// Há trabalho que só existe neste worktree: aviso `destructive`, sem `Don't ask again`.
    var losesData: Bool { preview?.losesData ?? false }
    var showsKeepBranch: Bool { isWorktree && branch != nil && preview?.missingOnDisk != true }
    var showsDontAsk: Bool { !losesData }

    /// Texto do diálogo: worktree (remove a pasta), pasta criada pelo app × pasta escolhida que fica no disco (AC-1105).
    var message: String {
        if isWorktree {
            if preview?.missingOnDisk == true {
                return String(localized: "Stops its terminals and computers. The worktree folder is already gone.", bundle: .module)
            }
            guard let branch, showsKeepBranch else {
                return String(localized: "Stops its terminals and computers and removes the worktree folder.", bundle: .module)
            }
            return keepBranch
                ? String(localized: "Stops its terminals and computers and removes the worktree folder. The branch \"\(branch)\" stays.", bundle: .module)
                : String(localized: "Stops its terminals and computers, removes the worktree folder and deletes the local branch \"\(branch)\".", bundle: .module)
        }
        return managedFolder
            ? String(localized: "Stops its terminals and computers.", bundle: .module)
            : String(localized: "Stops its terminals and computers. The folder stays on disk.", bundle: .module)
    }
}

/// Aviso `destructive` do diálogo de apagar worktree: contagens e os primeiros arquivos que se perdem (03 §16.5).
struct DeleteSessionLossView: View {
    let preview: SessionRemovalPreview

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: DS.Space.s4 - DS.Space.s0_5))
                    .foregroundStyle(DS.Color.destructive)
                    .accessibilityHidden(true)
                Text(verbatim: preview.lossSummary ?? "")
                    .dsFont(DS.Font.label)
                    .foregroundStyle(DS.Color.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.samplePaths.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.samplePaths, id: \.self) { path in
                        Text(verbatim: path)
                            .dsFont(DS.Font.monoMicro)
                            .foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if preview.uncommittedFiles > preview.samplePaths.count {
                        Text(verbatim: String(localized: "and \(preview.uncommittedFiles - preview.samplePaths.count) more", bundle: .module))
                            .dsFont(DS.Font.monoMicro)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
                .padding(.leading, DS.Space.s4 + DS.Space.s1)
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.destructiveBackground))
        .a11y(.overlayConfirmDeleteChanges, kind: "container", label: preview.lossSummary ?? "")
    }
}

/// "Delete "<session>"?" (03 §16.5), variante de sessão limpa.
struct DeleteSessionOverlayContent: View {
    let state: DeleteSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                Image(systemName: "trash")
                    .font(.system(size: DSMetrics.confirmationIcon))
                    .foregroundStyle(DS.Color.destructive)
                    .frame(width: DSMetrics.confirmationTile, height: DSMetrics.confirmationTile)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.destructiveBackground))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text(verbatim: String(localized: "Delete \"\(state.title)\"?", bundle: .module))
                        .dsFont(DS.Font.dialogTitle)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: state.message)
                        .dsFont(DS.Font.dialogBody)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let preview = state.preview, preview.losesData { DeleteSessionLossView(preview: preview) }
            if state.managedFolder {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    DSCheckbox(isOn: state.trashFolder, action: .dialogDeleteSessionTrashFolder, id: .overlayConfirmDeleteTrashFolder, "Move folder to Trash")
                    DSCheckbox(isOn: state.deleteRuns, action: .dialogDeleteSessionDeleteRuns, id: .overlayConfirmDeleteDeleteRuns, "Also delete run folders")
                }
            }
            if state.showsKeepBranch {
                DSCheckbox(isOn: state.keepBranch, action: .dialogDeleteSessionKeepBranch, id: .overlayConfirmDeleteKeepBranch, "Keep the branch")
            }
            HStack(spacing: DS.Space.s2) {
                if state.showsDontAsk {
                    DSCheckbox(isOn: state.dontAsk, action: .dialogDeleteSessionDontAsk, id: .overlayConfirmDeleteDontAsk, "Don't ask again")
                }
                Spacer(minLength: DS.Space.s2)
                DSButton(.dialogDeleteSessionCancel, id: .overlayConfirmDeleteCancel, "Cancel", variant: .outline)
                // O catálogo já tem "Delete Session…" (menu) e o Xcode recusa duas chaves com o mesmo símbolo: o texto vem de `String(localized:)`.
                DSButton(
                    .dialogDeleteSessionConfirm, id: .overlayConfirmDeleteConfirm, LocalizedStringKey(String(localized: "Delete Session", bundle: .module)),
                    variant: .destructive)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSMetrics.overlayPadding)
    }
}

extension OverlaySpec {
    static func deleteSession(_ state: DeleteSessionState) -> OverlaySpec {
        OverlaySpec(
            name: "confirmDelete", id: .overlayConfirmDelete, width: DS.Layout.confirmationWidth, cancelAction: .dialogDeleteSessionCancel,
            content: { AnyView(DeleteSessionOverlayContent(state: state)) })
    }
}

/// Estado do overlay "Move to Project" (03 §16.8).
@MainActor @Observable
final class MoveToProjectState {
    static let convertID = "convert"

    let sessionID: UUID
    let title: String
    /// `""` = nada escolhido (o botão fica desabilitado com `Choose a project.`).
    var selection: String
    let projects: [Project]

    init(sessionID: UUID, title: String, projects: [Project], selection: String = "") {
        self.sessionID = sessionID
        self.title = title
        self.projects = projects
        self.selection = selection
    }

    var isConvert: Bool { selection == Self.convertID }
    var projectID: UUID? { UUID(uuidString: selection) }

    var entries: [DSMenuEntry] {
        var list: [DSMenuEntry] = [
            .item(DSMenuItem(
                Self.convertID, String(localized: "Convert to Project (use this folder as the project root)", bundle: .module),
                icon: .symbol("folder.badge.plus"))),
            .separator("projects"),
        ]
        for p in projects {
            list.append(.item(DSMenuItem(p.id.uuidString, p.name, icon: .symbol("folder"), detail: p.rootPath)))
        }
        return list
    }

    var confirmTitle: LocalizedStringKey { isConvert ? "Convert" : "Move" }
}

struct MoveToProjectOverlayContent: View {
    let state: MoveToProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text(verbatim: String(localized: "Move \"\(state.title)\" to a project?", bundle: .module))
                    .dsFont(DS.Font.dialogTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text("The folder stays where it is. Agents keep running.", bundle: .module)
                    .dsFont(DS.Font.dialogBody)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("Project", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                DSCombobox(
                    id: .overlayMoveToProjectProject, selection: state.selection, entries: state.entries, action: .dialogMoveToProjectSetProject,
                    searchPlaceholder: String(localized: "Search projects…", bundle: .module),
                    placeholder: String(localized: "Select a project", bundle: .module))
            }
            HStack(spacing: DS.Space.s2) {
                Spacer(minLength: DS.Space.s2)
                DSButton(.dialogMoveToProjectCancel, id: .overlayMoveToProjectCancel, "Cancel", variant: .outline)
                DSButton(.dialogMoveToProjectConfirm, id: .overlayMoveToProjectConfirm, state.confirmTitle, variant: .primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSMetrics.overlayPadding)
    }
}

extension OverlaySpec {
    static func moveToProject(_ state: MoveToProjectState) -> OverlaySpec {
        OverlaySpec(
            name: "moveToProject", id: .overlayMoveToProject, width: DS.Layout.confirmationWidth, cancelAction: .dialogMoveToProjectCancel,
            content: { AnyView(MoveToProjectOverlayContent(state: state)) })
    }
}
