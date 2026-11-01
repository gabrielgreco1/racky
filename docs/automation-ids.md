# Identificadores de automação

Gerado por `scripts/gen-automation-ids.py` a partir de `docs/rebuild/spec/03-screens.md` §22 e §24. Não editar à mão.
`<x>` é um placeholder (ID estável do modelo; nunca texto visível nem índice de posição).

## A11yID (03 §22)


### Janela

- `window.main`
- `window.titlebar`
- `window.appName`
- `window.sidebarToggle`
- `window.historyBack`
- `window.historyForward`
- `window.automationBadge`
- `window.daemonBanner`
- `window.databaseBanner`

### Erros

- `<region>.errorBoundary`
- `<region>.errorBoundary.retry`
- `<region>.errorBoundary.copy`

### Genéricos

- `<host>.status`
- `<host>.hoverCard`
- `<panel>.empty`
- `tooltip`
- `menuPanel.<name>`
- `popover.<name>`
- `popover.<name>.<field>`
- `popover.<name>.confirm`

### Sidebar

- `sidebar`
- `sidebar.selection`
- `sidebar.search`
- `sidebar.search.clear`
- `sidebar.search.empty`
- `sidebar.search.empty.clear`
- `sidebar.nav.inbox`
- `sidebar.nav.inbox.badge`
- `sidebar.nav.sessions`
- `sidebar.nav.sessions.badge`
- `sidebar.needsYou`
- `sidebar.nav.computers`
- `sidebar.nav.datasets`
- `sidebar.nav.library`
- `sidebar.projects.filter`
- `sidebar.projects.filterMenu`
- `sidebar.projects.add`
- `sidebar.projects.newSession`
- `sidebar.project.<id>`
- `sidebar.project.<id>.toggle`
- `sidebar.project.<id>.menu`
- `sidebar.project.<id>.newSession`
- `sidebar.project.<id>.showMore`
- `sidebar.project.<id>.rename`
- `sidebar.session.<id>`
- `sidebar.session.<id>.name`
- `sidebar.session.<id>.status`
- `sidebar.session.<id>.archive`
- `sidebar.session.<id>.prChip`
- `sidebar.session.<id>.note`
- `sidebar.session.<id>.summaryPill`
- `sidebar.session.<id>.hoverCard`
- `sidebar.session.<id>.phase`
- `sidebar.session.<id>.error`
- `sidebar.session.<id>.agents`
- `sidebar.session.<id>.rename`
- `sidebar.session.<id>.revealGlow`
- `sidebar.session.<id>.showMore`
- `sidebar.session.<id>.computers`
- `sidebar.session.<id>.restartToApply`
- `sidebar.session.<id>.disclosure`
- `sidebar.session.<id>.pin`
- `sidebar.session.<id>.agent.<terminalId>`
- `sidebar.session.<id>.agent.<terminalId>.status`
- `sidebar.session.<id>.agent.<terminalId>.lastMessage`
- `sidebar.session.<id>.agent.<terminalId>.children.toggle`
- `sidebar.session.<id>.agent.<terminalId>.control`
- `sidebar.session.<id>.agent.<terminalId>.handBack`
- `sidebar.session.<id>.child.<childId>`
- `sidebar.session.<id>.child.<childId>.status`
- `sidebar.session.<id>.child.<childId>.glyph`
- `sidebar.session.<id>.child.<childId>.connector`
- `sidebar.session.<id>.child.<childId>.title`
- `sidebar.session.<id>.child.<childId>.elapsed`
- `sidebar.session.<id>.child.<childId>.hoverCard`
- `sidebar.session.<id>.child.<childId>.preview`
- `sidebar.session.<id>.child.<childId>.openViewer`
- `sidebar.session.<id>.child.<childId>.control`
- `sidebar.session.<id>.child.<childId>.handBack`
- `sidebar.session.<id>.dataset.<datasetId>`
- `sidebar.pending.<id>`
- `sidebar.pending.<id>.cancel`
- `sidebar.cleanSessions`
- `sidebar.cleanSessions.new`
- `sidebar.footer.settings`
- `sidebar.footer.reveal`
- `sidebar.projects.clone`

### Tabs

- `tabs.tab.<terminalId>`
- `tabs.tab.<terminalId>.close`
- `tabs.tab.<terminalId>.title`
- `tabs.tab.<terminalId>.restart`
- `tabs.tab.<terminalId>.status`
- `tabs.activeIndicator`
- `tabs.overflow.leading`
- `tabs.overflow.trailing`
- `tabs.new`
- `tabs.quickCommands`
- `tabs.paneActions`
- `tabs.rightPanelToggle`

### Panes

- `pane.<id>`
- `pane.<id>.terminal`
- `pane.<id>.header`
- `pane.<id>.status`
- `pane.<id>.splitRight`
- `pane.<id>.splitDown`
- `pane.<id>.expand`
- `pane.<id>.close`
- `pane.<id>.cover`
- `pane.<id>.rimFlash`
- `pane.<id>.attention`
- `pane.<id>.zoomPill`
- `pane.<id>.feedbackPill`
- `pane.<id>.computers`
- `pane.<id>.approval`
- `pane.<id>.approval.allow`
- `pane.<id>.approval.allowSession`
- `pane.<id>.approval.deny`
- `pane.<id>.approval.proxy`
- `pane.<id>.approval.leftovers`
- `pane.<id>.ignition`
- `pane.<id>.ignition.cancel`
- `pane.<id>.ignition.step.<stepKey>`
- `pane.<id>.exitBanner`
- `pane.<id>.exitOverlay`
- `pane.<id>.exitOverlay.restart`
- `pane.<id>.exitOverlay.close`
- `pane.<id>.exitOverlay.resume`
- `pane.<id>.startError`
- `pane.<id>.interrupted`
- `pane.<id>.interrupted.resume`
- `pane.<id>.daemonBanner`
- `pane.<id>.closing.forceQuit`
- `pane.<id>.containerPopover`
- `pane.<id>.containerPhases`
- `pane.<id>.containerStopped`
- `pane.<id>.rateLimit`
- `pane.<id>.tooNarrow`
- `pane.divider.<id>`
- `pane.empty`
- `pane.empty.newAgent`
- `pane.empty.newTerminal`
- `pane.empty.reopen`
- `pane.empty.start`
- `pane.empty.resume`
- `pane.empty.agent.<provider>`

### Tabs

- `tabs.dropIndicator`
- `subtabs`
- `subtabs.terminal`
- `subtabs.computer.<computerId>`

### Panes

- `pane.dropOverlay`
- `pane.dropZone.<zone>`
- `pane.dragGhost`

### Find

- `find.field`
- `find.count`
- `find.caseSensitive`
- `find.regex`
- `find.previous`
- `find.next`
- `find.close`

### Status bar

- `statusBar`
- `statusBar.usage.claude`
- `statusBar.usage.codex`
- `statusBar.agents`
- `statusBar.computers`
- `statusBar.proxyUsage`
- `statusBar.docker`
- `statusBar.background`
- `statusBar.popover.<segment>`
- `statusBar.popover.computers.stop.<computer>`
- `statusBar.popover.openComputers`
- `statusBar.popover.proxySettings`
- `statusBar.popover.startDocker`

### Overlays (geral)

- `overlay.scrim`
- `overlay.<name>`
- `overlay.<name>.advanced`
- `overlay.<name>.<field>.error`
- `overlay.<name>.submit`
- `overlay.<name>.cancel`

### Composer

- `overlay.composer`
- `overlay.composer.project`
- `overlay.composer.where`
- `overlay.composer.createFrom`
- `overlay.composer.baseRef`
- `overlay.composer.reuseBranch`
- `overlay.composer.worktree`
- `overlay.composer.folder`
- `overlay.composer.agent`
- `overlay.composer.profile`
- `overlay.composer.prompt`
- `overlay.composer.advanced`
- `overlay.composer.name`
- `overlay.composer.branch`
- `overlay.composer.location`
- `overlay.composer.computers`
- `overlay.composer.subagentHarness`
- `overlay.composer.dataDestination`
- `overlay.composer.proxy`
- `overlay.composer.watchSubagents`
- `overlay.composer.summary`
- `overlay.composer.skipPermissions`
- `overlay.composer.riskNote`
- `overlay.composer.dataNote`
- `overlay.composer.createMore`
- `overlay.composer.cancel`
- `overlay.composer.submit`
- `overlay.composer.launchChip`
- `overlay.composer.<field>.error`

