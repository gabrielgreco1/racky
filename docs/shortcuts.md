# T1-22 · Tabela de atalhos (gerada)

Gerada de `KeyBindingRegistry.canonical()` e do menu montado por `MainMenu.build` (03 §21). Não editar: `RACKY_WRITE_SHORTCUTS=1 swift test --filter ShortcutsTable`.

Coluna Terminal: `PTY` = a tecla é reservada ao terminal (03 §21) e o app não a captura; `exceção` = ⌃⇥ e ⌃1…⌃9, tirados do PTY de propósito;
`escopo` = só vale no escopo indicado (o item de menu perde o key equivalent quando o escopo não está ativo); `-` = sem conflito.

| Atalho | Escopo | Ação | ActionID | Menu | Terminal |
|---|---|---|---|---|---|
| ⌘, | global | Settings | `app.settings` | Racky ▸ Settings… | - |
| ⌘/ | global | Keyboard Shortcuts | `help.shortcuts` | Help ▸ Keyboard Shortcuts | - |
| ⌘Q | global | Quit | `app.quit` | Racky ▸ Quit Racky | - |
| ⌘H | global | Hide | `app.hideAppName` | Racky ▸ Hide Racky | - |
| ⌥⌘H | global | Hide Others | `-` | sistema | - |
| ⌘N | global | New Session | `session.new` | File ▸ New Session… | - |
| ⇧⌘N | global | New Clean Session | `session.newClean` | File ▸ New Clean Session | - |
| ⌥⇧⌘N | global | New Clean Session in Folder | `session.newCleanInFolder` | File ▸ New Clean Session in Folder… | - |
| ⌘J | global | Jump To | `palette.open` | Session ▸ Jump To… | - |
| ⇧⌘A | global | Next Needing Attention | `session.nextNeedingAttention` | Session ▸ Next Needing Attention | - |
| ⌘1 | global | Select Session 1 | `session.select1` | Session ▸ Select Session ▸ Select Session 1 | - |
| ⌘2 | global | Select Session 2 | `session.select2` | Session ▸ Select Session ▸ Select Session 2 | - |
| ⌘3 | global | Select Session 3 | `session.select3` | Session ▸ Select Session ▸ Select Session 3 | - |
| ⌘4 | global | Select Session 4 | `session.select4` | Session ▸ Select Session ▸ Select Session 4 | - |
| ⌘5 | global | Select Session 5 | `session.select5` | Session ▸ Select Session ▸ Select Session 5 | - |
| ⌘6 | global | Select Session 6 | `session.select6` | Session ▸ Select Session ▸ Select Session 6 | - |
| ⌘7 | global | Select Session 7 | `session.select7` | Session ▸ Select Session ▸ Select Session 7 | - |
| ⌘8 | global | Select Session 8 | `session.select8` | Session ▸ Select Session ▸ Select Session 8 | - |
| ⌘9 | global | Select Session 9 | `session.select9` | Session ▸ Select Session ▸ Select Session 9 | - |
| ⇧⌘↑ | global | Previous Session | `session.previous` | Session ▸ Previous Session | - |
| ⇧⌘↓ | global | Next Session | `session.next` | Session ▸ Next Session | - |
| ⌥⌘← | global | Back | `nav.back` | Session ▸ Back | - |
| ⌥⌘→ | global | Forward | `nav.forward` | Session ▸ Forward | - |
| ⇧⌘0 | global | Focus Session List | `sidebar.focus` | Session ▸ Focus Session List | - |
| ⌥⌘R | global | Rename Session | `session.rename` | Session ▸ Rename Session… | - |
| ⇧⌘⌫ | app | Delete Session | `session.delete` | Session ▸ Delete Session… | - |
| ⇧⌘⌫ | sidebar | Delete Session | `session.delete` | Session ▸ Delete Session… | escopo |
| ⇧⌘O | global | Open in Editor | `item.openInEditor` | File ▸ Open in Editor | - |
| ⌥⌘N | global | New Tab | `tab.quickLaunch` | File ▸ New Tab… | - |
| ⌥⌘T | global | New Agent Tab | `tab.newAgent` | File ▸ New Agent Tab | - |
| ⌘T | global | New Terminal | `tab.newTerminal` | File ▸ New Terminal | - |
| ⌘W | global | Close Pane / Tab | `pane.close` | File ▸ Close Pane | - |
| ⇧⌘T | global | Reopen Closed Tab | `tab.reopen` | File ▸ Reopen Closed Tab | - |
| ⇧⌘W | global | Close Window | `window.close` | File ▸ Close Window | - |
| ⇧⌘] | global | Next Tab | `tab.next` | Terminal ▸ Next Tab | - |
| ⇧⌘[ | global | Previous Tab | `tab.previous` | Terminal ▸ Previous Tab | - |
| ⌃⇥ | global | Recent Tab | `tab.recent` | Terminal ▸ Recent Tab; Terminal ▸ Recent Tab (Reverse) | exceção |
| ⌃⇧⇥ | global | Recent Tab (reverse) | `tab.recent` | Terminal ▸ Recent Tab; Terminal ▸ Recent Tab (Reverse) | - |
| ⌃1 | global | Select Tab 1 | `tab.select1` | Terminal ▸ Select Tab ▸ Select Tab 1 | exceção |
| ⌃2 | global | Select Tab 2 | `tab.select2` | Terminal ▸ Select Tab ▸ Select Tab 2 | exceção |
| ⌃3 | global | Select Tab 3 | `tab.select3` | Terminal ▸ Select Tab ▸ Select Tab 3 | exceção |
| ⌃4 | global | Select Tab 4 | `tab.select4` | Terminal ▸ Select Tab ▸ Select Tab 4 | exceção |
| ⌃5 | global | Select Tab 5 | `tab.select5` | Terminal ▸ Select Tab ▸ Select Tab 5 | exceção |
| ⌃6 | global | Select Tab 6 | `tab.select6` | Terminal ▸ Select Tab ▸ Select Tab 6 | exceção |
| ⌃7 | global | Select Tab 7 | `tab.select7` | Terminal ▸ Select Tab ▸ Select Tab 7 | exceção |
| ⌃8 | global | Select Tab 8 | `tab.select8` | Terminal ▸ Select Tab ▸ Select Tab 8 | exceção |
| ⌃9 | global | Select Tab 9 | `tab.select9` | Terminal ▸ Select Tab ▸ Select Tab 9 | exceção |
| ⌘R | global | Rename Tab | `tab.rename` | Terminal ▸ Rename Tab… | - |
| ⌘D | global | Split Right | `pane.splitRight` | Terminal ▸ Split Right | - |
| ⇧⌘D | global | Split Down | `pane.splitDown` | Terminal ▸ Split Down | - |
| ⌘] | global | Next Pane | `pane.next` | Terminal ▸ Next Pane | - |
| ⌘[ | global | Previous Pane | `pane.previous` | Terminal ▸ Previous Pane | - |
| ⇧⌘↵ | global | Expand / Collapse Pane | `pane.toggleExpand` | Terminal ▸ Expand Pane | - |
| ⌘F | global | Find | `find.open` | Edit ▸ Find ▸ Find… | - |
| ⌘G | find | Find Next | `find.next` | Edit ▸ Find ▸ Find Next | escopo |
| ⇧⌘G | find | Find Previous | `find.previous` | Edit ▸ Find ▸ Find Previous | escopo |
| ↵ | find | Find Next (Return) | `find.next` | Edit ▸ Find ▸ Find Next | escopo |
| ⇧↵ | find | Find Previous (Shift Return) | `find.previous` | Edit ▸ Find ▸ Find Previous | PTY |
| ⎋ | find | Close Find | `find.close` | - | escopo |
| ⌘K | terminal | Clear | `terminal.clear` | Edit ▸ Clear Terminal | escopo |
| ⌘C | terminal | Copy | `edit.copy` | - | escopo |
| ⌘V | terminal | Paste | `edit.paste` | - | escopo |
| ⌘A | terminal | Select All | `edit.selectAll` | - | escopo |
| ⌃C | terminal | Send Interrupt | `terminal.sendInterrupt` | Terminal ▸ Send Interrupt (⌃C) | PTY |
| ⌘= | terminal | Font Bigger | `terminal.fontBigger` | View ▸ Bigger | escopo |
| ⌘- | terminal | Font Smaller | `terminal.fontSmaller` | View ▸ Smaller | escopo |
| ⌘0 | terminal | Font Reset | `terminal.fontReset` | View ▸ Actual Size | escopo |
| ⌘B | global | Toggle Sidebar | `view.toggleSidebar` | View ▸ Toggle Sidebar | - |
| ⌘L | global | Toggle Right Panel | `view.toggleRightPanel` | View ▸ Toggle Right Panel | - |
| ⌥⌘1 | global | Toggle Files | `rightPanel.toggleFiles` | View ▸ Files | - |
| ⌥⌘2 | global | Toggle Insights | `rightPanel.toggleInsights` | View ▸ Insights | - |
| ⌥⌘0 | global | Toggle Right Panel (all modules) | `rightPanel.toggle` | View ▸ Toggle All Right Panel Modules | - |
| ⇧⌘G | global | Source Control | `panel.sourceControl` | View ▸ Source Control | - |
| ⇧⌘C | global | Computers panel | `panel.computers` | View ▸ Computers Panel | - |
| ⇧⌘H | global | Conversations | `panel.conversations` | View ▸ Conversations | - |
| ⇧⌘I | global | Sessions | `page.sessions` | View ▸ Sessions | - |
| ⇧⌘L | global | Library | `page.library` | - | - |
| ⎋ | app | Close page | `page.close` | - | - |
| ⇧⌘R | global | Take Over / Hand Back | `computer.takeOver` | Computer ▸ Take Over / Hand Back | - |
| ⇧⌘R | viewer | Take Over / Hand Back (viewer) | `computer.takeOver` | Computer ▸ Take Over / Hand Back | escopo |
| ⌘⎋ | viewer | Release Keyboard | `computer.releaseKeyboard` | Computer ▸ Release Keyboard | escopo |
| ⌃⌥ | viewer | Release Keyboard (modifiers) | `computer.releaseKeyboard` | Computer ▸ Release Keyboard | escopo |
| ⌘W | viewer | Close Viewer Tab | `tab.close` | File ▸ Close Tab | escopo |
| ⌘C | viewer | Copy (inside computer) | `computer.copySelection` | Computer ▸ Copy Selection from Computer | escopo |
| ⌘V | viewer | Paste to Computer | `computer.paste` | Computer ▸ Paste to Computer | escopo |
| ⌘↵ | overlay | Submit | `composer.submit` | - | escopo |
| ⎋ | overlay | Cancel / Close | `composer.cancel` | - | escopo |
| ⇥ | overlay | Next field | `-` | sistema | escopo |
| ⇧⇥ | overlay | Previous field | `-` | sistema | escopo |
| ⇧↵ | palette | Open in Split | `palette.openInSplit` | - | PTY |
| ⌘↵ | palette | New Session with text | `palette.newSessionWithText` | - | escopo |
| ⇥ | palette | Cycle filter | `palette.cycleFilter` | - | escopo |
| ↵ | palette | Open Row | `palette.openRow` | - | escopo |
| / | palette | Insert mode | `palette.insertMode` | - | escopo |
| ↑ | sidebar | Move up | `-` | sistema | escopo |
| ↓ | sidebar | Move down | `-` | sistema | escopo |
| → | sidebar | Expand | `sidebar.project.toggle` | - | escopo |
| ← | sidebar | Collapse | `sidebar.project.toggle` | - | escopo |
| ↵ | sidebar | Focus terminal of item | `-` | sistema | escopo |
| SPACE | sidebar | Show details | `-` | sistema | escopo |
| ⌘Z | app | Undo | `-` | sistema | - |
| ⇧⌘Z | app | Redo | `-` | sistema | - |
| ⌘X | app | Cut | `-` | sistema | - |
| ⌘M | global | Minimize | `-` | sistema | - |
| ⌃⌘F | global | Full Screen | `-` | sistema | - |
| ⌃⌥⌘M | global | Motion Lab | `-` | sistema | - |

Total: 106 atalhos, 0 conflitos.
