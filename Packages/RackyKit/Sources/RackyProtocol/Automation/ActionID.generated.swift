// GERADO por scripts/gen-automation-ids.py a partir de docs/rebuild/spec/03-screens.md §24. NÃO EDITAR.
// ActionID = <grupo>.<ação> em lowerCamelCase (03 §24). A fatia vem da coluna Versão (regras no gerador).

extension ActionID {
    public static let appAbout = ActionID(unchecked: "app.about")
    public static let appSettings = ActionID(unchecked: "app.settings")
    public static let appSetup = ActionID(unchecked: "app.setup")
    public static let appCheckProblems = ActionID(unchecked: "app.checkProblems")
    public static let appHideAppName = ActionID(unchecked: "app.hideAppName")
    public static let appQuit = ActionID(unchecked: "app.quit")
    public static let appQuitCompletely = ActionID(unchecked: "app.quitCompletely")
    public static let appOpenMainWindow = ActionID(unchecked: "app.openMainWindow")
    public static let appStopAllAgents = ActionID(unchecked: "app.stopAllAgents")
    public static let viewToggleSidebar = ActionID(unchecked: "view.toggleSidebar")
    public static let viewToggleRightPanel = ActionID(unchecked: "view.toggleRightPanel")
    public static let viewToggleStatusBar = ActionID(unchecked: "view.toggleStatusBar")
    public static let statusBarOpenSegment = ActionID(unchecked: "statusBar.openSegment")
    public static let statusBarToggleSegment = ActionID(unchecked: "statusBar.toggleSegment")
    public static let navBack = ActionID(unchecked: "nav.back")
    public static let navForward = ActionID(unchecked: "nav.forward")
    public static let terminalFontBigger = ActionID(unchecked: "terminal.fontBigger")
    public static let terminalFontSmaller = ActionID(unchecked: "terminal.fontSmaller")
    public static let terminalFontReset = ActionID(unchecked: "terminal.fontReset")
    public static let sidebarHideNavItem = ActionID(unchecked: "sidebar.hideNavItem")
    public static let helpOpen = ActionID(unchecked: "help.open")
    public static let helpShortcuts = ActionID(unchecked: "help.shortcuts")
    public static let helpRevealLogs = ActionID(unchecked: "help.revealLogs")
    public static let helpExportDiagnostics = ActionID(unchecked: "help.exportDiagnostics")
    public static let appOpenDiagnostics = ActionID(unchecked: "app.openDiagnostics")
    public static let diagnosticsSaveExport = ActionID(unchecked: "diagnostics.saveExport")
    public static let diagnosticsCancelExport = ActionID(unchecked: "diagnostics.cancelExport")
    public static let diagnosticsDismissCrash = ActionID(unchecked: "diagnostics.dismissCrash")
    public static let appRestartBackgroundService = ActionID(unchecked: "app.restartBackgroundService")
    public static let appErrorTryAgain = ActionID(unchecked: "app.errorTryAgain")
    public static let appCopyDetails = ActionID(unchecked: "app.copyDetails")
    public static let appRevealCorruptFile = ActionID(unchecked: "app.revealCorruptFile")
    public static let sessionNew = ActionID(unchecked: "session.new")
    public static let sessionNewClean = ActionID(unchecked: "session.newClean")
    public static let sessionNewCleanInFolder = ActionID(unchecked: "session.newCleanInFolder")
    public static let projectAdd = ActionID(unchecked: "project.add")
    public static let sessionSetSubagentComputers = ActionID(unchecked: "session.setSubagentComputers")
    public static let sessionSetSubagentHarness = ActionID(unchecked: "session.setSubagentHarness")
    public static let agentToggleChildren = ActionID(unchecked: "agent.toggleChildren")
    public static let sessionRestartToApply = ActionID(unchecked: "session.restartToApply")
    public static let projectCloneFromGitHub = ActionID(unchecked: "project.cloneFromGitHub")
    public static let sidebarSortFilter = ActionID(unchecked: "sidebar.sortFilter")
    public static let sidebarResetFilters = ActionID(unchecked: "sidebar.resetFilters")
    public static let sidebarClearSearch = ActionID(unchecked: "sidebar.clearSearch")
    public static let sidebarClearFilters = ActionID(unchecked: "sidebar.clearFilters")
    public static let projectShowMore = ActionID(unchecked: "project.showMore")
    public static let projectNewSession = ActionID(unchecked: "project.newSession")
    public static let projectNewSessionFromRef = ActionID(unchecked: "project.newSessionFromRef")
    public static let itemOpenInEditor = ActionID(unchecked: "item.openInEditor")
    public static let itemRevealInFinder = ActionID(unchecked: "item.revealInFinder")
    public static let itemCopyPath = ActionID(unchecked: "item.copyPath")
    public static let itemOpenOnGitHub = ActionID(unchecked: "item.openOnGitHub")
    public static let sessionCopyBranch = ActionID(unchecked: "session.copyBranch")
    public static let projectCollapseAll = ActionID(unchecked: "project.collapseAll")
    public static let projectHide = ActionID(unchecked: "project.hide")
    public static let projectRename = ActionID(unchecked: "project.rename")
    public static let projectRemove = ActionID(unchecked: "project.remove")
    public static let itemRefreshGit = ActionID(unchecked: "item.refreshGit")
    public static let itemCopyId = ActionID(unchecked: "item.copyId")
    public static let terminalShowLaunchDetails = ActionID(unchecked: "terminal.showLaunchDetails")
    public static let sessionRename = ActionID(unchecked: "session.rename")
    public static let sessionRenameBranch = ActionID(unchecked: "session.renameBranch")
    public static let sessionEditNote = ActionID(unchecked: "session.editNote")
    public static let sessionMarkRead = ActionID(unchecked: "session.markRead")
    public static let sessionMarkUnread = ActionID(unchecked: "session.markUnread")
    public static let sessionMute = ActionID(unchecked: "session.mute")
    public static let sessionUnmute = ActionID(unchecked: "session.unmute")
    public static let sessionPin = ActionID(unchecked: "session.pin")
    public static let sessionResumeAgents = ActionID(unchecked: "session.resumeAgents")
    public static let sessionMoveToProject = ActionID(unchecked: "session.moveToProject")
    public static let sessionConvertToProject = ActionID(unchecked: "session.convertToProject")
    public static let sessionMoveFolderIntoProject = ActionID(unchecked: "session.moveFolderIntoProject")
    public static let sessionArchive = ActionID(unchecked: "session.archive")
    public static let sessionDelete = ActionID(unchecked: "session.delete")
    public static let sessionRestore = ActionID(unchecked: "session.restore")
    public static let sessionUndoArchive = ActionID(unchecked: "session.undoArchive")
    public static let sessionUndoDelete = ActionID(unchecked: "session.undoDelete")
    public static let itemOpenIn = ActionID(unchecked: "item.openIn")
    public static let itemOpenInTarget = ActionID(unchecked: "item.openInTarget")
    public static let sessionLocateFolder = ActionID(unchecked: "session.locateFolder")
    public static let sidebarRevealCurrent = ActionID(unchecked: "sidebar.revealCurrent")
    public static let sessionNextNeedingAttention = ActionID(unchecked: "session.nextNeedingAttention")
    public static let sessionPrevious = ActionID(unchecked: "session.previous")
    public static let sessionNext = ActionID(unchecked: "session.next")
    public static let sessionSelect1 = ActionID(unchecked: "session.select1")
    public static let sessionSelect2 = ActionID(unchecked: "session.select2")
    public static let sessionSelect3 = ActionID(unchecked: "session.select3")
    public static let sessionSelect4 = ActionID(unchecked: "session.select4")
    public static let sessionSelect5 = ActionID(unchecked: "session.select5")
    public static let sessionSelect6 = ActionID(unchecked: "session.select6")
    public static let sessionSelect7 = ActionID(unchecked: "session.select7")
    public static let sessionSelect8 = ActionID(unchecked: "session.select8")
    public static let sessionSelect9 = ActionID(unchecked: "session.select9")
    public static let sidebarFocus = ActionID(unchecked: "sidebar.focus")
    public static let sessionSelect = ActionID(unchecked: "session.select")
    public static let sessionToggleAgents = ActionID(unchecked: "session.toggleAgents")
    public static let childAskParentToRelaunch = ActionID(unchecked: "child.askParentToRelaunch")
    public static let childShowTranscript = ActionID(unchecked: "child.showTranscript")
    public static let childShowComputer = ActionID(unchecked: "child.showComputer")
    public static let childCopyId = ActionID(unchecked: "child.copyId")
    public static let childMessage = ActionID(unchecked: "child.message")
    public static let childStop = ActionID(unchecked: "child.stop")
    public static let sidebarSearch = ActionID(unchecked: "sidebar.search")
    public static let sidebarProjectToggle = ActionID(unchecked: "sidebar.project.toggle")
    public static let sessionCancelLaunch = ActionID(unchecked: "session.cancelLaunch")
    public static let sessionRetryLaunch = ActionID(unchecked: "session.retryLaunch")
    public static let sessionResumeStopped = ActionID(unchecked: "session.resumeStopped")
    public static let sessionUseExistingBranch = ActionID(unchecked: "session.useExistingBranch")
    public static let sessionCreateWithoutFetch = ActionID(unchecked: "session.createWithoutFetch")
    public static let sessionDiscardPending = ActionID(unchecked: "session.discardPending")
    public static let sessionLaunch = ActionID(unchecked: "session.launch")
    public static let tabQuickLaunch = ActionID(unchecked: "tab.quickLaunch")
    public static let tabNewAgent = ActionID(unchecked: "tab.newAgent")
    public static let tabNewTerminal = ActionID(unchecked: "tab.newTerminal")
    public static let tabNewWithAgent = ActionID(unchecked: "tab.newWithAgent")
    public static let tabNewWithPrompt = ActionID(unchecked: "tab.newWithPrompt")
    public static let paneClose = ActionID(unchecked: "pane.close")
    public static let tabClose = ActionID(unchecked: "tab.close")
    public static let tabCloseOthers = ActionID(unchecked: "tab.closeOthers")
    public static let tabCloseRight = ActionID(unchecked: "tab.closeRight")
    public static let tabReopen = ActionID(unchecked: "tab.reopen")
    public static let windowClose = ActionID(unchecked: "window.close")
    public static let tabNext = ActionID(unchecked: "tab.next")
    public static let tabPrevious = ActionID(unchecked: "tab.previous")
    public static let tabRecent = ActionID(unchecked: "tab.recent")
    public static let tabSelect1 = ActionID(unchecked: "tab.select1")
    public static let tabSelect2 = ActionID(unchecked: "tab.select2")
    public static let tabSelect3 = ActionID(unchecked: "tab.select3")
    public static let tabSelect4 = ActionID(unchecked: "tab.select4")
    public static let tabSelect5 = ActionID(unchecked: "tab.select5")
    public static let tabSelect6 = ActionID(unchecked: "tab.select6")
    public static let tabSelect7 = ActionID(unchecked: "tab.select7")
    public static let tabSelect8 = ActionID(unchecked: "tab.select8")
    public static let tabSelect9 = ActionID(unchecked: "tab.select9")
    public static let tabRename = ActionID(unchecked: "tab.rename")
    public static let tabResetTitle = ActionID(unchecked: "tab.resetTitle")
    public static let paneSplitRight = ActionID(unchecked: "pane.splitRight")
    public static let paneSplitDown = ActionID(unchecked: "pane.splitDown")
    public static let paneNext = ActionID(unchecked: "pane.next")
    public static let panePrevious = ActionID(unchecked: "pane.previous")
    public static let paneToggleExpand = ActionID(unchecked: "pane.toggleExpand")
    public static let paneEqualize = ActionID(unchecked: "pane.equalize")
    public static let paneCloseOthers = ActionID(unchecked: "pane.closeOthers")
    public static let paneShow = ActionID(unchecked: "pane.show")
    public static let terminalRestart = ActionID(unchecked: "terminal.restart")
    public static let terminalRestartWithProfile = ActionID(unchecked: "terminal.restartWithProfile")
    public static let terminalResume = ActionID(unchecked: "terminal.resume")
    public static let terminalStartFresh = ActionID(unchecked: "terminal.startFresh")
    public static let terminalCopyResumeCommand = ActionID(unchecked: "terminal.copyResumeCommand")
    public static let terminalCopyId = ActionID(unchecked: "terminal.copyId")
    public static let terminalCopyConversationId = ActionID(unchecked: "terminal.copyConversationId")
    public static let paneCopyId = ActionID(unchecked: "pane.copyId")
    public static let terminalShowHookLog = ActionID(unchecked: "terminal.showHookLog")
    public static let terminalSendInterrupt = ActionID(unchecked: "terminal.sendInterrupt")
    public static let terminalSendText = ActionID(unchecked: "terminal.sendText")
    public static let terminalScreen = ActionID(unchecked: "terminal.screen")
    public static let terminalForceQuit = ActionID(unchecked: "terminal.forceQuit")
    public static let findOpen = ActionID(unchecked: "find.open")
    public static let findNext = ActionID(unchecked: "find.next")
    public static let findPrevious = ActionID(unchecked: "find.previous")
    public static let findClose = ActionID(unchecked: "find.close")
    public static let terminalClear = ActionID(unchecked: "terminal.clear")
    public static let editCopy = ActionID(unchecked: "edit.copy")
    public static let editPaste = ActionID(unchecked: "edit.paste")
    public static let editSelectAll = ActionID(unchecked: "edit.selectAll")
    public static let terminalOpenLink = ActionID(unchecked: "terminal.openLink")
    public static let terminalCopyLink = ActionID(unchecked: "terminal.copyLink")
    public static let terminalOpenFile = ActionID(unchecked: "terminal.openFile")
    public static let terminalOpenComputer = ActionID(unchecked: "terminal.openComputer")
    public static let terminalOpenElsewhere = ActionID(unchecked: "terminal.openElsewhere")
    public static let promptInsertSkillOrAgent = ActionID(unchecked: "prompt.insertSkillOrAgent")
    public static let promptInsertItem = ActionID(unchecked: "prompt.insertItem")
    public static let tabQuickCommands = ActionID(unchecked: "tab.quickCommands")
    public static let tabsPaneActions = ActionID(unchecked: "tabs.paneActions")
    public static let tabReorder = ActionID(unchecked: "tab.reorder")
    public static let tabDropOnPane = ActionID(unchecked: "tab.dropOnPane")
    public static let paneMove = ActionID(unchecked: "pane.move")
    public static let paneDetach = ActionID(unchecked: "pane.detach")
    public static let paneResizeDivider = ActionID(unchecked: "pane.resizeDivider")
    public static let findCaseSensitive = ActionID(unchecked: "find.caseSensitive")
    public static let findRegex = ActionID(unchecked: "find.regex")
    public static let findQuery = ActionID(unchecked: "find.query")
    public static let terminalRetryStart = ActionID(unchecked: "terminal.retryStart")
    public static let agentOpenSettings = ActionID(unchecked: "agent.openSettings")
    public static let terminalCopyStartError = ActionID(unchecked: "terminal.copyStartError")
    public static let terminalCancelClose = ActionID(unchecked: "terminal.cancelClose")
    public static let tabQuickLaunchResume = ActionID(unchecked: "tab.quickLaunchResume")
    public static let panelSourceControl = ActionID(unchecked: "panel.sourceControl")
    public static let panelChecks = ActionID(unchecked: "panel.checks")
    public static let panelComputers = ActionID(unchecked: "panel.computers")
    public static let panelConversations = ActionID(unchecked: "panel.conversations")
    public static let panelContext = ActionID(unchecked: "panel.context")
    public static let panelRefresh = ActionID(unchecked: "panel.refresh")
    public static let gitCreatePR = ActionID(unchecked: "git.createPR")
    public static let gitOpenPR = ActionID(unchecked: "git.openPR")
    public static let gitCopyPRURL = ActionID(unchecked: "git.copyPRURL")
    public static let gitOpenChange = ActionID(unchecked: "git.openChange")
    public static let gitOpenCheck = ActionID(unchecked: "git.openCheck")
    public static let accountLogIn = ActionID(unchecked: "account.logIn")
    public static let checksSendFailures = ActionID(unchecked: "checks.sendFailures")
    public static let conversationResume = ActionID(unchecked: "conversation.resume")
    public static let conversationResumeSplit = ActionID(unchecked: "conversation.resumeSplit")
    public static let conversationShowTranscript = ActionID(unchecked: "conversation.showTranscript")
    public static let conversationMenu = ActionID(unchecked: "conversation.menu")
    public static let conversationCopyResumeCommand = ActionID(unchecked: "conversation.copyResumeCommand")
    public static let conversationCopyId = ActionID(unchecked: "conversation.copyId")
    public static let conversationSetScope = ActionID(unchecked: "conversation.setScope")
    public static let conversationSetQuery = ActionID(unchecked: "conversation.setQuery")
    public static let conversationBack = ActionID(unchecked: "conversation.back")
    public static let contextRestartWithResume = ActionID(unchecked: "context.restartWithResume")
    public static let contextToggleItem = ActionID(unchecked: "context.toggleItem")
    public static let pageLibrary = ActionID(unchecked: "page.library")
    public static let pageComputers = ActionID(unchecked: "page.computers")
    public static let pageDatasets = ActionID(unchecked: "page.datasets")
    public static let datasetOpen = ActionID(unchecked: "dataset.open")
    public static let datasetFilter = ActionID(unchecked: "dataset.filter")
    public static let datasetSearch = ActionID(unchecked: "dataset.search")
    public static let datasetSelectRow = ActionID(unchecked: "dataset.selectRow")
    public static let datasetLoadMore = ActionID(unchecked: "dataset.loadMore")
    public static let datasetExport = ActionID(unchecked: "dataset.export")
    public static let datasetNotebook = ActionID(unchecked: "dataset.notebook")
    public static let notebookToggleDataset = ActionID(unchecked: "notebook.toggleDataset")
    public static let notebookAddDataset = ActionID(unchecked: "notebook.addDataset")
    public static let notebookApply = ActionID(unchecked: "notebook.apply")
    public static let notebookOpenBeside = ActionID(unchecked: "notebook.openBeside")
    public static let datasetOpenSource = ActionID(unchecked: "dataset.openSource")
    public static let datasetRange = ActionID(unchecked: "dataset.range")
    public static let datasetFacet = ActionID(unchecked: "dataset.facet")
    public static let datasetTimeWindow = ActionID(unchecked: "dataset.timeWindow")
    public static let datasetAddFilter = ActionID(unchecked: "dataset.addFilter")
    public static let datasetRemoveFilter = ActionID(unchecked: "dataset.removeFilter")
    public static let datasetColumnRange = ActionID(unchecked: "dataset.columnRange")
    public static let datasetFacetsReset = ActionID(unchecked: "dataset.facetsReset")
    public static let dataOpen = ActionID(unchecked: "data.open")
    public static let dataClose = ActionID(unchecked: "data.close")
    public static let dataToggleNode = ActionID(unchecked: "data.toggleNode")
    public static let dataNewQuery = ActionID(unchecked: "data.newQuery")
    public static let dataTableTab = ActionID(unchecked: "data.tableTab")
    public static let dataQueryRun = ActionID(unchecked: "data.queryRun")
    public static let dataAddConnection = ActionID(unchecked: "data.addConnection")
    public static let dataSendTo = ActionID(unchecked: "data.sendTo")
    public static let dataWebhookTest = ActionID(unchecked: "data.webhookTest")
    public static let dataPauseWriter = ActionID(unchecked: "data.pauseWriter")
    public static let dataToggleExplorer = ActionID(unchecked: "data.toggleExplorer")
    public static let dataRenameDataset = ActionID(unchecked: "data.renameDataset")
    public static let dataTablePage = ActionID(unchecked: "data.tablePage")
    public static let dataConnectStart = ActionID(unchecked: "data.connectStart")
    public static let dataConnectSave = ActionID(unchecked: "data.connectSave")
    public static let dataConnectionRemove = ActionID(unchecked: "data.connectionRemove")
    public static let dataS3Page = ActionID(unchecked: "data.s3Page")
    public static let dataRunsFilter = ActionID(unchecked: "data.runsFilter")
    public static let datasetPage = ActionID(unchecked: "dataset.page")
    public static let datasetColumns = ActionID(unchecked: "dataset.columns")
    public static let datasetCopyRow = ActionID(unchecked: "dataset.copyRow")
    public static let datasetPanelTab = ActionID(unchecked: "dataset.panelTab")
    public static let pageSessions = ActionID(unchecked: "page.sessions")
    public static let pageInbox = ActionID(unchecked: "page.inbox")
    public static let pageClose = ActionID(unchecked: "page.close")
    public static let inboxMarkRead = ActionID(unchecked: "inbox.markRead")
    public static let inboxMarkAllRead = ActionID(unchecked: "inbox.markAllRead")
    public static let inboxFilter = ActionID(unchecked: "inbox.filter")
    public static let notificationsRequest = ActionID(unchecked: "notifications.request")
    public static let appOpenSystemSettings = ActionID(unchecked: "app.openSystemSettings")
    public static let notificationOpen = ActionID(unchecked: "notification.open")
    public static let settingsTestNotification = ActionID(unchecked: "settings.testNotification")
    public static let notificationsPause = ActionID(unchecked: "notifications.pause")
    public static let libraryNewSessionWith = ActionID(unchecked: "library.newSessionWith")
    public static let libraryToggleInSession = ActionID(unchecked: "library.toggleInSession")
    public static let libraryOpenInEditor = ActionID(unchecked: "library.openInEditor")
    public static let libraryReveal = ActionID(unchecked: "library.reveal")
    public static let librarySetSection = ActionID(unchecked: "library.setSection")
    public static let librarySetSearch = ActionID(unchecked: "library.setSearch")
    public static let librarySetSource = ActionID(unchecked: "library.setSource")
    public static let librarySelectItem = ActionID(unchecked: "library.selectItem")
    public static let libraryEditProfiles = ActionID(unchecked: "library.editProfiles")
    public static let profileNew = ActionID(unchecked: "profile.new")
    public static let profileDuplicate = ActionID(unchecked: "profile.duplicate")
    public static let profileDelete = ActionID(unchecked: "profile.delete")
    public static let libraryNewAgent = ActionID(unchecked: "library.newAgent")
    public static let libraryImportSkill = ActionID(unchecked: "library.importSkill")
    public static let libraryEdit = ActionID(unchecked: "library.edit")
    public static let conflictBlock = ActionID(unchecked: "conflict.block")
    public static let conflictDisableGlobal = ActionID(unchecked: "conflict.disableGlobal")
    public static let conflictKeep = ActionID(unchecked: "conflict.keep")
    public static let conflictRestore = ActionID(unchecked: "conflict.restore")
    public static let computerOpenViewer = ActionID(unchecked: "computer.openViewer")
    public static let computerPopOut = ActionID(unchecked: "computer.popOut")
    public static let computerTakeOver = ActionID(unchecked: "computer.takeOver")
    public static let computerHandBack = ActionID(unchecked: "computer.handBack")
    public static let computerForceTakeOver = ActionID(unchecked: "computer.forceTakeOver")
    public static let computerDeclineHelp = ActionID(unchecked: "computer.declineHelp")
    public static let computerReleaseKeyboard = ActionID(unchecked: "computer.releaseKeyboard")
    public static let computerShowTab = ActionID(unchecked: "computer.showTab")
    public static let computerOpenRunFolder = ActionID(unchecked: "computer.openRunFolder")
    public static let computerRevealResult = ActionID(unchecked: "computer.revealResult")
    public static let computerOpenEvidence = ActionID(unchecked: "computer.openEvidence")
    public static let computerSetDisplay = ActionID(unchecked: "computer.setDisplay")
    public static let computerSetProxy = ActionID(unchecked: "computer.setProxy")
    public static let computerPaste = ActionID(unchecked: "computer.paste")
    public static let computerCopySelection = ActionID(unchecked: "computer.copySelection")
    public static let computerReconnect = ActionID(unchecked: "computer.reconnect")
    public static let computerShowPreview = ActionID(unchecked: "computer.showPreview")
    public static let computerAllowRequest = ActionID(unchecked: "computer.allowRequest")
    public static let computerAllowRequestSession = ActionID(unchecked: "computer.allowRequestSession")
    public static let computerDenyRequest = ActionID(unchecked: "computer.denyRequest")
    public static let computerRequestProxy = ActionID(unchecked: "computer.requestProxy")
    public static let computerRequestLeftovers = ActionID(unchecked: "computer.requestLeftovers")
    public static let computerKeepLeftovers = ActionID(unchecked: "computer.keepLeftovers")
    public static let computerDeleteLeftovers = ActionID(unchecked: "computer.deleteLeftovers")
    public static let computerStart = ActionID(unchecked: "computer.start")
    public static let computerStop = ActionID(unchecked: "computer.stop")
    public static let computerDelete = ActionID(unchecked: "computer.delete")
    public static let computerNew = ActionID(unchecked: "computer.new")
    public static let computerCopyId = ActionID(unchecked: "computer.copyId")
    public static let computerOpenShell = ActionID(unchecked: "computer.openShell")
    public static let computerCancel = ActionID(unchecked: "computer.cancel")
    public static let dockerStart = ActionID(unchecked: "docker.start")
    public static let dockerSettings = ActionID(unchecked: "docker.settings")
    public static let imageUpdate = ActionID(unchecked: "image.update")
    public static let imageBuildLocal = ActionID(unchecked: "image.buildLocal")
    public static let imageDownload = ActionID(unchecked: "image.download")
    public static let computersCleanUp = ActionID(unchecked: "computers.cleanUp")
    public static let computersRunOn = ActionID(unchecked: "computers.runOn")
    public static let computersWhereToggle = ActionID(unchecked: "computers.where.toggle")
    public static let computersCloudProvider = ActionID(unchecked: "computers.cloud.provider")
    public static let computersCloudRegion = ActionID(unchecked: "computers.cloud.region")
    public static let computersCloudLimits = ActionID(unchecked: "computers.cloud.limits")
    public static let computersCloudConnect = ActionID(unchecked: "computers.cloud.connect")
    public static let computersCloudStopHost = ActionID(unchecked: "computers.cloud.stopHost")
    public static let computersCloudSave = ActionID(unchecked: "computers.cloud.save")
    public static let computersCloudEdit = ActionID(unchecked: "computers.cloud.edit")
    public static let computersCloudCancel = ActionID(unchecked: "computers.cloud.cancel")
    public static let computerCleanAllLeftovers = ActionID(unchecked: "computer.cleanAllLeftovers")
    public static let computersLeftoversShowAll = ActionID(unchecked: "computers.leftovers.showAll")
    public static let computersCloudOpenLink = ActionID(unchecked: "computers.cloud.openLink")
    public static let batchNew = ActionID(unchecked: "batch.new")
    public static let batchOpen = ActionID(unchecked: "batch.open")
    public static let batchFilter = ActionID(unchecked: "batch.filter")
    public static let batchExportCSV = ActionID(unchecked: "batch.exportCSV")
    public static let batchExportJSON = ActionID(unchecked: "batch.exportJSON")
    public static let batchCollectAll = ActionID(unchecked: "batch.collectAll")
    public static let batchArchive = ActionID(unchecked: "batch.archive")
    public static let proxyAdd = ActionID(unchecked: "proxy.add")
    public static let proxyTest = ActionID(unchecked: "proxy.test")
    public static let proxyDelete = ActionID(unchecked: "proxy.delete")
    public static let proxyEdit = ActionID(unchecked: "proxy.edit")
    public static let proxySave = ActionID(unchecked: "proxy.save")
    public static let proxyCancel = ActionID(unchecked: "proxy.cancel")
    public static let proxyPreset = ActionID(unchecked: "proxy.preset")
    public static let proxyScheme = ActionID(unchecked: "proxy.scheme")
    public static let proxySetDefault = ActionID(unchecked: "proxy.setDefault")
    public static let proxyImportFromCLI = ActionID(unchecked: "proxy.importFromCLI")
    public static let settingsOpenSection = ActionID(unchecked: "settings.openSection")
    public static let settingsBack = ActionID(unchecked: "settings.back")
    public static let settingsGeneralKeepAgentsRunning = ActionID(unchecked: "settings.general.keepAgentsRunning")
    public static let settingsGeneralAllowLoginItems = ActionID(unchecked: "settings.general.allowLoginItems")
    public static let settingsGeneralAskBeforeQuit = ActionID(unchecked: "settings.general.askBeforeQuit")
    public static let settingsGeneralResumeAgentsOnOpen = ActionID(unchecked: "settings.general.resumeAgentsOnOpen")
    public static let settingsGeneralConfirmCloseTerminal = ActionID(unchecked: "settings.general.confirmCloseTerminal")
    public static let settingsGeneralConfirmDeleteSession = ActionID(unchecked: "settings.general.confirmDeleteSession")
    public static let settingsGeneralBranchPrefix = ActionID(unchecked: "settings.general.branchPrefix")
    public static let settingsGeneralBranchPrefixCustom = ActionID(unchecked: "settings.general.branchPrefixCustom")
    public static let settingsGeneralWorktreeFolder = ActionID(unchecked: "settings.general.worktreeFolder")
    public static let settingsGeneralCleanSessionFolder = ActionID(unchecked: "settings.general.cleanSessionFolder")
    public static let settingsGeneralProjectsFolder = ActionID(unchecked: "settings.general.projectsFolder")
    public static let settingsPickPath = ActionID(unchecked: "settings.pickPath")
    public static let settingsResetConfirmations = ActionID(unchecked: "settings.resetConfirmations")
    public static let settingsGeneralStorageCleanUp = ActionID(unchecked: "settings.general.storageCleanUp")
    public static let settingsGeneralComputerLeftovers = ActionID(unchecked: "settings.general.computerLeftovers")
    public static let settingsGeneralLeftoversOnCard = ActionID(unchecked: "settings.general.leftoversOnCard")
    public static let settingsGeneralArchivedWorktrees = ActionID(unchecked: "settings.general.archivedWorktrees")
    public static let settingsGeneralOldComputerImages = ActionID(unchecked: "settings.general.oldComputerImages")
    public static let settingsComputersDefaultSubagentMode = ActionID(unchecked: "settings.computers.defaultSubagentMode")
    public static let settingsComputersDefaultSubagentHarness = ActionID(unchecked: "settings.computers.defaultSubagentHarness")
    public static let settingsComputersForceDocker = ActionID(unchecked: "settings.computers.forceDocker")
    public static let settingsComputersGithubAccess = ActionID(unchecked: "settings.computers.githubAccess")
    public static let settingsAgentsDefaultAgent = ActionID(unchecked: "settings.agents.defaultAgent")
    public static let settingsAgentsDefaultProfile = ActionID(unchecked: "settings.agents.defaultProfile")
    public static let settingsAgentsProfileNew = ActionID(unchecked: "settings.agents.profileNew")
    public static let settingsAgentsProfileDuplicate = ActionID(unchecked: "settings.agents.profileDuplicate")
    public static let settingsAgentsProfileEdit = ActionID(unchecked: "settings.agents.profileEdit")
    public static let settingsAgentsProfileDelete = ActionID(unchecked: "settings.agents.profileDelete")
    public static let settingsAgentsProfileName = ActionID(unchecked: "settings.agents.profileName")
    public static let settingsAgentsProfilePermission = ActionID(unchecked: "settings.agents.profilePermission")
    public static let settingsAgentsProfileModel = ActionID(unchecked: "settings.agents.profileModel")
    public static let settingsAgentsProfileArgs = ActionID(unchecked: "settings.agents.profileArgs")
    public static let settingsTerminalFont = ActionID(unchecked: "settings.terminal.font")
    public static let settingsTerminalSize = ActionID(unchecked: "settings.terminal.size")
    public static let settingsTerminalTheme = ActionID(unchecked: "settings.terminal.theme")
    public static let settingsTerminalCursor = ActionID(unchecked: "settings.terminal.cursor")
    public static let settingsTerminalCursorBlink = ActionID(unchecked: "settings.terminal.cursorBlink")
    public static let settingsNotificationsNeedsInput = ActionID(unchecked: "settings.notifications.needsInput")
    public static let settingsNotificationsFinished = ActionID(unchecked: "settings.notifications.finished")
    public static let settingsNotificationsFailed = ActionID(unchecked: "settings.notifications.failed")
    public static let settingsNotificationsTerminalBell = ActionID(unchecked: "settings.notifications.terminalBell")
    public static let settingsNotificationsSuppressWhenVisible = ActionID(unchecked: "settings.notifications.suppressWhenVisible")
    public static let settingsNotificationsDockBadge = ActionID(unchecked: "settings.notifications.dockBadge")
    public static let settingsNotificationsSound = ActionID(unchecked: "settings.notifications.sound")
    public static let agentDetect = ActionID(unchecked: "agent.detect")
    public static let agentInstallHelp = ActionID(unchecked: "agent.installHelp")
    public static let onboardingRetry = ActionID(unchecked: "onboarding.retry")
    public static let onboardingCopyCommand = ActionID(unchecked: "onboarding.copyCommand")
    public static let onboardingKeepSettingUp = ActionID(unchecked: "onboarding.keepSettingUp")
    public static let onboardingConfirmSkip = ActionID(unchecked: "onboarding.confirmSkip")
    public static let onboardingSkip = ActionID(unchecked: "onboarding.skip")
    public static let onboardingDone = ActionID(unchecked: "onboarding.done")
    public static let paletteOpen = ActionID(unchecked: "palette.open")
    public static let paletteOpenRow = ActionID(unchecked: "palette.openRow")
    public static let paletteOpenInSplit = ActionID(unchecked: "palette.openInSplit")
    public static let paletteNewSessionWithText = ActionID(unchecked: "palette.newSessionWithText")
    public static let paletteCycleFilter = ActionID(unchecked: "palette.cycleFilter")
    public static let paletteInsertMode = ActionID(unchecked: "palette.insertMode")
    public static let composerSetProject = ActionID(unchecked: "composer.setProject")
    public static let composerSetWhere = ActionID(unchecked: "composer.setWhere")
    public static let composerSetBase = ActionID(unchecked: "composer.setBase")
    public static let composerReuseBranch = ActionID(unchecked: "composer.reuseBranch")
    public static let composerSetWorktree = ActionID(unchecked: "composer.setWorktree")
    public static let composerChooseFolder = ActionID(unchecked: "composer.chooseFolder")
    public static let composerSetAgent = ActionID(unchecked: "composer.setAgent")
    public static let composerSetDefaultAgent = ActionID(unchecked: "composer.setDefaultAgent")
    public static let composerManageAgents = ActionID(unchecked: "composer.manageAgents")
    public static let composerSetProfile = ActionID(unchecked: "composer.setProfile")
    public static let composerEditProfiles = ActionID(unchecked: "composer.editProfiles")
    public static let composerSetSubagentComputers = ActionID(unchecked: "composer.setSubagentComputers")
    public static let composerSetSubagentHarness = ActionID(unchecked: "composer.setSubagentHarness")
    public static let composerSetDataDestination = ActionID(unchecked: "composer.setDataDestination")
    public static let composerSetPrompt = ActionID(unchecked: "composer.setPrompt")
    public static let composerToggleAdvanced = ActionID(unchecked: "composer.toggleAdvanced")
    public static let composerSetSessionName = ActionID(unchecked: "composer.setSessionName")
    public static let composerSetBranchName = ActionID(unchecked: "composer.setBranchName")
    public static let composerChangeLocation = ActionID(unchecked: "composer.changeLocation")
    public static let composerCreateMore = ActionID(unchecked: "composer.createMore")
    public static let composerSubmit = ActionID(unchecked: "composer.submit")
    public static let composerCancel = ActionID(unchecked: "composer.cancel")
    public static let composerKeepEditing = ActionID(unchecked: "composer.keepEditing")
    public static let composerDiscard = ActionID(unchecked: "composer.discard")
    public static let dialogCloseTerminalConfirm = ActionID(unchecked: "dialog.closeTerminal.confirm")
    public static let dialogCloseTerminalCancel = ActionID(unchecked: "dialog.closeTerminal.cancel")
    public static let dialogCloseTerminalDontAsk = ActionID(unchecked: "dialog.closeTerminal.dontAsk")
    public static let dialogArchiveConfirm = ActionID(unchecked: "dialog.archive.confirm")
    public static let dialogArchiveCancel = ActionID(unchecked: "dialog.archive.cancel")
    public static let dialogArchiveBatchConfirm = ActionID(unchecked: "dialog.archiveBatch.confirm")
    public static let dialogArchiveBatchCancel = ActionID(unchecked: "dialog.archiveBatch.cancel")
    public static let dialogStopComputerConfirm = ActionID(unchecked: "dialog.stopComputer.confirm")
    public static let dialogStopComputerCancel = ActionID(unchecked: "dialog.stopComputer.cancel")
    public static let dialogRestartAgentsConfirm = ActionID(unchecked: "dialog.restartAgents.confirm")
    public static let dialogRestartAgentsCancel = ActionID(unchecked: "dialog.restartAgents.cancel")
    public static let dialogDeleteComputerConfirm = ActionID(unchecked: "dialog.deleteComputer.confirm")
    public static let dialogDeleteSessionConfirm = ActionID(unchecked: "dialog.deleteSession.confirm")
    public static let dialogDeleteSessionCancel = ActionID(unchecked: "dialog.deleteSession.cancel")
    public static let dialogDeleteSessionKeepBranch = ActionID(unchecked: "dialog.deleteSession.keepBranch")
    public static let dialogDeleteSessionTrashFolder = ActionID(unchecked: "dialog.deleteSession.trashFolder")
    public static let dialogDeleteSessionDeleteRuns = ActionID(unchecked: "dialog.deleteSession.deleteRuns")
    public static let dialogDeleteSessionDontAsk = ActionID(unchecked: "dialog.deleteSession.dontAsk")
    public static let dialogRemoveProjectConfirm = ActionID(unchecked: "dialog.removeProject.confirm")
    public static let dialogRemoveProjectCancel = ActionID(unchecked: "dialog.removeProject.cancel")
    public static let dialogResumeAgentsConfirm = ActionID(unchecked: "dialog.resumeAgents.confirm")
    public static let dialogResumeAgentsCancel = ActionID(unchecked: "dialog.resumeAgents.cancel")
    public static let dialogResumeAgentsSelectAll = ActionID(unchecked: "dialog.resumeAgents.selectAll")
    public static let dialogResumeAgentsSelectNone = ActionID(unchecked: "dialog.resumeAgents.selectNone")
    public static let dialogResumeAgentsToggleRow = ActionID(unchecked: "dialog.resumeAgents.toggleRow")
    public static let dialogMoveToProjectConfirm = ActionID(unchecked: "dialog.moveToProject.confirm")
    public static let dialogMoveToProjectSetProject = ActionID(unchecked: "dialog.moveToProject.setProject")
    public static let dialogMoveToProjectCancel = ActionID(unchecked: "dialog.moveToProject.cancel")
    public static let dialogAddProjectAddFound = ActionID(unchecked: "dialog.addProject.addFound")
    public static let dialogAddProjectStopScan = ActionID(unchecked: "dialog.addProject.stopScan")
    public static let dialogCloneRepoSetSource = ActionID(unchecked: "dialog.cloneRepo.setSource")
    public static let dialogCloneRepoSelect = ActionID(unchecked: "dialog.cloneRepo.select")
    public static let dialogCloneRepoSubmit = ActionID(unchecked: "dialog.cloneRepo.submit")
    public static let dialogCloneRepoCancel = ActionID(unchecked: "dialog.cloneRepo.cancel")
    public static let dialogCloneRepoLogIn = ActionID(unchecked: "dialog.cloneRepo.logIn")
    public static let dialogCloneRepoRetry = ActionID(unchecked: "dialog.cloneRepo.retry")
    public static let dialogCreatePRSetTitle = ActionID(unchecked: "dialog.createPR.setTitle")
    public static let dialogCreatePRSetBase = ActionID(unchecked: "dialog.createPR.setBase")
    public static let dialogCreatePRSetBody = ActionID(unchecked: "dialog.createPR.setBody")
    public static let dialogCreatePRSetDraft = ActionID(unchecked: "dialog.createPR.setDraft")
    public static let dialogCreatePRSubmit = ActionID(unchecked: "dialog.createPR.submit")
    public static let dialogCreatePRCancel = ActionID(unchecked: "dialog.createPR.cancel")
    public static let dialogCreatePRRetry = ActionID(unchecked: "dialog.createPR.retry")
    public static let dialogCreatePROpenCompare = ActionID(unchecked: "dialog.createPR.openCompare")
    public static let dialogQuitKeepRunning = ActionID(unchecked: "dialog.quit.keepRunning")
    public static let dialogQuitStopAll = ActionID(unchecked: "dialog.quit.stopAll")
    public static let dialogQuitStopAllConfirm = ActionID(unchecked: "dialog.quit.stopAllConfirm")
    public static let dialogQuitCancel = ActionID(unchecked: "dialog.quit.cancel")
    public static let dialogQuitDontAsk = ActionID(unchecked: "dialog.quit.dontAsk")
    public static let dialogSkipPermissionsConfirm = ActionID(unchecked: "dialog.skipPermissions.confirm")
    public static let dialogPasteToAgentConfirm = ActionID(unchecked: "dialog.pasteToAgent.confirm")
    public static let dialogRenameBranchConfirm = ActionID(unchecked: "dialog.renameBranch.confirm")
    public static let dialogAboutLicenses = ActionID(unchecked: "dialog.about.licenses")
    public static let dialogAboutCopy = ActionID(unchecked: "dialog.about.copy")
    public static let dialogNewBatchConfirm = ActionID(unchecked: "dialog.newBatch.confirm")
    public static let dialogNewBatchImportCSV = ActionID(unchecked: "dialog.newBatch.importCSV")
    public static let dialogNewBatchSetTargets = ActionID(unchecked: "dialog.newBatch.setTargets")
    public static let dialogNewBatchSetBrief = ActionID(unchecked: "dialog.newBatch.setBrief")
    public static let dialogNewBatchSetDisplay = ActionID(unchecked: "dialog.newBatch.setDisplay")
    public static let dialogNewBatchSetProxy = ActionID(unchecked: "dialog.newBatch.setProxy")
    public static let dialogNewBatchToggleProxy = ActionID(unchecked: "dialog.newBatch.toggleProxy")
    public static let dialogNewBatchSetSession = ActionID(unchecked: "dialog.newBatch.setSession")
    public static let dialogNewBatchCancel = ActionID(unchecked: "dialog.newBatch.cancel")
    public static let rightPanelToggleFiles = ActionID(unchecked: "rightPanel.toggleFiles")
    public static let rightPanelToggleInsights = ActionID(unchecked: "rightPanel.toggleInsights")
    public static let rightPanelToggleData = ActionID(unchecked: "rightPanel.toggleData")
    public static let rightPanelToggleComputers = ActionID(unchecked: "rightPanel.toggleComputers")
    public static let rightPanelComputersPick = ActionID(unchecked: "rightPanel.computersPick")
    public static let computerOpenTraffic = ActionID(unchecked: "computer.openTraffic")
    public static let trafficSet = ActionID(unchecked: "traffic.set")
    public static let trafficCopyCurl = ActionID(unchecked: "traffic.copyCurl")
    public static let rightPanelDataPick = ActionID(unchecked: "rightPanel.dataPick")
    public static let rightPanelToggle = ActionID(unchecked: "rightPanel.toggle")
    public static let rightPanelMinimize = ActionID(unchecked: "rightPanel.minimize")
    public static let rightPanelMove = ActionID(unchecked: "rightPanel.move")
    public static let rightPanelSwap = ActionID(unchecked: "rightPanel.swap")
    public static let rightPanelSetWidth = ActionID(unchecked: "rightPanel.setWidth")
    public static let rightPanelSetSplit = ActionID(unchecked: "rightPanel.setSplit")
    public static let filesOpen = ActionID(unchecked: "files.open")
    public static let filesOpenExternal = ActionID(unchecked: "files.openExternal")
    public static let filesCloseFile = ActionID(unchecked: "files.closeFile")
    public static let filesTogglePin = ActionID(unchecked: "files.togglePin")
    public static let filesShowSessionFolder = ActionID(unchecked: "files.showSessionFolder")
    public static let filesToggleIgnored = ActionID(unchecked: "files.toggleIgnored")
    public static let filesRefresh = ActionID(unchecked: "files.refresh")
    public static let filesFind = ActionID(unchecked: "files.find")
    public static let filesFindNext = ActionID(unchecked: "files.findNext")
    public static let filesFindPrevious = ActionID(unchecked: "files.findPrevious")
    public static let filesFindClose = ActionID(unchecked: "files.findClose")
    public static let filesCopyPath = ActionID(unchecked: "files.copyPath")
    public static let filesOpenIn = ActionID(unchecked: "files.openIn")
    public static let filesOpenInTarget = ActionID(unchecked: "files.openInTarget")
    public static let insightsShowExactLimits = ActionID(unchecked: "insights.showExactLimits")
}