### Quick launch

- `overlay.quickLaunch`
- `overlay.quickLaunch.input`
- `overlay.quickLaunch.item.<agent>`
- `overlay.quickLaunch.profile.<id>`
- `overlay.quickLaunch.dataset.<id>`
- `overlay.quickLaunch.resume`
- `overlay.quickLaunch.openComputer`
- `overlay.quickLaunch.agentSettings`

### Palette

- `overlay.palette`
- `overlay.palette.input`
- `overlay.palette.row.<kind>.<id>`
- `overlay.palette.filter`
- `overlay.palette.insertMode`

### Inbox

- `inbox`
- `inbox.filter`
- `inbox.markAllRead`
- `inbox.empty`
- `inbox.item.<eventId>`
- `inbox.item.<eventId>.markRead`
- `inbox.item.<eventId>.takeOver`
- `inbox.item.<eventId>.allow`
- `inbox.item.<eventId>.deny`
- `inbox.item.<eventId>.open`
- `eventId`
- `batch.<batchId>`

### Painel direito

- `rightPanel`
- `rightPanel.tab.<name>`
- `rightPanel.tabs.indicator`
- `rightPanel.sourceControl.branch`
- `rightPanel.sourceControl.refresh`
- `rightPanel.sourceControl.pr`
- `rightPanel.sourceControl.createPR`
- `rightPanel.sourceControl.openPR`
- `rightPanel.sourceControl.copyURL`
- `rightPanel.sourceControl.openInEditor`
- `rightPanel.sourceControl.revealInFinder`
- `rightPanel.sourceControl.retry`
- `rightPanel.sourceControl.change.<path>`
- `rightPanel.checks.row.<name>`
- `rightPanel.checks.refresh`
- `rightPanel.checks.retry`
- `rightPanel.checks.sendFailures`
- `rightPanel.computers.new`
- `rightPanel.computers.empty`
- `rightPanel.computers.thumb.<computerId>`
- `rightPanel.computers.thumb.<computerId>.takeOver`
- `rightPanel.conversations.search`
- `rightPanel.conversations.scope`
- `rightPanel.conversations.empty`
- `rightPanel.conversations.warning`
- `rightPanel.conversations.back`
- `rightPanel.conversations.transcript`
- `rightPanel.conversations.row.<id>`
- `rightPanel.conversations.row.<id>.resume`
- `rightPanel.context.item.<kind>.<id>`
- `rightPanel.context.item.<kind>.<id>.toggle`
- `rightPanel.context.item.<kind>.<id>.insert`
- `rightPanel.context.banner`
- `rightPanel.context.restart`
- `rightPanel.context.openLibrary`
- `rightPanel.context.empty`
- `rightPanel.computer.<id>.tab.<name>`
- `rightPanel.computer.<id>.back`
- `rightPanel.computer.<id>.reveal`
- `rightPanel.computer.<id>.openRun`
- `rightPanel.computer.<id>.summary`
- `rightPanel.computer.<id>.integrity`
- `rightPanel.computer.<id>.field.<pointer>`
- `rightPanel.computer.<id>.evidence.<ref>`

### Painel direito (contêiner e módulos, 10-right-panel)

- `rightPanel.module.<id>`
- `rightPanel.module.<id>.header`
- `rightPanel.module.<id>.minimize`
- `rightPanel.divider`
- `rightPanel.insights.empty`
- `rightPanel.insights.showExactLimits`
- `tabs.filesToggle`
- `tabs.insightsToggle`
- `tabs.dataToggle`
- `tabs.computersToggle`
- `rightPanel.computers.pick`
- `rightPanel.computers.stats`
- `rightPanel.computers.proxies`
- `rightPanel.computers.changeExit`
- `rightPanel.computers.openTraffic`
- `rightPanel.computers.request.<id>`
- `rightPanel.computers.filter.<filter>`
- `traffic.page`
- `traffic.close`
- `traffic.search`
- `traffic.filter.<filter>`
- `traffic.host.<host>`
- `traffic.row.<id>`
- `traffic.detail`
- `traffic.copyCurl`
- `traffic.mode.<mode>`
- `traffic.requestTab.<tab>`
- `traffic.responseTab.<tab>`
- `traffic.detailSide.<side>`
- `traffic.noise`
- `traffic.activity.row.<id>`
- `rightPanel.data`
- `rightPanel.data.empty`
- `rightPanel.data.open`
- `rightPanel.data.beside`
- `rightPanel.data.pick`
- `rightPanel.data.stats`
- `rightPanel.data.row.<key>`

### Painel direito (Files, 10-right-panel §2)

- `rightPanel.files`
- `rightPanel.files.chip`
- `rightPanel.files.root`
- `rightPanel.files.sessionFolder`
- `rightPanel.files.showIgnored`
- `rightPanel.files.refresh`
- `rightPanel.files.tree`
- `rightPanel.files.empty`
- `rightPanel.files.row.<path>`
- `rightPanel.files.viewer`
- `rightPanel.files.viewer.back`
- `rightPanel.files.viewer.name`
- `rightPanel.files.viewer.find`
- `rightPanel.files.viewer.findField`
- `rightPanel.files.viewer.findCount`
- `rightPanel.files.viewer.findNext`
- `rightPanel.files.viewer.findPrevious`
- `rightPanel.files.viewer.findClose`
- `rightPanel.files.viewer.openIn`
- `rightPanel.files.viewer.copyPath`
- `rightPanel.files.viewer.code`
- `rightPanel.files.viewer.empty`

### Viewer

- `viewer.<computerId>`
- `viewer.<computerId>.back`
- `viewer.<computerId>.name`
- `viewer.<computerId>.mode`
- `viewer.<computerId>.url`
- `viewer.<computerId>.controlPill`
- `viewer.<computerId>.controlFrame`
- `viewer.<computerId>.ghostCursor`
- `viewer.<computerId>.clickRipple`
- `viewer.<computerId>.takeOver`
- `viewer.<computerId>.handBack`
- `viewer.<computerId>.handBack.note`
- `viewer.<computerId>.handBack.confirm`
- `viewer.<computerId>.forceTakeOver`
- `viewer.<computerId>.helpBanner`
- `viewer.<computerId>.helpBanner.decline`
- `viewer.<computerId>.connecting`
- `viewer.<computerId>.status`
- `viewer.<computerId>.disconnected`
- `viewer.<computerId>.popOut`
- `viewer.<computerId>.more`
- `viewer.<computerId>.strip`
- `viewer.<computerId>.strip.thumb.<otherId>`
- `viewer.<computerId>.keyboardBadge`
- `viewer.<computerId>.exit`
- `viewer.<computerId>.exit.handBack`
- `viewer.<computerId>.exit.keep`

### Páginas