extension ActionID {
    /// Índice completo (03 §24).
    public static let catalog: [ActionSpec] = [
        ActionSpec(id: ActionID(unchecked: "app.about"), label: "About Racky", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.settings"), label: "Settings…", shortcut: "⌘,", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.setup"), label: "Set Up Racky… / Run Diagnostics", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.checkProblems"), label: "Check for Problems", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.hideAppName"), label: "Hide App Name", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.quit"), label: "Quit Racky", shortcut: "⌘Q", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.quitCompletely"), label: "Quit Racky Completely", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.openMainWindow"), label: "Open Racky (barra de menus)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.stopAllAgents"), label: "Stop All Agents… (barra de menus)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "view.toggleSidebar"), label: "Toggle Sidebar", shortcut: "⌘B", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "view.toggleRightPanel"), label: "Right Panel", shortcut: "⌘L (Fatia 2)", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "view.toggleStatusBar"), label: "Show Status Bar", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "statusBar.openSegment"), label: "Status bar: abrir", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "statusBar.toggleSegment"), label: "mostrar-esconder segmento", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "nav.back"), label: "Back", shortcut: "⌥⌘←", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "nav.forward"), label: "Forward", shortcut: "⌥⌘→", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.fontBigger"), label: "Bigger", shortcut: "⌘=", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.fontSmaller"), label: "Smaller", shortcut: "⌘-", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.fontReset"), label: "Actual Size", shortcut: "⌘0", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "sidebar.hideNavItem"), label: "Hide from Sidebar", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "help.open"), label: "Racky Help", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "help.shortcuts"), label: "Keyboard Shortcuts", shortcut: "⌘/", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "help.revealLogs"), label: "Reveal Logs in Finder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "help.exportDiagnostics"), label: "Export Diagnostics…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.openDiagnostics"), label: "Open Diagnostics", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "diagnostics.saveExport"), label: "Save Diagnostics", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "diagnostics.cancelExport"), label: "Cancel Export", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "diagnostics.dismissCrash"), label: "Dismiss Crash", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.restartBackgroundService"), label: "Restart Background Service", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.errorTryAgain"), label: "Try Again", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.copyDetails"), label: "Copy Details (região com erro)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "app.revealCorruptFile"), label: "Reveal Corrupt File", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.new"), label: "New Session…", shortcut: "⌘N", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.newClean"), label: "New Clean Session", shortcut: "⇧⌘N", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.newCleanInFolder"), label: "New Clean Session in Folder…", shortcut: "⌥⇧⌘N", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.add"), label: "Add Project…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.setSubagentComputers"), label: "Subagent computers (card, header do pane)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "session.setSubagentHarness"), label: "Subagents run as (card, header do pane)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "agent.toggleChildren"), label: "Collapse / Expand Subagents (chevron da linha do agente)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "session.restartToApply"), label: "Restart to apply", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "project.cloneFromGitHub"), label: "Clone from GitHub…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "sidebar.sortFilter"), label: "Sort and Filter", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "sidebar.resetFilters"), label: "Reset", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "sidebar.clearSearch"), label: "Clear Search", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "sidebar.clearFilters"), label: "Clear Filters", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.showMore"), label: "Show <n> more", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.newSession"), label: "New Session in <project>…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.newSessionFromRef"), label: "from Branch or PR…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.openInEditor"), label: "Open in Editor", shortcut: "⇧⌘O", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.revealInFinder"), label: "Reveal in Finder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.copyPath"), label: "Copy Path", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.openOnGitHub"), label: "Open on GitHub", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.copyBranch"), label: "Copy Branch Name", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.collapseAll"), label: "Collapse All Sessions", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.hide"), label: "Hide Project", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.rename"), label: "Rename Project…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "project.remove"), label: "Remove Project…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.refreshGit"), label: "Refresh Git (⌥)", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.copyId"), label: "Copy Project/Session ID (⌥)", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.showLaunchDetails"), label: "Show Launch Details (⌥)", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.rename"), label: "Rename…", shortcut: "⌥⌘R", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.renameBranch"), label: "Rename Branch… (⌥)", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.editNote"), label: "Edit Note…", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "session.markRead"), label: "Mark as Read", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "session.markUnread"), label: "Unread", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "session.mute"), label: "Mute", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "session.unmute"), label: "Unmute Notifications", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "session.pin"), label: "Pin / Unpin Session", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "session.resumeAgents"), label: "Resume Agents…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.moveToProject"), label: "Move to Project…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.convertToProject"), label: "Convert to Project…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.moveFolderIntoProject"), label: "Move Folder into Project…", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "session.archive"), label: "Archive Session…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.delete"), label: "Delete Session…", shortcut: "⇧⌘⌫", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.restore"), label: "Restore Session", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.undoArchive"), label: "Undo (toast `Session archived.`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.undoDelete"), label: "Undo (toast `Session deleted.`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.openIn"), label: "Open in…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "item.openInTarget"), label: "Open in <app> (item do menu `Open in…`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.locateFolder"), label: "Locate Folder…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "sidebar.revealCurrent"), label: "Reveal Current Session", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.nextNeedingAttention"), label: "Next Needing Attention", shortcut: "⇧⌘A", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "session.previous"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.next"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select1"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘1", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select2"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘2", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select3"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘3", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select4"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘4", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select5"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘5", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select6"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘6", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select7"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘7", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select8"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘8", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select9"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⌘9", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "sidebar.focus"), label: "Previous / Next Session, Select Session 1–9, Focus Session List", shortcut: "⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.select"), label: "Select Session (clique no card)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.toggleAgents"), label: "Expand / Collapse Agent Rows (pílula-resumo, → / ← no card)", shortcut: "→ / ←", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "child.askParentToRelaunch"), label: "Ask Parent to Relaunch", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "child.showTranscript"), label: "Show Transcript", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "child.showComputer"), label: "Show Computer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "child.copyId"), label: "Copy Agent ID", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "child.message"), label: "Message…", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "child.stop"), label: "Stop Subagent", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "sidebar.search"), label: "Search (campo da sidebar)", shortcut: "⌘F (sidebar focada)", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "sidebar.project.toggle"), label: "Expand / Collapse Project (clique na linha)", shortcut: "→ / ←", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.cancelLaunch"), label: "Cancel (linha pendente, PhaseList e ignição)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.retryLaunch"), label: "Try Again (criação da sessão)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.resumeStopped"), label: "Resume All (agentes parados com o app fechado)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.useExistingBranch"), label: "Use Existing Branch", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.createWithoutFetch"), label: "Create Without Fetching", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.discardPending"), label: "Discard (sessão que falhou ao criar)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "session.launch"), label: "Launch Session (automação)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.quickLaunch"), label: "New Tab… (Quick Launch)", shortcut: "⌥⌘N", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.newAgent"), label: "New Agent Tab", shortcut: "⌥⌘T", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.newTerminal"), label: "New Terminal", shortcut: "⌘T", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.newWithAgent"), label: "New <Agent> Tab (Quick Launch, New Tab ▸)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.newWithPrompt"), label: "Start <agent> with '<text>'", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.close"), label: "Close Pane", shortcut: "⌘W", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.close"), label: "Close Tab", shortcut: "⌘W (1 pane)", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.closeOthers"), label: "Close Other Tabs", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.closeRight"), label: "Tabs to the Right", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.reopen"), label: "Reopen Closed Tab", shortcut: "⇧⌘T", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "window.close"), label: "Close Window", shortcut: "⇧⌘W", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.next"), label: "Next", shortcut: "⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.previous"), label: "Previous", shortcut: "⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.recent"), label: "Recent Tab, Select Tab 1–9", shortcut: "⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select1"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃1", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select2"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃2", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select3"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃3", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select4"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃4", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select5"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃5", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select6"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃6", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select7"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃7", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select8"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃8", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.select9"), label: "Next / Previous / Recent Tab, Select Tab 1–9", shortcut: "⌃9", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.rename"), label: "Rename…", shortcut: "⌘R", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.resetTitle"), label: "Reset Title", shortcut: "⌘R", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.splitRight"), label: "Split Right", shortcut: "⌘D", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.splitDown"), label: "Down", shortcut: "⇧⌘D", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.next"), label: "Next", shortcut: "⌘]", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.previous"), label: "Previous Pane", shortcut: "⌘[", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.toggleExpand"), label: "Expand / Collapse Pane", shortcut: "⇧⌘↵", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.equalize"), label: "Equalize Pane Sizes", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.closeOthers"), label: "Close Other Panes", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.show"), label: "Show Pane", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.restart"), label: "Restart", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.restartWithProfile"), label: "Restart with ▸", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.resume"), label: "Resume Conversation", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.startFresh"), label: "Start Fresh", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.copyResumeCommand"), label: "Copy Resume Command", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.copyId"), label: "Copy Terminal", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.copyConversationId"), label: "Conversation", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.copyId"), label: "Pane ID (⌥)", shortcut: "⌥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.showHookLog"), label: "Show Hook Log (⌥)", shortcut: "⌥", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "terminal.sendInterrupt"), label: "Send Interrupt (⌃C)", shortcut: "⌃C", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.sendText"), label: "Send Text", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.screen"), label: "Screen (automação, sem UI)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.forceQuit"), label: "Force Quit Process… / Force Quit", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.open"), label: "Find…", shortcut: "⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.next"), label: "Next", shortcut: "⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.previous"), label: "Previous", shortcut: "⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.close"), label: "Close", shortcut: "⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.clear"), label: "Clear Terminal", shortcut: "⌘K", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "edit.copy"), label: "Copy", shortcut: "⌘C", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "edit.paste"), label: "Paste", shortcut: "⌘V", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "edit.selectAll"), label: "Select All", shortcut: "⌘A", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.openLink"), label: "Open Link", shortcut: "⌘-clique", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.copyLink"), label: "Copy Link", shortcut: "⌘-clique", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.openFile"), label: "Open File", shortcut: "⌘-clique", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.openComputer"), label: "Open Computer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "terminal.openElsewhere"), label: "Open in another terminal", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "prompt.insertSkillOrAgent"), label: "Insert Skill or Agent…", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "prompt.insertItem"), label: "Insert in Prompt", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "tab.quickCommands"), label: "Quick Commands", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "tabs.paneActions"), label: "Pane Actions (menu ⋯ da tab row)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.reorder"), label: "Reorder Tab (arrastar na tab row)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.dropOnPane"), label: "Drop Tab on Pane (arrastar tab para a área de panes)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.move"), label: "Move Pane (arrastar o cabeçalho sobre outro pane)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.detach"), label: "Detach Pane to Tab (arrastar o cabeçalho para a tab row)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "pane.resizeDivider"), label: "Resize Divider (arrastar o divisor)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.caseSensitive"), label: "Case Sensitive (busca no terminal)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.regex"), label: "Regex (busca no terminal)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "find.query"), label: "Search field e contador (busca no terminal)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.retryStart"), label: "Try Again (agente não iniciou)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "agent.openSettings"), label: "Open Agent Settings", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.copyStartError"), label: "Copy Details (agente não iniciou)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "terminal.cancelClose"), label: "Cancel (fechando, `The process didn't exit.`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "tab.quickLaunchResume"), label: "Resume a Conversation… (Quick Launch)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "panel.sourceControl"), label: "Source Control", shortcut: "⇧⌘G / ⇧⌘C / ⇧⌘H", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "panel.checks"), label: "Checks", shortcut: "⇧⌘G / ⇧⌘C / ⇧⌘H", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "panel.computers"), label: "Computers Panel", shortcut: "⇧⌘G / ⇧⌘C / ⇧⌘H", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "panel.conversations"), label: "Conversations", shortcut: "⇧⌘G / ⇧⌘C / ⇧⌘H", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "panel.context"), label: "Context", shortcut: "⇧⌘G / ⇧⌘C / ⇧⌘H", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "panel.refresh"), label: "Refresh (Source Control, Checks)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "git.createPR"), label: "Create Pull Request…", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "git.openPR"), label: "Open on GitHub", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "git.copyPRURL"), label: "Copy URL (PR)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "git.openChange"), label: "Abrir arquivo alterado (Source Control, §10.2)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "git.openCheck"), label: "Abrir check (Checks, §10.3)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "account.logIn"), label: "Log In (gh, Claude, Codex)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "checks.sendFailures"), label: "Send Failures to Claude Code", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "conversation.resume"), label: "Resume in New Tab / in Split, Show Transcript", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.resumeSplit"), label: "Resume in New Tab / in Split, Show Transcript", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.showTranscript"), label: "Resume in New Tab / in Split, Show Transcript", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.menu"), label: "Menu da conversa", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.copyResumeCommand"), label: "Copy Resume Command", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.copyId"), label: "Copy Conversation ID", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.setScope"), label: "Escopo", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.setQuery"), label: "Busca", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conversation.back"), label: "Voltar do transcript", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "context.restartWithResume"), label: "Restart Agents with Resume", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "context.toggleItem"), label: "Toggle item in this session", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "page.library"), label: "Open Library / Library", shortcut: "⇧⌘L", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "page.computers"), label: "Computers (página)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "page.datasets"), label: "Datasets (página)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.open"), label: "Open Dataset", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.filter"), label: "Dataset: filtro", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.search"), label: "busca", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.selectRow"), label: "linha", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.loadMore"), label: "Load more", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.export"), label: "Export Dataset", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.notebook"), label: "Open in Notebook", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "notebook.toggleDataset"), label: "Notebook: dataset", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "notebook.addDataset"), label: "Notebook: soltar dataset", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "notebook.apply"), label: "Notebook: carregar", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "notebook.openBeside"), label: "Notebook: ao lado do agente", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dataset.openSource"), label: "Open Source URL", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.range"), label: "Dataset: período", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.facet"), label: "Dataset: faceta", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.timeWindow"), label: "Dataset: janela do gráfico", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.addFilter"), label: "Dataset: adicionar filtro", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.removeFilter"), label: "Dataset: remover filtro", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.columnRange"), label: "Dataset: faixa da coluna", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.facetsReset"), label: "Dataset: limpar filtros", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "data.open"), label: "Data: abrir", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.close"), label: "fechar objeto", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.toggleNode"), label: "Data: expandir nó", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.newQuery"), label: "nova consulta", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.tableTab"), label: "Data: sub-aba da tabela", shortcut: "⌘↩ (consulta)", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.queryRun"), label: "rodar consulta", shortcut: "⌘↩ (consulta)", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.addConnection"), label: "Data: adicionar conexão", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.sendTo"), label: "enviar para", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.webhookTest"), label: "testar webhook", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.pauseWriter"), label: "Data: pausar quem grava", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.toggleExplorer"), label: "Data: mostrar/recolher o explorer", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.renameDataset"), label: "Data: renomear dataset", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.tablePage"), label: "Data: página da tabela", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.connectStart"), label: "Data: conectar (começar)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.connectSave"), label: "Data: conectar (salvar)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.connectionRemove"), label: "Data: remover conexão", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.s3Page"), label: "Data: página da pasta S3", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "data.runsFilter"), label: "Data: filtro dos flow runs", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dataset.page"), label: "Dataset: página", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.columns"), label: "Dataset: colunas", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.copyRow"), label: "Copy Row JSON", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dataset.panelTab"), label: "Dataset: aba do painel", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "page.sessions"), label: "Sessions", shortcut: "⇧⌘I", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "page.inbox"), label: "Inbox (legado)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "page.close"), label: "Close page", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "inbox.markRead"), label: "Mark as Read", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "inbox.markAllRead"), label: "Mark All as Read", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "inbox.filter"), label: "Inbox: filtro", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "notifications.request"), label: "Allow Notifications", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "app.openSystemSettings"), label: "Open System Settings", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "notification.open"), label: "Open (notificação)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.testNotification"), label: "Send Test Notification", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "notifications.pause"), label: "Pause / Resume Notifications for 1 Hour", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "library.newSessionWith"), label: "Library: New Session with Agent / Profile", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.toggleInSession"), label: "Library: Enable / Disable in This Session", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.openInEditor"), label: "Library: Open in Editor", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.reveal"), label: "Reveal in Finder", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.setSection"), label: "Library: seção", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.setSearch"), label: "busca", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.setSource"), label: "fonte", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.selectItem"), label: "item", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.editProfiles"), label: "Library: Edit Profiles…", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "profile.new"), label: "Library: New Profile", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "profile.duplicate"), label: "Duplicate", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "profile.delete"), label: "Delete…", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "library.newAgent"), label: "Library: New Agent…", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "library.importSkill"), label: "Import Skill Folder…", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "library.edit"), label: "Edit", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "conflict.block"), label: "Block in Racky", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conflict.disableGlobal"), label: "Disable Globally…", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conflict.keep"), label: "Keep", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "conflict.restore"), label: "Restore Skill", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "computer.openViewer"), label: "Open Viewer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.popOut"), label: "Open in New Window", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.takeOver"), label: "Take Over", shortcut: "⇧⌘R", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.handBack"), label: "Hand Back", shortcut: "⇧⌘R", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.forceTakeOver"), label: "Force Take Over", shortcut: "⇧⌘R", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.declineHelp"), label: "Decline… (pedido de ajuda)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.releaseKeyboard"), label: "Release Keyboard", shortcut: "⌘⎋ / ⌃⌥", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.showTab"), label: "Show Network / Journal / Files / Timeline / Result", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.openRunFolder"), label: "Open Run Folder", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.revealResult"), label: "Reveal Result in Finder", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.openEvidence"), label: "Open Evidence", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.setDisplay"), label: "Change type (HTTP/Headless/Desktop)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.setProxy"), label: "Proxy ▸", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.paste"), label: "Paste to Computer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.copySelection"), label: "Copy Selection from Computer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.reconnect"), label: "Reconnect", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.showPreview"), label: "Show Preview (hover card do subagente)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.allowRequest"), label: "Allow", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.allowRequestSession"), label: "Allow for this session", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.denyRequest"), label: "Deny (pedido de computador)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.requestProxy"), label: "Escolher o proxy do pedido de computador", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.requestLeftovers"), label: "Escolher o que sai do computador", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.keepLeftovers"), label: "Keep", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.deleteLeftovers"), label: "Delete now (Left on disk)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.start"), label: "Start Computer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.stop"), label: "Stop Computer…", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.delete"), label: "Delete Computer…", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.new"), label: "New Computer…", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.copyId"), label: "Copy Computer ID", shortcut: "⌥", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.openShell"), label: "Open Shell (⌥)", shortcut: "⌥", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computer.cancel"), label: "Cancel (fila, provisionando)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "docker.start"), label: "Start Docker", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "docker.settings"), label: "Docker Settings", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "image.update"), label: "Update", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "image.buildLocal"), label: "Build Locally", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "image.download"), label: "Download (imagem)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computers.cleanUp"), label: "Clean Up…", shortcut: "", slice: .v11),
        ActionSpec(id: ActionID(unchecked: "computers.runOn"), label: "Where computers run", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.where.toggle"), label: "Show where computers run", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.provider"), label: "Cloud provider", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.region"), label: "Cloud region", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.limits"), label: "Cloud limits", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.connect"), label: "Connect cloud account", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.stopHost"), label: "Stop cloud host", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.save"), label: "Save cloud setup", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.edit"), label: "Edit cloud setup", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.cancel"), label: "Cancel cloud setup", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "computer.cleanAllLeftovers"), label: "Delete all left on disk", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computers.leftovers.showAll"), label: "Show all left on disk", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "computers.cloud.openLink"), label: "Open provider link", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "batch.new"), label: "New Batch…", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "batch.open"), label: "Open Batch", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "batch.filter"), label: "Filter", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "batch.exportCSV"), label: "Export CSV", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "batch.exportJSON"), label: "Export JSON", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "batch.collectAll"), label: "Collect All", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "batch.archive"), label: "Archive Batch", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.add"), label: "Add Proxy", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.test"), label: "Test Proxy", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.delete"), label: "Delete…", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.edit"), label: "Edit Proxy", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.save"), label: "Save Proxy", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.cancel"), label: "Cancel (proxy)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.preset"), label: "Preset", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.scheme"), label: "Type", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.setDefault"), label: "Default proxy (proxy)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "proxy.importFromCLI"), label: "Import from racky CLI…", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "settings.openSection"), label: "Seção do Settings (nav)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.back"), label: "Back to App", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.keepAgentsRunning"), label: "Keep agents running when you quit", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.allowLoginItems"), label: "Allow in Login Items", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.askBeforeQuit"), label: "Ask before quitting with running agents", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.resumeAgentsOnOpen"), label: "Resume agents automatically when Racky opens", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.confirmCloseTerminal"), label: "Confirm before closing a running terminal", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.confirmDeleteSession"), label: "Confirm before deleting a session", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.branchPrefix"), label: "Branch prefix", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.branchPrefixCustom"), label: "Branch prefix", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.worktreeFolder"), label: "Worktree folder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.cleanSessionFolder"), label: "Clean session folder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.projectsFolder"), label: "Projects folder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.pickPath"), label: "Change…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.resetConfirmations"), label: "Reset", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.storageCleanUp"), label: "Space used › Clean up now", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.computerLeftovers"), label: "What computers leave behind", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.leftoversOnCard"), label: "Choose on the approval card", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.archivedWorktrees"), label: "Worktrees of archived sessions", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.general.oldComputerImages"), label: "Old computer images", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.computers.defaultSubagentMode"), label: "Subagent computers (padrão das novas sessões)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "settings.computers.defaultSubagentHarness"), label: "Subagents run as (padrão das novas sessões)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "settings.computers.forceDocker"), label: "Use Docker instead (runtime dos computadores)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.computers.githubAccess"), label: "Git from computers (GitHub)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.defaultAgent"), label: "Default agent", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.defaultProfile"), label: "Default profile", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileNew"), label: "New Profile", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileDuplicate"), label: "Duplicate", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileEdit"), label: "Edit", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileDelete"), label: "Delete", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileName"), label: "Profile name", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profilePermission"), label: "Permissions", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileModel"), label: "Model", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.agents.profileArgs"), label: "Extra flags", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.terminal.font"), label: "Font", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.terminal.size"), label: "Size", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.terminal.theme"), label: "Theme", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.terminal.cursor"), label: "Cursor", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.terminal.cursorBlink"), label: "Cursor", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.needsInput"), label: "Agent needs input", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.finished"), label: "Agent finished", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.failed"), label: "Agent failed", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.terminalBell"), label: "Terminal bell", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.suppressWhenVisible"), label: "Suppress when the session is visible", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.dockBadge"), label: "Dock badge", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "settings.notifications.sound"), label: "Notification sound", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "agent.detect"), label: "Detect Again / Check Again", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "agent.installHelp"), label: "Install…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "onboarding.retry"), label: "Try Again", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "onboarding.copyCommand"), label: "Copy Command", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "onboarding.keepSettingUp"), label: "Keep Setting Up", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "onboarding.confirmSkip"), label: "Skip (confirmação do onboarding)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "onboarding.skip"), label: "Skip for Now", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "onboarding.done"), label: "Done", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "palette.open"), label: "Jump To… (abrir a palette)", shortcut: "⌘J", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "palette.openRow"), label: "Open Row", shortcut: "↵", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "palette.openInSplit"), label: "Open in Split", shortcut: "⇧↵", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "palette.newSessionWithText"), label: "New Session '<text>' / Start with prompt", shortcut: "⌘↵", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "palette.cycleFilter"), label: "Cycle filter", shortcut: "⇥", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "palette.insertMode"), label: "Insert mode (`/`)", shortcut: "`/` no início do campo", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "composer.setProject"), label: "Project (combobox)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setWhere"), label: "Where (segmented)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setBase"), label: "Create from (campo, base e chip `Branch exists`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.reuseBranch"), label: "Reuse existing branch (chip e link `Reuse it`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setWorktree"), label: "Worktree (combobox, Existing Worktree)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.chooseFolder"), label: "Folder `[Choose…]`", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setAgent"), label: "Agent (combobox)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setDefaultAgent"), label: "Set as Default (agente)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.manageAgents"), label: "Manage Agents… (rodapé do combobox de agente)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setProfile"), label: "Profile (combobox)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.editProfiles"), label: "Edit Profiles… (rodapé do combobox de perfil)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setSubagentComputers"), label: "Subagent computers (segmented)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "composer.setSubagentHarness"), label: "Subagents run as (segmented)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "composer.setDataDestination"), label: "Save data to", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setPrompt"), label: "Prompt", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.toggleAdvanced"), label: "Advanced (disclosure)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setSessionName"), label: "Session name", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.setBranchName"), label: "Branch name", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.changeLocation"), label: "Worktree location `[Change…]`", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.createMore"), label: "Create More (switch)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.submit"), label: "Create Session", shortcut: "⌘↵ (de qualquer campo)", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.cancel"), label: "Cancel", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.keepEditing"), label: "Keep Editing", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "composer.discard"), label: "Discard (confirmação inline)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.closeTerminal.confirm"), label: "Close Terminal (confirma §16.1, inclui `Close <n> terminals?`)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.closeTerminal.cancel"), label: "Cancel (§16.1)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.closeTerminal.dontAsk"), label: "Don't ask again (§16.1)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.archive.confirm"), label: "Archive (§16.2)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.archive.cancel"), label: "Cancel (§16.2)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.archiveBatch.confirm"), label: "Archive Batch", shortcut: "Esc", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.archiveBatch.cancel"), label: "Cancel (confirmação com filhos rodando: `Stop <n> running subagents?`)", shortcut: "Esc", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.stopComputer.confirm"), label: "Stop Computer", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.stopComputer.cancel"), label: "Cancel (§16.3)", shortcut: "Esc", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.restartAgents.confirm"), label: "Restart Agents", shortcut: "", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "dialog.restartAgents.cancel"), label: "Cancel (aba Context, §10.6)", shortcut: "Esc", slice: .slice4),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteComputer.confirm"), label: "Delete Computer (§16.4)", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteSession.confirm"), label: "Delete Session (§16.5)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteSession.cancel"), label: "Cancel (§16.5)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteSession.keepBranch"), label: "Keep the branch", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteSession.trashFolder"), label: "Move folder to Trash", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteSession.deleteRuns"), label: "Also delete run folders (§16.5)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.deleteSession.dontAsk"), label: "Don't ask again (§16.5)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.removeProject.confirm"), label: "Remove Project (§16.6)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.removeProject.cancel"), label: "Cancel (§16.6)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.resumeAgents.confirm"), label: "Resume <n>", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.resumeAgents.cancel"), label: "Not Now (§16.7)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.resumeAgents.selectAll"), label: "Select All", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.resumeAgents.selectNone"), label: "Select None", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.resumeAgents.toggleRow"), label: "linha com checkbox (§16.7)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.moveToProject.confirm"), label: "Move / Convert (§16.8)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.moveToProject.setProject"), label: "Project (combobox, §16.8)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.moveToProject.cancel"), label: "Cancel (§16.8)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.addProject.addFound"), label: "Add <n> Projects", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.addProject.stopScan"), label: "Stop Scan (§16.9)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.cloneRepo.setSource"), label: "Campo `owner/repo` ou URL (§16.9b)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.cloneRepo.select"), label: "Linha de repositório (§16.9b)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.cloneRepo.submit"), label: "Clone (§16.9b)", shortcut: "↵", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.cloneRepo.cancel"), label: "Cancel (§16.9b)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.cloneRepo.logIn"), label: "Log in to GitHub (§16.9b)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.cloneRepo.retry"), label: "Try Again (§16.9b)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.setTitle"), label: "Título (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.setBase"), label: "Base (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.setBody"), label: "Descrição (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.setDraft"), label: "Draft (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.submit"), label: "Create (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.cancel"), label: "Cancel (§16.9c)", shortcut: "Esc", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.retry"), label: "Try Again (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.createPR.openCompare"), label: "Open Compare on GitHub (§16.9c)", shortcut: "", slice: .slice2),
        ActionSpec(id: ActionID(unchecked: "dialog.quit.keepRunning"), label: "Keep Running (§16.10)", shortcut: "↵", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.quit.stopAll"), label: "Stop All and Quit… (§16.10)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.quit.stopAllConfirm"), label: "Stop All and Quit (segunda confirmação, §16.10)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.quit.cancel"), label: "Cancel (§16.10)", shortcut: "Esc", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.quit.dontAsk"), label: "Don't ask again (§16.10)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.skipPermissions.confirm"), label: "Use Skip Permissions (§16.11)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.pasteToAgent.confirm"), label: "Paste (§16.12)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.renameBranch.confirm"), label: "Rename Branch (§16.13)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.about.licenses"), label: "Licenses…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.about.copy"), label: "Copy Version Info (§16.14)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.confirm"), label: "Start Batch", shortcut: "⌘↵", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.importCSV"), label: "Import CSV… (§16.15)", shortcut: "⌘↵", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.setTargets"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.setBrief"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.setDisplay"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.setProxy"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.toggleProxy"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.setSession"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "dialog.newBatch.cancel"), label: "Campos de New Batch… (§16.15)", shortcut: "Esc (cancel)", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "rightPanel.toggleFiles"), label: "Toggle Files", shortcut: "⌥⌘1", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.toggleInsights"), label: "Toggle Insights", shortcut: "⌥⌘2", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.toggleData"), label: "Toggle Data", shortcut: "⌥⌘3", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.toggleComputers"), label: "Toggle Computers", shortcut: "⌥⌘4", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.computersPick"), label: "Computers: escolher computador", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "computer.openTraffic"), label: "Traffic: abrir", shortcut: "", slice: .slice3),
        ActionSpec(id: ActionID(unchecked: "traffic.set"), label: "Traffic: estado", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "traffic.copyCurl"), label: "Traffic: copiar como cURL", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.dataPick"), label: "Data: escolher dataset", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.toggle"), label: "Toggle Right Panel", shortcut: "⌥⌘0", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.minimize"), label: "Minimize Module", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.move"), label: "Move Module", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.swap"), label: "Swap Modules", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.setWidth"), label: "Set Panel Width", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "rightPanel.setSplit"), label: "Set Panel Split", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.open"), label: "Open File or Folder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.openExternal"), label: "Open in External Editor", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.closeFile"), label: "Back to Files", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.togglePin"), label: "Pin Folder / Follow Terminal", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.showSessionFolder"), label: "Show Session Folder", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.toggleIgnored"), label: "Show / Hide Ignored Files", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.refresh"), label: "Refresh (Files)", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.find"), label: "Find in File", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.findNext"), label: "Find Next", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.findPrevious"), label: "Find Previous", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.findClose"), label: "Close Find", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.copyPath"), label: "Copy Path", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.openIn"), label: "Open in…", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "files.openInTarget"), label: "Open in Target", shortcut: "", slice: .slice1),
        ActionSpec(id: ActionID(unchecked: "insights.showExactLimits"), label: "Show Exact Limits", shortcut: "", slice: .slice1),
    ]
}