- `computers.page`
- `computers.where`
- `computers.where.local`
- `computers.where.cloud`
- `computers.where.change`
- `computers.newSessions`
- `computers.cloud.provider.<providerId>`
- `computers.cloud.region.<regionId>`
- `computers.cloud.dailyCap`
- `computers.cloud.monthlyCap`
- `computers.cloud.maxComputers`
- `computers.cloud.connect`
- `computers.cloud.save`
- `computers.cloud.edit`
- `computers.cloud.cancel`
- `computers.cloud.summary`
- `computers.cloud.status`
- `computers.cloud.spend`
- `computers.cloud.hosts`
- `computers.cloud.host.<id>`
- `computers.cloud.host.<id>.stop`
- `computers.cloud.record.<id>`
- `computers.cloud.link.<kind>`
- `computers.newBatch`
- `computers.cleanUp`
- `computers.dockerBanner`
- `computers.empty`
- `computers.row.<id>`
- `computers.queue.row.<id>.cancel`
- `batch.<batchId>.page`
- `batch.<batchId>.row.<childId>`
- `batch.<batchId>.collectAll`
- `batch.<batchId>.archive`
- `batch.<batchId>.summary`
- `batch.<batchId>.empty`
- `batch.<batchId>.results`
- `batch.<batchId>.filter.<name>`
- `batch.<batchId>.export.csv`
- `batch.<batchId>.export.json`
- `computers.row.<id>.result`
- `computers.row.<id>.runFolder`
- `computers.leftovers`
- `computers.leftovers.showAll`
- `computers.leftovers.cleanAll`
- `computers.leftovers.row.<key>`
- `computers.leftovers.row.<key>.keep`
- `computers.leftovers.row.<key>.delete`
- `datasets.page`
- `datasets.empty`
- `datasets.row.<id>`
- `dataset.page`
- `dataset.filter`
- `dataset.search`
- `dataset.export`
- `dataset.export.<format>`
- `dataset.notebook`
- `notebook.page`
- `notebook.dataset.<id>`
- `notebook.apply`
- `notebook.openBeside`
- `notebook.close`
- `notebook.status`
- `notebook.web`
- `dataset.table`
- `dataset.empty`
- `dataset.loadMore`
- `dataset.row.<key>`
- `dataset.provenance`
- `dataset.provenance.source`
- `dataset.provenance.computer`
- `dataset.provenance.run`
- `dataset.provenance.request`
- `dataset.provenance.trust`
- `dataset.provenance.seen`
- `dataset.provenance.error`
- `dataset.stats`
- `dataset.chart`
- `dataset.range`
- `dataset.columns`
- `dataset.facet.<facet>.<value>`
- `dataset.filter.add`
- `dataset.pill.<index>`
- `dataset.pill.<index>.remove`
- `dataset.column.<name>`
- `dataset.column.<name>.value.<value>`
- `dataset.column.<name>.range`
- `dataset.chart.window`
- `dataset.chart.window.clear`
- `dataset.facet.<facet>.<value>.only`
- `dataset.facet.<facet>.reset`
- `dataset.facets.reset`
- `dataset.chip.<id>.clear`
- `dataset.search.clear`
- `dataset.status`
- `dataset.page.prev`
- `dataset.page.next`
- `dataset.copyRow`
- `dataset.panel.tab.<tab>`
- `data.page`
- `data.demo`
- `data.tabs.menu`
- `data.rename.button`
- `data.beside`
- `data.ownTab`
- `data.backToSession`
- `data.openInSession`
- `data.table.page.prev`
- `data.table.page.next`
- `data.moreColumns`
- `data.rename.field`
- `data.path`
- `data.explorer`
- `data.explorer.toggle`
- `data.explorer.resize`
- `data.explorer.node.<id>`
- `data.explorer.section.<section>`
- `data.addConnection`
- `data.tab.<key>`
- `data.tab.<key>.close`
- `data.location`
- `data.location.crumb.<index>`
- `data.flow`
- `data.flow.item.<id>`
- `data.object`
- `data.sendTo`
- `data.table.tab.<tab>`
- `data.panel.collapse`
- `data.table.grid`
- `data.query.editor`
- `data.query.run`
- `data.query.target`
- `data.query.result`
- `data.query.error`
- `data.table.error`
- `data.folder.entry.<name>`
- `data.folder.preview`
- `data.webhook.log`
- `data.webhook.test`
- `data.connect.sheet`
- `data.connect.kind.<kind>`
- `data.connect.form`
- `data.connect.name`
- `data.connect.url`
- `data.connect.auth`
- `data.connect.user`
- `data.connect.secret`
- `data.connect.save`
- `data.connect.error`
- `data.connect.s3mode`
- `data.connect.region`
- `data.connect.accessKey`
- `data.connect.sessionToken`
- `data.connect.profile`
- `data.connect.bucket`
- `data.s3.page.prev`
- `data.s3.page.next`
- `data.s3.error`
- `data.s3.preview`
- `data.runs`
- `data.runs.filter`
- `data.runs.row.<id>`
- `data.runs.error`
- `data.connection.remove`
- `data.connection.remove.confirm`
- `data.connection.remove.cancel`
- `data.empty`
- `data.production`
- `data.production.pause`
- `data.writer.<id>.pause`
- `data.writer.<id>.open`
- `data.webhook.payload`
- `library.page`
- `library.section`
- `library.search`
- `library.source`
- `library.new`
- `library.empty`
- `library.row.<kind>.<id>`
- `library.detail.newSession`
- `library.detail.enable`
- `library.detail.insert`
- `library.detail.openInEditor`
- `library.detail.reveal`
- `library.detail.restart`
- `library.profile.name`
- `library.profile.agent`
- `library.profile.model`
- `library.profile.permissions`
- `library.profile.args`
- `library.profile.env`
- `library.profile.default`
- `library.profile.row.<id>`
- `library.profile.edit`

### Settings

- `settings.page`
- `settings.back`
- `settings.search`
- `settings.nav.<section>`
- `settings.<section>.<key>`
- `settings.computers.proxies.row.<proxyId>`
- `settings.computers.proxies.add`
- `settings.computers.proxies.test`

### Onboarding

- `onboarding`
- `onboarding.step.<name>`
- `onboarding.item.<key>`
- `onboarding.done`
- `onboarding.skip`

### Dialogs

- `overlay.confirmClose`
- `overlay.confirmClose.dontAsk`
- `overlay.confirmClose.cancel`
- `overlay.confirmClose.confirm`
- `overlay.confirmArchive`
- `overlay.confirmArchive.cancel`
- `overlay.confirmArchive.confirm`
- `overlay.confirmArchiveBatch`
- `overlay.confirmArchiveBatch.cancel`
- `overlay.confirmArchiveBatch.confirm`
- `overlay.confirmStopComputer`
- `overlay.confirmStopComputer.cancel`
- `overlay.confirmStopComputer.confirm`
- `overlay.confirmRestartAgents`
- `overlay.confirmRestartAgents.cancel`
- `overlay.confirmRestartAgents.confirm`
- `overlay.confirmDeleteComputer.confirm`
- `overlay.confirmDelete`
- `overlay.confirmDelete.keepBranch`
- `overlay.confirmDelete.trashFolder`
- `overlay.confirmDelete.deleteRuns`
- `overlay.confirmDelete.dontAsk`
- `overlay.confirmDelete.changes`
- `overlay.confirmDelete.cancel`
- `overlay.confirmDelete.confirm`
- `overlay.confirmRemoveProject`
- `overlay.confirmRemoveProject.cancel`
- `overlay.confirmRemoveProject.confirm`
- `overlay.resume`
- `overlay.resume.row.<id>`
- `overlay.resume.confirm`
- `overlay.resume.cancel`
- `overlay.resume.selectAll`
- `overlay.resume.selectNone`
- `overlay.moveToProject`
- `overlay.moveToProject.project`
- `overlay.moveToProject.cancel`
- `overlay.moveToProject.confirm`
- `overlay.addProject.choose`
- `overlay.addProject.clone`
- `overlay.addProject.clone.url`
- `overlay.addProject.clone.submit`
- `overlay.cloneRepo`
- `overlay.cloneRepo.input`
- `overlay.cloneRepo.list`
- `overlay.cloneRepo.row.<id>`
- `overlay.cloneRepo.progress`
- `overlay.cloneRepo.logIn`
- `overlay.cloneRepo.error`
- `overlay.cloneRepo.retry`
- `overlay.cloneRepo.cancel`
- `overlay.cloneRepo.submit`
- `overlay.createPR`
- `overlay.createPR.title`
- `overlay.createPR.base`
- `overlay.createPR.body`
- `overlay.createPR.draft`
- `overlay.createPR.preview`
- `overlay.createPR.error`
- `overlay.createPR.retry`
- `overlay.createPR.compare`
- `overlay.createPR.cancel`
- `overlay.createPR.submit`
- `overlay.confirmQuit`
- `overlay.confirmQuit.keepRunning`
- `overlay.confirmQuit.stopAll`
- `overlay.confirmQuit.stopAllConfirm`
- `overlay.confirmQuit.cancel`
- `overlay.confirmQuit.dontAsk`
- `overlay.confirmSkipPermissions.confirm`
- `overlay.renameBranch`
- `overlay.renameBranch.name`
- `overlay.renameBranch.submit`
- `overlay.about`
- `overlay.about.licenses`
- `overlay.about.copy`
- `overlay.newBatch`
- `overlay.newBatch.targets`
- `overlay.newBatch.importCSV`
- `overlay.newBatch.brief`
- `overlay.newBatch.display`
- `overlay.newBatch.proxy`
- `overlay.newBatch.allowedProxies`
- `overlay.newBatch.session`
- `overlay.newBatch.submit`
- `overlay.newBatch.cancel`
- `overlay.newBatch.count`
- `overlay.newBatch.allowedProxies.<proxy>`
- `popover.paste`
- `popover.paste.text`
- `popover.paste.confirm`

### Landing

- `landing`
- `landing.addProject`
- `landing.cloneProject`
- `landing.newCleanSession`
- `landing.newSession`
- `landing.agent.<provider>`
- `landing.recent.<sessionId>`
- `landing.computers`
- `landing.data`

### Menu bar

- `menuBar.icon`
- `menuBar.item.<sessionId>`
- `menuBar.open`
- `menuBar.newSession`
- `menuBar.newCleanSession`
- `menuBar.stopAll`
- `menuBar.quitCompletely`

### Menus do app

- `menu.<group>.<actionId>`

### Toasts

- `toast.<kind>`
- `toast.<kind>.action`

## ActionID (03 §24)

| ActionID | Rótulo | Atalho | Fatia |
|---|---|---|---|
| `app.about` | About Racky | — | slice1 |
| `app.settings` | Settings… | ⌘, | slice1 |
| `app.setup` | Set Up Racky… / Run Diagnostics | — | slice1 |
| `app.checkProblems` | Check for Problems | — | slice1 |
| `app.hideAppName` | Hide App Name | — | slice1 |
| `app.quit` | Quit Racky | ⌘Q | slice1 |
| `app.quitCompletely` | Quit Racky Completely | — | slice1 |
| `app.openMainWindow` | Open Racky (barra de menus) | — | slice1 |
| `app.stopAllAgents` | Stop All Agents… (barra de menus) | — | slice1 |
| `view.toggleSidebar` | Toggle Sidebar | ⌘B | slice1 |
| `view.toggleRightPanel` | Right Panel | ⌘L (Fatia 2) | slice2 |
| `view.toggleStatusBar` | Show Status Bar | — | slice1 |
| `statusBar.openSegment` | Status bar: abrir | — | slice4 |
| `statusBar.toggleSegment` | mostrar-esconder segmento | — | slice4 |
| `nav.back` | Back | ⌥⌘← | slice1 |
| `nav.forward` | Forward | ⌥⌘→ | slice1 |
| `terminal.fontBigger` | Bigger | ⌘= | slice1 |
| `terminal.fontSmaller` | Smaller | ⌘- | slice1 |
| `terminal.fontReset` | Actual Size | ⌘0 | slice1 |
| `sidebar.hideNavItem` | Hide from Sidebar | — | slice1 |
| `help.open` | Racky Help | — | slice1 |
| `help.shortcuts` | Keyboard Shortcuts | ⌘/ | slice1 |
| `help.revealLogs` | Reveal Logs in Finder | — | slice1 |
| `help.exportDiagnostics` | Export Diagnostics… | — | slice1 |
| `app.openDiagnostics` | Open Diagnostics | — | slice1 |
| `diagnostics.saveExport` | Save Diagnostics | — | slice1 |
| `diagnostics.cancelExport` | Cancel Export | — | slice1 |
| `diagnostics.dismissCrash` | Dismiss Crash | — | slice1 |
| `app.restartBackgroundService` | Restart Background Service | — | slice1 |
| `app.errorTryAgain` | Try Again | — | slice1 |
| `app.copyDetails` | Copy Details (região com erro) | — | slice1 |
| `app.revealCorruptFile` | Reveal Corrupt File | — | slice1 |
| `session.new` | New Session… | ⌘N | slice1 |
| `session.newClean` | New Clean Session | ⇧⌘N | slice1 |
| `session.newCleanInFolder` | New Clean Session in Folder… | ⌥⇧⌘N | slice1 |
| `project.add` | Add Project… | — | slice1 |
| `session.setSubagentComputers` | Subagent computers (card, header do pane) | — | slice3 |
| `session.setSubagentHarness` | Subagents run as (card, header do pane) | — | slice3 |
| `agent.toggleChildren` | Collapse / Expand Subagents (chevron da linha do agente) | — | slice3 |
| `session.restartToApply` | Restart to apply | — | slice3 |
| `project.cloneFromGitHub` | Clone from GitHub… | — | slice1 |
| `sidebar.sortFilter` | Sort and Filter | — | slice1 |
| `sidebar.resetFilters` | Reset | — | slice1 |
| `sidebar.clearSearch` | Clear Search | — | slice2 |
| `sidebar.clearFilters` | Clear Filters | — | slice1 |
| `project.showMore` | Show <n> more | — | slice1 |
| `project.newSession` | New Session in <project>… | — | slice1 |
| `project.newSessionFromRef` | from Branch or PR… | — | slice1 |
| `item.openInEditor` | Open in Editor | ⇧⌘O | slice1 |
| `item.revealInFinder` | Reveal in Finder | — | slice1 |
| `item.copyPath` | Copy Path | — | slice1 |
| `item.openOnGitHub` | Open on GitHub | — | slice1 |
| `session.copyBranch` | Copy Branch Name | — | slice1 |
| `project.collapseAll` | Collapse All Sessions | — | slice1 |
| `project.hide` | Hide Project | — | slice1 |
| `project.rename` | Rename Project… | — | slice1 |
| `project.remove` | Remove Project… | — | slice1 |
| `item.refreshGit` | Refresh Git (⌥) | ⌥ | slice1 |
| `item.copyId` | Copy Project/Session ID (⌥) | ⌥ | slice1 |
| `terminal.showLaunchDetails` | Show Launch Details (⌥) | ⌥ | slice1 |
| `session.rename` | Rename… | ⌥⌘R | slice1 |
| `session.renameBranch` | Rename Branch… (⌥) | ⌥ | slice1 |
| `session.editNote` | Edit Note… | — | slice2 |
| `session.markRead` | Mark as Read | — | slice2 |
| `session.markUnread` | Unread | — | slice2 |
| `session.mute` | Mute | — | slice2 |
| `session.unmute` | Unmute Notifications | — | slice2 |
| `session.pin` | Pin / Unpin Session | — | v11 |
| `session.resumeAgents` | Resume Agents… | — | slice1 |
| `session.moveToProject` | Move to Project… | — | slice1 |
| `session.convertToProject` | Convert to Project… | — | slice1 |
| `session.moveFolderIntoProject` | Move Folder into Project… | — | v11 |
| `session.archive` | Archive Session… | — | slice1 |
| `session.delete` | Delete Session… | ⇧⌘⌫ | slice1 |
| `session.restore` | Restore Session | — | slice1 |
| `session.undoArchive` | Undo (toast `Session archived.`) | — | slice1 |
| `session.undoDelete` | Undo (toast `Session deleted.`) | — | slice1 |
| `item.openIn` | Open in… | — | slice1 |
| `item.openInTarget` | Open in <app> (item do menu `Open in…`) | — | slice1 |
| `session.locateFolder` | Locate Folder… | — | slice1 |
| `sidebar.revealCurrent` | Reveal Current Session | — | slice1 |
| `session.nextNeedingAttention` | Next Needing Attention | ⇧⌘A | slice2 |
| `session.previous` | Previous / Next Session, Select Session 1–9, Focus Session List | ⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0 | slice1 |
| `session.next` | Previous / Next Session, Select Session 1–9, Focus Session List | ⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0 | slice1 |
| `session.select1` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘1 | slice1 |
| `session.select2` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘2 | slice1 |
| `session.select3` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘3 | slice1 |
| `session.select4` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘4 | slice1 |
| `session.select5` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘5 | slice1 |
| `session.select6` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘6 | slice1 |
| `session.select7` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘7 | slice1 |
| `session.select8` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘8 | slice1 |
| `session.select9` | Previous / Next Session, Select Session 1–9, Focus Session List | ⌘9 | slice1 |
| `sidebar.focus` | Previous / Next Session, Select Session 1–9, Focus Session List | ⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0 | slice1 |
| `session.select` | Select Session (clique no card) | — | slice1 |
| `session.toggleAgents` | Expand / Collapse Agent Rows (pílula-resumo, → / ← no card) | → / ← | slice1 |
| `child.askParentToRelaunch` | Ask Parent to Relaunch | — | slice3 |
| `child.showTranscript` | Show Transcript | — | slice3 |
| `child.showComputer` | Show Computer | — | slice3 |
| `child.copyId` | Copy Agent ID | — | slice3 |
| `child.message` | Message… | — | v11 |
| `child.stop` | Stop Subagent | — | slice3 |
| `sidebar.search` | Search (campo da sidebar) | ⌘F (sidebar focada) | slice2 |
| `sidebar.project.toggle` | Expand / Collapse Project (clique na linha) | → / ← | slice1 |
| `session.cancelLaunch` | Cancel (linha pendente, PhaseList e ignição) | — | slice1 |
| `session.retryLaunch` | Try Again (criação da sessão) | — | slice1 |
| `session.resumeStopped` | Resume All (agentes parados com o app fechado) | — | slice1 |
| `session.useExistingBranch` | Use Existing Branch | — | slice1 |
| `session.createWithoutFetch` | Create Without Fetching | — | slice1 |
| `session.discardPending` | Discard (sessão que falhou ao criar) | — | slice1 |
| `session.launch` | Launch Session (automação) | — | slice1 |
| `tab.quickLaunch` | New Tab… (Quick Launch) | ⌥⌘N | slice1 |
| `tab.newAgent` | New Agent Tab | ⌥⌘T | slice1 |
| `tab.newTerminal` | New Terminal | ⌘T | slice1 |
| `tab.newWithAgent` | New <Agent> Tab (Quick Launch, New Tab ▸) | — | slice1 |
| `tab.newWithPrompt` | Start <agent> with '<text>' | — | slice1 |
| `pane.close` | Close Pane | ⌘W | slice1 |
| `tab.close` | Close Tab | ⌘W (1 pane) | slice1 |
| `tab.closeOthers` | Close Other Tabs | — | slice1 |
| `tab.closeRight` | Tabs to the Right | — | slice1 |
| `tab.reopen` | Reopen Closed Tab | ⇧⌘T | slice1 |
| `window.close` | Close Window | ⇧⌘W | slice1 |
| `tab.next` | Next | ⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9 | slice1 |
| `tab.previous` | Previous | ⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9 | slice1 |
| `tab.recent` | Recent Tab, Select Tab 1–9 | ⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9 | slice1 |
| `tab.select1` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃1 | slice1 |
| `tab.select2` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃2 | slice1 |
| `tab.select3` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃3 | slice1 |
| `tab.select4` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃4 | slice1 |
| `tab.select5` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃5 | slice1 |
| `tab.select6` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃6 | slice1 |
| `tab.select7` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃7 | slice1 |
| `tab.select8` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃8 | slice1 |
| `tab.select9` | Next / Previous / Recent Tab, Select Tab 1–9 | ⌃9 | slice1 |
| `tab.rename` | Rename… | ⌘R | slice1 |
| `tab.resetTitle` | Reset Title | ⌘R | slice1 |
| `pane.splitRight` | Split Right | ⌘D | slice1 |
| `pane.splitDown` | Down | ⇧⌘D | slice1 |
| `pane.next` | Next | ⌘] | slice1 |
| `pane.previous` | Previous Pane | ⌘[ | slice1 |
| `pane.toggleExpand` | Expand / Collapse Pane | ⇧⌘↵ | slice1 |
| `pane.equalize` | Equalize Pane Sizes | — | slice1 |
| `pane.closeOthers` | Close Other Panes | — | slice1 |
| `pane.show` | Show Pane | — | slice1 |
| `terminal.restart` | Restart | — | slice1 |
| `terminal.restartWithProfile` | Restart with ▸ | — | slice1 |
| `terminal.resume` | Resume Conversation | — | slice1 |
| `terminal.startFresh` | Start Fresh | — | slice1 |
| `terminal.copyResumeCommand` | Copy Resume Command | — | slice1 |
| `terminal.copyId` | Copy Terminal | ⌥ | slice1 |
| `terminal.copyConversationId` | Conversation | ⌥ | slice1 |
| `pane.copyId` | Pane ID (⌥) | ⌥ | slice1 |
| `terminal.showHookLog` | Show Hook Log (⌥) | ⌥ | slice2 |
| `terminal.sendInterrupt` | Send Interrupt (⌃C) | ⌃C | slice1 |
| `terminal.sendText` | Send Text | — | slice1 |
| `terminal.screen` | Screen (automação, sem UI) | — | slice1 |
| `terminal.forceQuit` | Force Quit Process… / Force Quit | — | slice1 |
| `find.open` | Find… | ⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc | slice1 |
| `find.next` | Next | ⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc | slice1 |
| `find.previous` | Previous | ⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc | slice1 |
| `find.close` | Close | ⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc | slice1 |
| `terminal.clear` | Clear Terminal | ⌘K | slice1 |
| `edit.copy` | Copy | ⌘C | slice1 |
| `edit.paste` | Paste | ⌘V | slice1 |
| `edit.selectAll` | Select All | ⌘A | slice1 |
| `terminal.openLink` | Open Link | ⌘-clique | slice1 |
| `terminal.copyLink` | Copy Link | ⌘-clique | slice1 |
| `terminal.openFile` | Open File | ⌘-clique | slice1 |
| `terminal.openComputer` | Open Computer | — | slice3 |
| `terminal.openElsewhere` | Open in another terminal | — | slice1 |
| `prompt.insertSkillOrAgent` | Insert Skill or Agent… | — | slice4 |
| `prompt.insertItem` | Insert in Prompt | — | slice4 |
| `tab.quickCommands` | Quick Commands | — | v11 |
| `tabs.paneActions` | Pane Actions (menu ⋯ da tab row) | — | slice1 |
| `tab.reorder` | Reorder Tab (arrastar na tab row) | — | slice1 |
| `tab.dropOnPane` | Drop Tab on Pane (arrastar tab para a área de panes) | — | slice1 |
| `pane.move` | Move Pane (arrastar o cabeçalho sobre outro pane) | — | slice1 |
| `pane.detach` | Detach Pane to Tab (arrastar o cabeçalho para a tab row) | — | slice1 |
| `pane.resizeDivider` | Resize Divider (arrastar o divisor) | — | slice1 |
| `find.caseSensitive` | Case Sensitive (busca no terminal) | — | slice1 |
| `find.regex` | Regex (busca no terminal) | — | slice1 |
| `find.query` | Search field e contador (busca no terminal) | — | slice1 |
| `terminal.retryStart` | Try Again (agente não iniciou) | — | slice1 |
| `agent.openSettings` | Open Agent Settings | — | slice1 |
| `terminal.copyStartError` | Copy Details (agente não iniciou) | — | slice1 |
| `terminal.cancelClose` | Cancel (fechando, `The process didn't exit.`) | — | slice1 |
| `tab.quickLaunchResume` | Resume a Conversation… (Quick Launch) | — | slice2 |
| `panel.sourceControl` | Source Control | ⇧⌘G / ⇧⌘C / ⇧⌘H | slice1 |
| `panel.checks` | Checks | ⇧⌘G / ⇧⌘C / ⇧⌘H | slice1 |
| `panel.computers` | Computers Panel | ⇧⌘G / ⇧⌘C / ⇧⌘H | slice1 |
| `panel.conversations` | Conversations | ⇧⌘G / ⇧⌘C / ⇧⌘H | slice2 |
| `panel.context` | Context | ⇧⌘G / ⇧⌘C / ⇧⌘H | slice4 |
| `panel.refresh` | Refresh (Source Control, Checks) | — | slice2 |
| `git.createPR` | Create Pull Request… | — | slice2 |
| `git.openPR` | Open on GitHub | — | slice2 |
| `git.copyPRURL` | Copy URL (PR) | — | slice2 |
| `git.openChange` | Abrir arquivo alterado (Source Control, §10.2) | — | slice2 |
| `git.openCheck` | Abrir check (Checks, §10.3) | — | slice2 |
| `account.logIn` | Log In (gh, Claude, Codex) | — | slice1 |
| `checks.sendFailures` | Send Failures to Claude Code | — | v11 |
| `conversation.resume` | Resume in New Tab / in Split, Show Transcript | — | slice2 |
| `conversation.resumeSplit` | Resume in New Tab / in Split, Show Transcript | — | slice2 |
| `conversation.showTranscript` | Resume in New Tab / in Split, Show Transcript | — | slice2 |
| `conversation.menu` | Menu da conversa | — | slice2 |
| `conversation.copyResumeCommand` | Copy Resume Command | — | slice2 |
| `conversation.copyId` | Copy Conversation ID | — | slice2 |
| `conversation.setScope` | Escopo | — | slice2 |
| `conversation.setQuery` | Busca | — | slice2 |
| `conversation.back` | Voltar do transcript | — | slice2 |
| `context.restartWithResume` | Restart Agents with Resume | — | slice4 |
| `context.toggleItem` | Toggle item in this session | — | slice4 |
| `page.library` | Open Library / Library | ⇧⌘L | slice4 |
| `page.computers` | Computers (página) | — | slice3 |
| `page.datasets` | Datasets (página) | — | slice3 |
| `dataset.open` | Open Dataset | — | slice3 |
| `dataset.filter` | Dataset: filtro | — | slice3 |
| `dataset.search` | busca | — | slice3 |
| `dataset.selectRow` | linha | — | slice3 |
| `dataset.loadMore` | Load more | — | slice3 |
| `dataset.export` | Export Dataset | — | slice3 |
| `dataset.notebook` | Open in Notebook | — | v11 |
| `notebook.toggleDataset` | Notebook: dataset | — | v11 |
| `notebook.addDataset` | Notebook: soltar dataset | — | v11 |
| `notebook.apply` | Notebook: carregar | — | v11 |
| `notebook.openBeside` | Notebook: ao lado do agente | — | slice1 |
| `dataset.openSource` | Open Source URL | — | slice3 |
| `dataset.range` | Dataset: período | — | slice3 |
| `dataset.facet` | Dataset: faceta | — | slice3 |
| `dataset.timeWindow` | Dataset: janela do gráfico | — | slice3 |
| `dataset.addFilter` | Dataset: adicionar filtro | — | slice3 |
| `dataset.removeFilter` | Dataset: remover filtro | — | slice3 |
| `dataset.columnRange` | Dataset: faixa da coluna | — | slice3 |
| `dataset.facetsReset` | Dataset: limpar filtros | — | slice3 |
| `data.open` | Data: abrir | — | slice1 |
| `data.close` | fechar objeto | — | slice1 |
| `data.toggleNode` | Data: expandir nó | — | slice1 |
| `data.newQuery` | nova consulta | — | slice1 |
| `data.tableTab` | Data: sub-aba da tabela | ⌘↩ (consulta) | slice1 |
| `data.queryRun` | rodar consulta | ⌘↩ (consulta) | slice1 |
| `data.addConnection` | Data: adicionar conexão | — | slice1 |
| `data.sendTo` | enviar para | — | slice1 |
| `data.webhookTest` | testar webhook | — | slice1 |
| `data.pauseWriter` | Data: pausar quem grava | — | slice1 |
| `data.toggleExplorer` | Data: mostrar/recolher o explorer | — | slice1 |
| `data.renameDataset` | Data: renomear dataset | — | slice1 |
| `data.tablePage` | Data: página da tabela | — | slice1 |
| `data.connectStart` | Data: conectar (começar) | — | slice1 |
| `data.connectSave` | Data: conectar (salvar) | — | slice1 |
| `data.connectionRemove` | Data: remover conexão | — | slice1 |
| `data.s3Page` | Data: página da pasta S3 | — | slice1 |
| `data.runsFilter` | Data: filtro dos flow runs | — | slice1 |
| `dataset.page` | Dataset: página | — | slice3 |
| `dataset.columns` | Dataset: colunas | — | slice3 |
| `dataset.copyRow` | Copy Row JSON | — | slice3 |
| `dataset.panelTab` | Dataset: aba do painel | — | slice3 |
| `page.sessions` | Sessions | ⇧⌘I | slice2 |
| `page.inbox` | Inbox (legado) | — | slice2 |
| `page.close` | Close page | Esc | slice1 |
| `inbox.markRead` | Mark as Read | — | slice2 |
| `inbox.markAllRead` | Mark All as Read | — | slice2 |
| `inbox.filter` | Inbox: filtro | — | slice2 |
| `notifications.request` | Allow Notifications | — | slice2 |
| `app.openSystemSettings` | Open System Settings | — | slice2 |
| `notification.open` | Open (notificação) | — | slice2 |
| `settings.testNotification` | Send Test Notification | — | slice2 |
| `notifications.pause` | Pause / Resume Notifications for 1 Hour | — | v11 |
| `library.newSessionWith` | Library: New Session with Agent / Profile | — | slice4 |
| `library.toggleInSession` | Library: Enable / Disable in This Session | — | slice4 |
| `library.openInEditor` | Library: Open in Editor | — | slice4 |
| `library.reveal` | Reveal in Finder | — | slice4 |
| `library.setSection` | Library: seção | — | slice4 |
| `library.setSearch` | busca | — | slice4 |
| `library.setSource` | fonte | — | slice4 |
| `library.selectItem` | item | — | slice4 |
| `library.editProfiles` | Library: Edit Profiles… | — | slice4 |
| `profile.new` | Library: New Profile | — | slice4 |
| `profile.duplicate` | Duplicate | — | slice4 |
| `profile.delete` | Delete… | — | slice4 |
| `library.newAgent` | Library: New Agent… | — | v11 |
| `library.importSkill` | Import Skill Folder… | — | v11 |
| `library.edit` | Edit | — | v11 |
| `conflict.block` | Block in Racky | — | slice2 |
| `conflict.disableGlobal` | Disable Globally… | — | slice2 |
| `conflict.keep` | Keep | — | slice2 |
| `conflict.restore` | Restore Skill | — | slice2 |
| `computer.openViewer` | Open Viewer | — | slice3 |
| `computer.popOut` | Open in New Window | — | slice3 |
| `computer.takeOver` | Take Over | ⇧⌘R | slice3 |
| `computer.handBack` | Hand Back | ⇧⌘R | slice3 |
| `computer.forceTakeOver` | Force Take Over | ⇧⌘R | slice3 |
| `computer.declineHelp` | Decline… (pedido de ajuda) | — | slice3 |
| `computer.releaseKeyboard` | Release Keyboard | ⌘⎋ / ⌃⌥ | slice3 |
| `computer.showTab` | Show Network / Journal / Files / Timeline / Result | — | slice3 |
| `computer.openRunFolder` | Open Run Folder | — | slice3 |
| `computer.revealResult` | Reveal Result in Finder | — | slice3 |
| `computer.openEvidence` | Open Evidence | — | slice3 |
| `computer.setDisplay` | Change type (HTTP/Headless/Desktop) | — | slice3 |
| `computer.setProxy` | Proxy ▸ | — | slice3 |
| `computer.paste` | Paste to Computer | — | slice3 |
| `computer.copySelection` | Copy Selection from Computer | — | slice3 |
| `computer.reconnect` | Reconnect | — | slice3 |
| `computer.showPreview` | Show Preview (hover card do subagente) | — | slice3 |
| `computer.allowRequest` | Allow | — | slice3 |
| `computer.allowRequestSession` | Allow for this session | — | slice3 |
| `computer.denyRequest` | Deny (pedido de computador) | — | slice3 |
| `computer.requestProxy` | Escolher o proxy do pedido de computador | — | slice3 |
| `computer.requestLeftovers` | Escolher o que sai do computador | — | slice3 |
| `computer.keepLeftovers` | Keep | — | slice3 |
| `computer.deleteLeftovers` | Delete now (Left on disk) | — | slice3 |
| `computer.start` | Start Computer | — | slice3 |
| `computer.stop` | Stop Computer… | — | slice3 |
| `computer.delete` | Delete Computer… | — | slice3 |
| `computer.new` | New Computer… | — | slice3 |
| `computer.copyId` | Copy Computer ID | ⌥ | slice3 |
| `computer.openShell` | Open Shell (⌥) | ⌥ | slice3 |
| `computer.cancel` | Cancel (fila, provisionando) | — | slice3 |
| `docker.start` | Start Docker | — | slice3 |
| `docker.settings` | Docker Settings | — | slice3 |
| `image.update` | Update | — | slice3 |
| `image.buildLocal` | Build Locally | — | slice3 |
| `image.download` | Download (imagem) | — | slice3 |
| `computers.cleanUp` | Clean Up… | — | v11 |
| `computers.runOn` | Where computers run | — | slice4 |
| `computers.where.toggle` | Show where computers run | — | slice4 |
| `computers.cloud.provider` | Cloud provider | — | slice4 |
| `computers.cloud.region` | Cloud region | — | slice4 |
| `computers.cloud.limits` | Cloud limits | — | slice4 |
| `computers.cloud.connect` | Connect cloud account | — | slice4 |
| `computers.cloud.stopHost` | Stop cloud host | — | slice4 |
| `computers.cloud.save` | Save cloud setup | — | slice4 |
| `computers.cloud.edit` | Edit cloud setup | — | slice4 |
| `computers.cloud.cancel` | Cancel cloud setup | — | slice4 |
| `computer.cleanAllLeftovers` | Delete all left on disk | — | slice3 |
| `computers.leftovers.showAll` | Show all left on disk | — | slice3 |
| `computers.cloud.openLink` | Open provider link | — | slice4 |
| `batch.new` | New Batch… | — | slice3 |
| `batch.open` | Open Batch | — | slice3 |
| `batch.filter` | Filter | — | slice3 |
| `batch.exportCSV` | Export CSV | — | slice3 |
| `batch.exportJSON` | Export JSON | — | slice3 |
| `batch.collectAll` | Collect All | — | slice3 |
| `batch.archive` | Archive Batch | — | slice3 |
| `proxy.add` | Add Proxy | — | slice3 |
| `proxy.test` | Test Proxy | — | slice3 |
| `proxy.delete` | Delete… | — | slice3 |
| `proxy.edit` | Edit Proxy | — | slice3 |
| `proxy.save` | Save Proxy | — | slice3 |
| `proxy.cancel` | Cancel (proxy) | — | slice3 |
| `proxy.preset` | Preset | — | slice3 |
| `proxy.scheme` | Type | — | slice3 |
| `proxy.setDefault` | Default proxy (proxy) | — | slice3 |
| `proxy.importFromCLI` | Import from racky CLI… | — | slice3 |
| `settings.openSection` | Seção do Settings (nav) | — | slice1 |
| `settings.back` | Back to App | Esc | slice1 |
| `settings.general.keepAgentsRunning` | Keep agents running when you quit | — | slice1 |
| `settings.general.allowLoginItems` | Allow in Login Items | — | slice1 |
| `settings.general.askBeforeQuit` | Ask before quitting with running agents | — | slice1 |
| `settings.general.resumeAgentsOnOpen` | Resume agents automatically when Racky opens | — | slice1 |
| `settings.general.confirmCloseTerminal` | Confirm before closing a running terminal | — | slice1 |
| `settings.general.confirmDeleteSession` | Confirm before deleting a session | — | slice1 |
| `settings.general.branchPrefix` | Branch prefix | — | slice1 |
| `settings.general.branchPrefixCustom` | Branch prefix | — | slice1 |
| `settings.general.worktreeFolder` | Worktree folder | — | slice1 |
| `settings.general.cleanSessionFolder` | Clean session folder | — | slice1 |
| `settings.general.projectsFolder` | Projects folder | — | slice1 |
| `settings.pickPath` | Change… | — | slice1 |
| `settings.resetConfirmations` | Reset | — | slice1 |
| `settings.general.storageCleanUp` | Space used › Clean up now | — | slice1 |
| `settings.general.computerLeftovers` | What computers leave behind | — | slice1 |
| `settings.general.leftoversOnCard` | Choose on the approval card | — | slice1 |
| `settings.general.archivedWorktrees` | Worktrees of archived sessions | — | slice1 |
| `settings.general.oldComputerImages` | Old computer images | — | slice1 |
| `settings.computers.defaultSubagentMode` | Subagent computers (padrão das novas sessões) | — | slice3 |
| `settings.computers.defaultSubagentHarness` | Subagents run as (padrão das novas sessões) | — | slice3 |
| `settings.computers.forceDocker` | Use Docker instead (runtime dos computadores) | — | slice1 |
| `settings.computers.githubAccess` | Git from computers (GitHub) | — | slice1 |
| `settings.agents.defaultAgent` | Default agent | — | slice1 |
| `settings.agents.defaultProfile` | Default profile | — | slice1 |
| `settings.agents.profileNew` | New Profile | — | slice1 |
| `settings.agents.profileDuplicate` | Duplicate | — | slice1 |
| `settings.agents.profileEdit` | Edit | — | slice1 |
| `settings.agents.profileDelete` | Delete | — | slice1 |
| `settings.agents.profileName` | Profile name | — | slice1 |
| `settings.agents.profilePermission` | Permissions | — | slice1 |
| `settings.agents.profileModel` | Model | — | slice1 |
| `settings.agents.profileArgs` | Extra flags | — | slice1 |
| `settings.terminal.font` | Font | — | slice1 |
| `settings.terminal.size` | Size | — | slice1 |
| `settings.terminal.theme` | Theme | — | slice1 |
| `settings.terminal.cursor` | Cursor | — | slice1 |
| `settings.terminal.cursorBlink` | Cursor | — | slice1 |
| `settings.notifications.needsInput` | Agent needs input | — | slice2 |
| `settings.notifications.finished` | Agent finished | — | slice2 |
| `settings.notifications.failed` | Agent failed | — | slice2 |
| `settings.notifications.terminalBell` | Terminal bell | — | slice2 |
| `settings.notifications.suppressWhenVisible` | Suppress when the session is visible | — | slice2 |
| `settings.notifications.dockBadge` | Dock badge | — | slice2 |
| `settings.notifications.sound` | Notification sound | — | slice2 |
| `agent.detect` | Detect Again / Check Again | — | slice1 |
| `agent.installHelp` | Install… | — | slice1 |
| `onboarding.retry` | Try Again | — | slice1 |
| `onboarding.copyCommand` | Copy Command | — | slice1 |
| `onboarding.keepSettingUp` | Keep Setting Up | — | slice1 |
| `onboarding.confirmSkip` | Skip (confirmação do onboarding) | — | slice1 |
| `onboarding.skip` | Skip for Now | — | slice1 |
| `onboarding.done` | Done | — | slice1 |
| `palette.open` | Jump To… (abrir a palette) | ⌘J | slice1 |
| `palette.openRow` | Open Row | ↵ | slice1 |
| `palette.openInSplit` | Open in Split | ⇧↵ | slice1 |
| `palette.newSessionWithText` | New Session '<text>' / Start with prompt | ⌘↵ | slice1 |
| `palette.cycleFilter` | Cycle filter | ⇥ | slice1 |
| `palette.insertMode` | Insert mode (`/`) | `/` no início do campo | slice4 |
| `composer.setProject` | Project (combobox) | — | slice1 |
| `composer.setWhere` | Where (segmented) | — | slice1 |
| `composer.setBase` | Create from (campo, base e chip `Branch exists`) | — | slice1 |
| `composer.reuseBranch` | Reuse existing branch (chip e link `Reuse it`) | — | slice1 |
| `composer.setWorktree` | Worktree (combobox, Existing Worktree) | — | slice1 |
| `composer.chooseFolder` | Folder `[Choose…]` | — | slice1 |
| `composer.setAgent` | Agent (combobox) | — | slice1 |
| `composer.setDefaultAgent` | Set as Default (agente) | — | slice1 |
| `composer.manageAgents` | Manage Agents… (rodapé do combobox de agente) | — | slice1 |
| `composer.setProfile` | Profile (combobox) | — | slice1 |
| `composer.editProfiles` | Edit Profiles… (rodapé do combobox de perfil) | — | slice1 |
| `composer.setSubagentComputers` | Subagent computers (segmented) | — | slice3 |
| `composer.setSubagentHarness` | Subagents run as (segmented) | — | slice3 |
| `composer.setDataDestination` | Save data to | — | slice1 |
| `composer.setPrompt` | Prompt | — | slice1 |
| `composer.toggleAdvanced` | Advanced (disclosure) | — | slice1 |
| `composer.setSessionName` | Session name | — | slice1 |
| `composer.setBranchName` | Branch name | — | slice1 |
| `composer.changeLocation` | Worktree location `[Change…]` | — | slice1 |
| `composer.createMore` | Create More (switch) | — | slice1 |
| `composer.submit` | Create Session | ⌘↵ (de qualquer campo) | slice1 |
| `composer.cancel` | Cancel | Esc | slice1 |
| `composer.keepEditing` | Keep Editing | — | slice1 |
| `composer.discard` | Discard (confirmação inline) | — | slice1 |
| `dialog.closeTerminal.confirm` | Close Terminal (confirma §16.1, inclui `Close <n> terminals?`) | — | slice1 |
| `dialog.closeTerminal.cancel` | Cancel (§16.1) | Esc | slice1 |
| `dialog.closeTerminal.dontAsk` | Don't ask again (§16.1) | — | slice1 |
| `dialog.archive.confirm` | Archive (§16.2) | — | slice1 |
| `dialog.archive.cancel` | Cancel (§16.2) | Esc | slice1 |
| `dialog.archiveBatch.confirm` | Archive Batch | Esc | slice3 |
| `dialog.archiveBatch.cancel` | Cancel (confirmação com filhos rodando: `Stop <n> running subagents?`) | Esc | slice3 |
| `dialog.stopComputer.confirm` | Stop Computer | — | slice3 |
| `dialog.stopComputer.cancel` | Cancel (§16.3) | Esc | slice3 |
| `dialog.restartAgents.confirm` | Restart Agents | — | slice4 |
| `dialog.restartAgents.cancel` | Cancel (aba Context, §10.6) | Esc | slice4 |
| `dialog.deleteComputer.confirm` | Delete Computer (§16.4) | — | slice3 |
| `dialog.deleteSession.confirm` | Delete Session (§16.5) | — | slice1 |
| `dialog.deleteSession.cancel` | Cancel (§16.5) | Esc | slice1 |
| `dialog.deleteSession.keepBranch` | Keep the branch | — | slice1 |
| `dialog.deleteSession.trashFolder` | Move folder to Trash | — | slice1 |
| `dialog.deleteSession.deleteRuns` | Also delete run folders (§16.5) | — | slice1 |
| `dialog.deleteSession.dontAsk` | Don't ask again (§16.5) | — | slice1 |
| `dialog.removeProject.confirm` | Remove Project (§16.6) | — | slice1 |
| `dialog.removeProject.cancel` | Cancel (§16.6) | Esc | slice1 |
| `dialog.resumeAgents.confirm` | Resume <n> | — | slice1 |
| `dialog.resumeAgents.cancel` | Not Now (§16.7) | — | slice1 |
| `dialog.resumeAgents.selectAll` | Select All | — | slice1 |
| `dialog.resumeAgents.selectNone` | Select None | — | slice1 |
| `dialog.resumeAgents.toggleRow` | linha com checkbox (§16.7) | — | slice1 |
| `dialog.moveToProject.confirm` | Move / Convert (§16.8) | — | slice1 |
| `dialog.moveToProject.setProject` | Project (combobox, §16.8) | — | slice1 |
| `dialog.moveToProject.cancel` | Cancel (§16.8) | Esc | slice1 |
| `dialog.addProject.addFound` | Add <n> Projects | — | slice1 |
| `dialog.addProject.stopScan` | Stop Scan (§16.9) | — | slice1 |
| `dialog.cloneRepo.setSource` | Campo `owner/repo` ou URL (§16.9b) | — | slice1 |
| `dialog.cloneRepo.select` | Linha de repositório (§16.9b) | — | slice1 |
| `dialog.cloneRepo.submit` | Clone (§16.9b) | ↵ | slice1 |
| `dialog.cloneRepo.cancel` | Cancel (§16.9b) | Esc | slice1 |
| `dialog.cloneRepo.logIn` | Log in to GitHub (§16.9b) | — | slice1 |
| `dialog.cloneRepo.retry` | Try Again (§16.9b) | — | slice1 |
| `dialog.createPR.setTitle` | Título (§16.9c) | — | slice2 |
| `dialog.createPR.setBase` | Base (§16.9c) | — | slice2 |
| `dialog.createPR.setBody` | Descrição (§16.9c) | — | slice2 |
| `dialog.createPR.setDraft` | Draft (§16.9c) | — | slice2 |
| `dialog.createPR.submit` | Create (§16.9c) | — | slice2 |
| `dialog.createPR.cancel` | Cancel (§16.9c) | Esc | slice2 |
| `dialog.createPR.retry` | Try Again (§16.9c) | — | slice2 |
| `dialog.createPR.openCompare` | Open Compare on GitHub (§16.9c) | — | slice2 |
| `dialog.quit.keepRunning` | Keep Running (§16.10) | ↵ | slice1 |
| `dialog.quit.stopAll` | Stop All and Quit… (§16.10) | — | slice1 |
| `dialog.quit.stopAllConfirm` | Stop All and Quit (segunda confirmação, §16.10) | — | slice1 |
| `dialog.quit.cancel` | Cancel (§16.10) | Esc | slice1 |
| `dialog.quit.dontAsk` | Don't ask again (§16.10) | — | slice1 |
| `dialog.skipPermissions.confirm` | Use Skip Permissions (§16.11) | — | slice1 |
| `dialog.pasteToAgent.confirm` | Paste (§16.12) | — | slice1 |
| `dialog.renameBranch.confirm` | Rename Branch (§16.13) | — | slice1 |
| `dialog.about.licenses` | Licenses… | — | slice1 |
| `dialog.about.copy` | Copy Version Info (§16.14) | — | slice1 |
| `dialog.newBatch.confirm` | Start Batch | ⌘↵ | slice3 |
| `dialog.newBatch.importCSV` | Import CSV… (§16.15) | ⌘↵ | slice3 |
| `dialog.newBatch.setTargets` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `dialog.newBatch.setBrief` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `dialog.newBatch.setDisplay` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `dialog.newBatch.setProxy` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `dialog.newBatch.toggleProxy` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `dialog.newBatch.setSession` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `dialog.newBatch.cancel` | Campos de New Batch… (§16.15) | Esc (cancel) | slice3 |
| `rightPanel.toggleFiles` | Toggle Files | ⌥⌘1 | slice1 |
| `rightPanel.toggleInsights` | Toggle Insights | ⌥⌘2 | slice1 |
| `rightPanel.toggleData` | Toggle Data | ⌥⌘3 | slice1 |
| `rightPanel.toggleComputers` | Toggle Computers | ⌥⌘4 | slice1 |
| `rightPanel.computersPick` | Computers: escolher computador | — | slice1 |
| `computer.openTraffic` | Traffic: abrir | — | slice3 |
| `traffic.set` | Traffic: estado | — | slice1 |
| `traffic.copyCurl` | Traffic: copiar como cURL | — | slice1 |
| `rightPanel.dataPick` | Data: escolher dataset | — | slice1 |
| `rightPanel.toggle` | Toggle Right Panel | ⌥⌘0 | slice1 |
| `rightPanel.minimize` | Minimize Module | — | slice1 |
| `rightPanel.move` | Move Module | — | slice1 |
| `rightPanel.swap` | Swap Modules | — | slice1 |
| `rightPanel.setWidth` | Set Panel Width | — | slice1 |
| `rightPanel.setSplit` | Set Panel Split | — | slice1 |
| `files.open` | Open File or Folder | — | slice1 |
| `files.openExternal` | Open in External Editor | — | slice1 |
| `files.closeFile` | Back to Files | — | slice1 |
| `files.togglePin` | Pin Folder / Follow Terminal | — | slice1 |
| `files.showSessionFolder` | Show Session Folder | — | slice1 |
| `files.toggleIgnored` | Show / Hide Ignored Files | — | slice1 |
| `files.refresh` | Refresh (Files) | — | slice1 |
| `files.find` | Find in File | — | slice1 |
| `files.findNext` | Find Next | — | slice1 |
| `files.findPrevious` | Find Previous | — | slice1 |
| `files.findClose` | Close Find | — | slice1 |
| `files.copyPath` | Copy Path | — | slice1 |
| `files.openIn` | Open in… | — | slice1 |
| `files.openInTarget` | Open in Target | — | slice1 |
| `insights.showExactLimits` | Show Exact Limits | — | slice1 |
