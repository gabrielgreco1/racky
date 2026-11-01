# 03 · Telas e superfícies

Status: spec do rebuild. Data: 2026-10-16. **Revisado após R1–R3 em 2026-10-16** (mudanças em `review/E-02-03-changelog.md`). Prevalece: `00-decisions.md`. Tokens e componentes: `02-design-system.md` (citado como **DS §n**). Animações: `04-motion.md` (citado pelo ID `M-xxx`, ex. **M-101**). Comportamento de terminais e agentes: `06-terminals-and-agents.md`. Comportamento de computadores e subagentes: `07-computers-and-subagents.md`. Jornadas: `05-journeys…`.

Convenções:
- Medidas em pt. Toda microcopy está **em inglês e é exata**: o que está entre aspas ou em `code` é o texto que aparece.
- `<…>` marca valor dinâmico. `[Button]` marca um botão; o estilo vem de DS §12.1.
- Cada tela lista: propósito, anatomia com medidas, controles e ações, estados, atalhos, context menus, microcopy, `accessibilityIdentifier` (formato DS §17).
- **v1 / v1.1 / later**: quando um item só entra na v1.1 (modo isolado, P6, ou corte de 01 §4) ou depois, está marcado. Controle de versão ou fatia futura **não é renderizado** (feature flag por fatia; nada de botão cinza "coming soon"). Controle da versão atual que não pode agir agora aparece desabilitado com tooltip do motivo (DS §15 regra 20).
- **Este capítulo é a fonte canônica** de microcopy, atalhos (§21), `accessibilityIdentifier` (§22, lista única), checklist visual (§23, removido) e tabela de ações (§24). Os outros capítulos citam essas seções.
- Referências à auditoria levam o prefixo `audit/NN` (ex.: `audit/07 #14`). "P2" é sempre a decisão de idioma do `00`.
- Atalhos escritos na ordem da Apple: ⌃ ⌥ ⇧ ⌘.

Modelo que as telas assumem (de `audit/10 §1` e P10): **Project → Session → Tabs → Panes (terminais e computadores)**, e cada terminal de agente pode ter **filhos** (subagentes nativos, workers do app, computadores). Uma sessão é ligada a **um diretório**: worktree nova, worktree existente, checkout principal ou pasta. **Sessões limpas** (clean sessions, P10/P11) não têm projeto nem Git e ficam na seção **Sessions** da sidebar.

---

## 0. Mapa de superfícies

```
Main window (single, "workspace")
├─ Titlebar strip (36) — over sidebar: traffic lights · "Racky" · sidebar toggle · ←/→
├─ Left sidebar (280)
│  ├─ Search
│  ├─ Nav: Inbox · Computers · Library
│  ├─ Projects  [filter] [add project] [new session]
│  │   └─ Project ▸ Session cards ▸ agent rows ▸ child rows (subagents, computers)
│  ├─ Sessions  [new clean session]
│  │   └─ Session cards (folder instead of branch)
│  └─ Footer: Settings · Locate current
│     (Inbox mode replaces Projects/Sessions with the feed)
├─ Center
│  ├─ Tab row (32 + 4 drag) — tabs · [+] · [▷ Command] (v1.1) · [⋯] · [panel toggle]
│  ├─ Pane tree — terminal panes / computer panes, splits
│  └─ or a Page: Library · Computers · (landing when no session)
├─ Right panel (310) — activity bar: Source Control · Checks · Computers · Conversations · Context
└─ Status bar (24)

Window-level overlays (OverlayPanelHost, never sheets):
  Composer (⌘N) · Quick Launch (⌥⌘N / "+") · Jump palette (⌘J) · Confirmations · Add Project ·
  Resume Agents · New Batch · Onboarding checklist · Hand-back note · Move to Project · Quit with running agents · About
Full-window page: Settings (⌘,)
Separate windows: Computer viewer pop-out (one per computer)
Outside the window: Menu bar extra · System notifications · Dock badge · App menus
```

Fora destas telas (registrado como later em 01 §4.3, não desenhado): sparse checkout e parent workspace no composer, `Create from` com URL de GitLab/Linear/Jira, Settings por projeto, arrastar pane para reorganizar, templates de sessão e de layout, fixar e colorir tab, terminal flutuante, kanban de agentes.

Navegação: tudo é **inline** (seleção na sidebar, página no centro, painel à direita) ou **overlay**. Não existe `.sheet`. Um overlay pode abrir no máximo um sub-overlay (DS §12.17). Páginas (Library, Computers) substituem só o centro; Settings substitui sidebar + centro + painel.

Histórico de navegação (⌥⌘← / ⌥⌘→): registra troca de sessão, de tab focada e abertura de página. Máx. 50 entradas.

---

## 1. Janela e chrome

### 1.1 Janela

| Item | Valor |
|---|---|
| Cena | `Window("Racky", id: "workspace")` única; reabrir pelo Dock usa `openWindow(id:)` (`audit/07 #14`) |
| Estilo | `fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, **sem `NSToolbar`**, `isMovableByWindowBackground = false`, `acceptsFirstMouse` nos controles da faixa |
| Fundo | `canvas #0a0a0a`; `NSApp.appearance = .darkAqua` (DS13) |
| Tamanho | mínimo **760×480**; primeira abertura **1440×900** centralizada; depois restaura frame (`NSWindow.setFrameAutosaveName("workspace")`) |
| Título acessível | `window.title = "Racky — <session name>"` (não visível; usado por Mission Control, VoiceOver e Window menu) |
| Responsividade | largura < 1100 → painel direito recolhe sozinho (reabre ao alargar se estava aberto); largura < 980 com sidebar aberta e painel aberto → painel vira flutuante sobre o centro; nunca esconder panes em silêncio (`audit/03 bug 6`): um pane com menos de 240 de largura mostra só o título e `[Expand]` (⇧⌘↵), ver §4.6 "Pane estreito". Regras de largura mínima em §1.5 |
| `accessibilityIdentifier` | `window.main` |

### 1.2 Semáforos

- Botões nativos (`standardWindowButton`), nunca desenhados à mão.
- Posição: centro vertical em **y = 18** a partir do topo; x da origem = **16 / 36 / 56** (close / minimize / zoom).
- Reaplicar em `windowDidResize`, `windowDidEnterFullScreen`/`Exit`, `viewDidLayout` da `NSTitlebarView` e mudança de backing scale.
- Tela cheia: semáforos somem; o pad de 80 vira 0 (M-201 não se aplica; troca instantânea).
- Com overlay aberto, os semáforos continuam ativos.

### 1.3 Faixa de titlebar sobre a sidebar (`window.titlebar`)

36 de altura, fundo `sidebar #2a2a2a`, divisor inferior `inset 0 -1 0 border`, região de arrastar (duplo clique = zoom conforme `AppleActionOnDoubleClick`). Da esquerda para a direita:

| # | Elemento | Medidas | Ação | Tooltip | ID |
|---|---|---|---|---|---|
| 1 | Pad dos semáforos | 80 (0 em tela cheia) | — | — | — |
| 2 | Nome `"Racky"` | 12/600, altura 24, padding 0×6, margem esq. 2, dir. 4, raio 4, cor `textSecondary`, hover `accent` | Clique: `DSMenuPanel` com `About Racky` · `Settings…` · `Check for Problems` · `Hide App Name` (ações em §24). Clique direito: `Hide App Name` | — | `window.appName` |
| 3 | Toggle da sidebar | DS §12.2 `titlebar`, `PanelLeft` 16 | Recolhe/expande a sidebar (M-201) | `Toggle Sidebar ⌘B` | `window.sidebarToggle` |
| 4 | Espaço flexível | — | arrastar | — | — |
| 4b | Selo `Automation on` | pílula `neutral` 16, só com o canal de automação ligado (AR-806) | Abre Settings › Advanced | `Automation channel is on` | `window.automationBadge` |
| 5 | Voltar / Avançar | `titlebarSmall`, `ArrowLeft`/`ArrowRight` 12, margem dir. 12 | Histórico; desabilitado a 45% com tooltip `No earlier page` / `No later page` | `Back ⌥⌘←` / `Forward ⌥⌘→` | `window.historyBack`, `window.historyForward` |

**Sidebar recolhida:** a faixa vira flutuante (largura do conteúdo, fundo `chrome`, borda direita `border`) por cima do início da tab row, que ganha padding esquerdo igual à largura da faixa.

**Acima do centro e do painel direito** não há faixa própria: a tab row (32) fica abaixo de uma faixa de arrasto de 4 pt, somando 36. O painel direito tem a activity bar de 36 alinhada.

### 1.4 Regiões de erro

Cada região (sidebar, centro, painel direito, status bar) tem um limite de erro: se a view falhar ao montar ou o store dela entrar em erro, a região mostra, centralizado:
- `"This part of Racky hit an error."` (13/500)
- `"<one-line error>"` (`small`, `textSecondary`)
- `[Try Again]` (`outline sm`) `[Copy Details]` (`ghost sm`)

O resto da janela continua funcionando (substitui `.disabled(loadError != nil)` do app atual). `[Try Again]` remonta a região; `[Copy Details]` copia erro, região e versão.

Banner de banco (T2, AR-331), no topo do centro (`window.databaseBanner`, M-904):
- `Racky couldn't read its database. Your terminals are still running.` `[Open Diagnostics]` (abre Settings › Diagnostics na linha Database);
- `Database was created by a newer Racky.` `[Open Diagnostics]`;
- `Restored from the backup of <date>.` `[Reveal Corrupt File]` (✕ dispensa).

IDs: `<region>.errorBoundary`, `<region>.errorBoundary.retry`, `<region>.errorBoundary.copy`.

### 1.5 Largura mínima e nada sai da caixa

Responde à queixa 7 (R2 §6). Vale para toda página, overlay, painel e para o Settings, na janela mínima **760×480** e em 1440×900, com fixtures de nomes longos (nome de sessão de 80 caracteres, caminho de 120, branch de 60, nome de computador de 40):
- Nenhum texto é cortado sem `…` e tooltip com o valor completo; nenhum controle invade outro; **nunca há rolagem horizontal** na página nem no overlay (a tabela de Computers e a Network são as únicas com colunas, e elas escondem colunas em vez de rolar).
- Overlays: largura `min(<largura do overlay>, janela − 32)`; altura máx. janela − 96 com rolagem vertical interna.
- Settings: nav 240 + conteúdo; o conteúdo encolhe até 400. Abaixo de 560 de conteúdo, cada linha passa a rótulo em cima e controle embaixo (largura total), em vez de controle de 240 à direita.
- Library: abaixo de 640 de centro, lista e detalhe se empilham (o detalhe substitui a lista e ganha `← Back`).
- Página Computers: colunas somem nesta ordem conforme falta largura: `Last Used`, `CPU`, `Owner`, `Proxy`, `Memory`; `Name` e `State` nunca somem.
- Painel direito: recolhe abaixo de 1100 (§1.1). Sidebar: mín. 220.
- Teste: `LayoutConformanceTests` percorre cada página e overlay nas duas larguras e falha se algum frame de filho sai do frame do pai ou se há `NSScrollView` horizontal ativo (critério para 05 JT).

---

## 2. Sidebar esquerda

### 2.1 Anatomia

```
┌ 280 ─────────────────────────────┐
│ titlebar strip (36)              │
├──────────────────────────────────┤ padding 8 lados, 8 topo, 4 base, gap 2
│ [⌕ Search                  ⌘J]  │ 32
│ [▢ Inbox                    (2)] │ 32
│ [▢ Computers                 3 ] │ 32
│ [▢ Library                     ] │ 32
├──────────────────────────────────┤ margem 8
│ Projects        [≡][▤][+]        │ 32 (sticky)
│ ▾ acme-platform          […][+]   │ 28 (sticky abaixo do header)
│   ┌ session card ─────────────┐  │
│   │● shop-pr-checkout   5d  │  │
│   │  me/shop ●↑2 #412 ✗│
│   │  ✳ Opened PR #412; 2 checks…│  │ agent rows 24
│   │    └ ▢ phoenix-az  $0.12   │  │ child rows 24
│   └───────────────────────────┘  │
│ Sessions                   [+]   │ 32
│   ┌ session card ─────────────┐  │
├──────────────────────────────────┤
│ [⚙]                        [⌖]  │ footer 32
└──────────────────────────────────┘
```

Fundo `sidebar #2a2a2a`. Largura 280 (220–500), redimensionável (DS §12.23), recolhível (⌘B). Scroll overlay (DS §12.24). ID do container: `sidebar`.

### 2.2 Search

- DS §12.10 `sidebarSearch`. Placeholder `"Search"`. Keycaps `⌘` `J` no hover/foco; clique no keycap abre a palette.
- Digitar filtra **no nível do item** (`audit/07 #28`): sessões cujo nome, branch, pasta, nota ou projeto casam; terminais cujo título, agente ou última mensagem casam (o card aparece com só os terminais que casaram); filhos e computadores por nome. Trecho casado ganha fundo `warning/20` (M-207).
- Projetos sem resultado somem; seção Sessions idem.
- `✕` (14, `ghost`) aparece com texto; Esc limpa; Esc com campo vazio devolve foco ao terminal.
- Sem resultados: empty state no lugar da lista (M-902): `No sessions match "<query>".` + `[Clear Search]` (`ghost xs`).
- Foco: `⌘F` quando o foco está na sidebar; clique.
- IDs: `sidebar.search`, `sidebar.search.clear`, `sidebar.search.empty`, `sidebar.search.empty.clear`.

### 2.3 Itens de navegação

DS §12.8 `Nav item` (32, `nav` 13/500, ícone 16).

| Item | Ícone | Ação | Badge | Tooltip | ID |
|---|---|---|---|---|---|
| `Inbox` | `Inbox` | Alterna o corpo da sidebar para o feed (§9.1). Ativo enquanto o feed está aberto | `count` laranja com o nº de AttentionItems de prioridade 1–2 (01 §5.12, o mesmo do Dock); sem eles mas com não lidos, bolinha âmbar 6 (M-701) | `Inbox ⇧⌘I` | `sidebar.nav.inbox`, `sidebar.nav.inbox.badge` |
| `Computers` | `Monitor` | Abre a página Computers no centro (§12.3) | contador neutro de computadores rodando; vira laranja se algum pediu ajuda | `Computers` | `sidebar.nav.computers` |
| `Datasets` | `Table` | Abre a página Datasets no centro (§12.5) | — | `Datasets` | `sidebar.nav.datasets` |
| `Library` | `Library` | Abre a página Library (§13) | — | `Library ⇧⌘L` | `sidebar.nav.library` |

Clique direito em um item: `Hide from Sidebar` (esconde só aquele item de nav; volta pela checkbox em Settings › Appearance › Sidebar; o atalho continua funcionando).

### 2.4 Header "Projects"

32 de altura, margem superior 8, padding 0×8, sticky. Label `"Projects"` (`sectionLabel`, `textSecondary/80`). Ações (DS §12.2 `header`, 24×24, ícone 14 stroke 2,25):

| Ação | Ícone | Faz | Tooltip | ID |
|---|---|---|---|---|
| Filter & sort | `SlidersHorizontal` | Abre `DSMenuPanel` (abaixo) | `Sort and Filter` | `sidebar.projects.filter` |
| Add project | `FolderPlus` | Overlay **Add a Project** (§16.9) | `Add Project…` | `sidebar.projects.add` |
| Clone from GitHub | `Download` | Overlay **Clone from GitHub** (§16.9b) | `Clone from GitHub…` | `sidebar.projects.clone` |
| New session | `Plus` | Composer (§6) com o projeto da sessão atual | `New Session ⌘N` | `sidebar.projects.newSession` |

Menu **Sort and Filter** (popover 240):
- Grupo `Sort by`: `Recent Activity` (padrão) · `Name` · `Needs You First` · `Manual` (habilita arrastar cards, M-214). Ao trocar, toast `Sort changed to <x>.` com ação `Undo` (8 s).
- Grupo `Show`: checkboxes `Sessions Idle for More Than 7 Days`, `Archived Sessions`, `Hidden Projects`, `Main Checkouts` (todos desmarcados por padrão, menos o último).
- Grupo `Filter` (later, R2.6; não renderiza na v1): `Needs You` · `Working` · `Has Computers`.
- Rodapé: `[Reset]` (volta a `Recent Activity` e às checkboxes padrão). Com algo diferente do padrão, o ícone `SlidersHorizontal` fica `textPrimary` com ponto 6.
- ID: `sidebar.projects.filterMenu`.

### 2.5 Linha de projeto

28 de altura, padding esquerdo 10, sticky abaixo do header ao rolar.
- Chevron `ChevronDown` 12 (gira −90° recolhido, 150 ms) · ícone do repo 16 · nome `bodyStrong` 13/600 truncado · contador `textTertiary` `micro` com nº de sessões quando recolhido.
- **Ícone do repo (2026-10-25):** com remote no GitHub, o avatar do dono do repositório (a organização, como `acme`, ou o usuário), 16×16 com raio 4, vindo de `https://github.com/<dono>.png?size=64` (público, sem login), com cache em memória e em `<home>/cache/avatars/<dono>.png`. Sem remote GitHub, sem rede ou com `RACKY_GITHUB=off`: caixa r4 `secondary` com o glifo `GitBranch` 12 (pasta comum: `FolderOpen`). O avatar nunca bloqueia a linha: o glifo aparece até a imagem chegar.
- Hover: fundo `fg5`; à direita aparecem botões `row` 20: `Ellipsis` (menu do projeto) e `Plus` (`New Session in <project> ⌘N`).
- Clique na linha recolhe/expande (estado persistido, `audit/07 #29`; M-806).
- Com mais de 5 sessões (ex.: sessões antigas), mostra as 5 mais recentes e a linha `Show <n> more` (24, `textTertiary`); clique expande e o estado persiste (P15).
- Arrastar uma sessão limpa e soltar na linha de projeto = **Move to Project…** com aquele projeto pré-escolhido (overlay §16.8, M-212).
- ID: `sidebar.project.<projectId>`, `.toggle`, `.menu`, `.newSession`.

**Context menu do projeto** (NSMenu, mesmo conteúdo do `…`):
- `New Session in <project>…` ⌘N
- `New Session from Branch or PR…` (abre composer com foco em "Create from")
- separador
- `Open in Editor` ⇧⌘O · `Reveal in Finder` · `Open on GitHub` (se remote GitHub) · `Copy Path`
- separador
- `Rename…` · `Collapse All Sessions` (recolhe as linhas de agente de todos os cards do projeto) · `Hide Project` (some da sidebar; volta por `Show › Hidden Projects`)
- separador
- `Remove Project…` (destrutivo; confirmação §16.6; nunca apaga arquivos)
- com ⌥: `Refresh Git` · `Copy Project ID` (sem "Reauthorize Folder…": não há bookmarks, AR-533)

### 2.6 Card de sessão

Superfície DS §12.9. Uma sessão = um card. O card **é o item selecionável**; clicar mostra as tabs da sessão no centro e foca o último pane focado dela.

**Cada sessão é um bloco (2026-10-25).** O dono via sessões sem agente (sem bolinha) parecerem filhas da sessão de cima. Por isso todo card, selecionado ou não, tem fundo `fg5` e borda `border` hairline (raio do card), com 6 pt entre um card e outro; selecionado continua `fg10` + borda `fg18`; hover `hoverRow`. O detalhe da sessão (agentes, computadores, tabelas) fica atrás de uma **setinha** no fim da linha 1 e começa fechado, menos na sessão selecionada.

**Coluna de status (20 + 4):** indicador agregado `md` (DS §2.6 regra de agregação). Toda sessão tem indicador: sem agente (não começou, só shells parados) é um **círculo vazio** 8 com traço 1,5 `textQuaternary`, nunca a coluna vazia. Não lido: bolinha âmbar 6 no canto superior direito da coluna. Linha pendente: spinner (ver §2.9).

**Linha 1** (altura 20):
| Elemento | Spec |
|---|---|
| Nome | `body` 13; não lido 600 `textPrimary`; lido 400 `fg/80`. Truncado no fim. Duplo clique renomeia inline (§2.11) |
| Badges (máx. 2) | `Main` (sessão no checkout principal), `Detached`, `Conflicts` (`warning`), `Rename failed` (`error`, clicável → toast com o erro e `Copy Details`), `Container` (v1.1, se algum terminal roda em container) |
| Tempo | `microNumeric` `textTertiary` à direita: tempo desde a última atividade (`now`, `12m`, `3h`, `5d`); some no hover |
| Ações no hover | `row` 20: `Archive` (`Archive Session…`). `Star` (`Pin Session`, v1.1) não renderiza na v1 |
| Setinha (detalhe) | Última coisa da linha, caixa 16, `ChevronRight` 12 `textTertiary`; gira 90° aberta (150 ms `standard`). Só aparece quando a sessão tem agentes, computadores ou tabelas. Abre e fecha o detalhe sem selecionar a sessão (o resto do card continua selecionando). Tooltip `Show agents, computers and data` / `Hide details`. A escolha por sessão persiste (`expandedSessions` / `collapsedSessions` no estado da sidebar); sem escolha, só a sessão selecionada fica aberta. ID `sidebar.session.<id>.disclosure`, ação `session.toggleAgents` |

**Linha 2** (altura 14, `small` 11 `textSecondary`, lh 1):
- Sessão de projeto: `GitBranch` 10 + branch truncado no meio · ponto `gitModified` 6 se há alterações não commitadas · `↑<n>` se há commits não enviados (só >0) · à direita, **chip de PR** (DS §12.4 `chip`: ícone de estado 13 + `#<n>` + glifo de checks 12). Sem PR: nada.
- Sessão limpa: `FolderOpen` 10 + caminho abreviado (`~/Racky/sessions/quiet-harbor`).
- Sessão importada sem processo: depois da branch, `Not started` em `textTertiary`.
- Altura reservada desde o início (placeholder `fg5` 60×8 enquanto o Git não respondeu).
- **Fechado (2026-10-25):** à direita da linha 2, contadores do que a sessão tem, `microNumeric` `textTertiary`: logo do primeiro agente (12, apagado) + nº de agentes · `display` + nº de computadores · `tablecells` (`dataValid`) + nº de tabelas. Só os que existem.

**Linha 3, nota da sessão** (opcional, R2.4, v1): `small` `fg/60`, uma linha, truncada. Ex.: `Reproduced the bug; testing fix`. Editável em `Edit Note…`, por duplo clique na linha da nota e pela ferramenta MCP `session_set_status`.

**Detalhe aberto, por grupo (2026-10-25):** com a setinha aberta, o que pertence à sessão aparece em grupos, cada um com um rótulo `micro` `textTertiary` alinhado ao nome: **Agents** (linhas de agente, §2.7), **Computers** (linhas filhas, §2.8) e **Data** (tabelas que a sessão coletou; quando a sessão grava numa conexão ou roda fluxos numa conexão Prefect, essas conexões entram aqui também). Grupos vazios não aparecem.

**Linhas de agente** (uma por terminal da sessão, na ordem das tabs): ver §2.7. Shells puros aparecem como linha só quando estão rodando um comando (título OSC diferente do shell) ou quando a sessão não tem agentes; caso contrário ficam agrupados em `+2 terminals` (linha de 24, `textTertiary`, clique expande).

**Muitos agentes** (> 4 linhas): as linhas colapsam numa **pílula-resumo** de 24: até 3 grupos de estado (indicador + logos sobrepostos 16 + contagem) e `ChevronDown` 12; clique expande (M-206, 180 ms). Estado expandido persiste.

**Hover card** (250 ms, DS §12.16), 300 de largura:
```
shop-pr-checkout                         (bodyStrong)
acme-platform · ~/Racky/worktrees/acme-platform/shop   (small, path middle-truncated)
State      Claude Code needs input · 4m
Branch     me/shop  ↑2  ● 3 files changed
PR         #412 Open · Checks 2 failing, 9 passing
Computers  2 running · proxy $0.31 today   (proxy só se o provedor informa uso)
Note       Opened PR #412; fixing tests
```
Linhas ausentes não aparecem. ID: `sidebar.session.<id>.hoverCard`.

**Estados do card:**
| Estado | Visual |
|---|---|
| normal | §DS 12.9 |
| hover | `hoverRow`, ações de hover, tempo some |
| selecionado (ativo) | `fg10` + borda `fg18` (M-203 desliza) |
| focado por teclado | anel interno 2 `ring/50` |
| não lido | nome 600 + bolinha âmbar |
| arquivando | 50% + grayscale + pílula `Archiving…` com spinner (M-209) |
| excluindo | 50% + grayscale + pílula `Deleting…` |
| erro de diretório (pasta sumiu) | linha 2 vira `AlertCircle` 10 `destructive` + `Folder not found`; ação `Locate Folder…` no hover (§24) |

**Clique:** seleciona a sessão; ⌘-clique: multi-seleção (para arquivar/excluir em lote); clique na linha de agente foca aquele pane (troca de tab se preciso, com rim flash M-309 só se veio de teclado).

**IDs:** `sidebar.session.<id>`, `.name`, `.status`, `.archive`, `.prChip`, `.note`, `.agent.<terminalId>`, `.summaryPill`, `.showMore`, `.disclosure` (lista completa em §22).

**Como validar o card (2026-10-25):** print da sidebar com 3+ sessões de estados diferentes (uma rodando, uma interrompida, uma que não começou) para 10 testers sem contexto: "quantas sessões há neste projeto?" e "o que pertence à sessão X?". Critério 10/10; nenhum pode contar uma sessão como parte de outra.

**Context menu da sessão** (cabeçalho `Session`):
- `Rename…` ⌥⌘R
- `Edit Note…`
- `New Tab ▸` → `Claude Code` · `Codex` · `OpenCode` · `Terminal` ⌘T · separador · perfis
- `Open in Editor` ⇧⌘O · `Reveal in Finder` · `Copy Path` · `Copy Branch Name`
- `Open Pull Request` / `Create Pull Request…` (se branch tem push) · `Open on GitHub`
- separador
- `Mark as Read` / `Mark as Unread` · `Mute Notifications` / `Unmute Notifications` (`Pin` / `Unpin`: v1.1)
- `Resume Agents…` (se há terminais interrompidos; overlay §16.7)
- `Move to Project…` (só sessão limpa; §16.8) · `Convert to Project…` (só sessão limpa; cria projeto com a pasta como raiz) · `Move Folder into Project…` (v1.1; só com terminais parados)
- separador
- `Archive Session…` (para processos e computadores; mantém pasta, worktree e branch)
- `Delete Session…` ⇧⌘⌫ (destrutivo; §16.5)
- com ⌥: `Refresh Git` · `Rename Branch…` · `Copy Session ID` · `Show Launch Details`

### 2.7 Linha de agente (terminal)

24 de altura, padding 0×4, gap 4, raio 4, texto `small` 11 `textSecondary`. Recuo: alinhada com o nome do card (início após a coluna de status).

Conteúdo, em ordem:
1. `AgentStateIndicator sm` (10).
2. `AgentLogo 13` (shell: `SquareTerminal` 12).
3. Selo de modo `Box` 10 se em container (v1.1).
4. Texto **lead – trail**, truncado: *lead* = última mensagem do agente (R2.1) em `textSecondary/90` (600 `textPrimary` se não vista); se não há mensagem, o título da tab. *trail* = complemento em `textSecondary/65` (ex.: nome da ferramenta em uso: `Bash · pnpm test`). Ex.: `Which table should I use, listings_2024 or listings_v2?`
5. Modelo (`monoMicro`, máx. 96, opcional, `textTertiary`): `opus-4.5`.
6. Contador `+N` de subagentes recolhidos.
7. Tempo `microNumeric` `textTertiary/60`.

Estados: hover `hoverAgentRow` (M-210); pane focado `sidebarSelected`; último focado de sessão não ativa: `sidebarSelected` a 50% (`audit/07 #37`). Texto da última mensagem troca com M-409.

Clique: seleciona a sessão e foca o pane. Duplo clique: renomeia o título da tab. Clique no indicador `needsInput`: foca o pane com rim flash.

Tooltip da linha (400 ms): texto completo da última mensagem (até 6 linhas) + `Claude Code · opus-4.5 · started 2h ago`.

**Filhos** (subagentes e computadores) aparecem abaixo, recolhíveis por um chevron 10 que surge no hover à esquerda do indicador; padrão: expandido enquanto algum filho está ativo, recolhido quando todos terminaram.

ID: `sidebar.session.<id>.agent.<terminalId>`, `.lastMessage`, `.children.toggle`.

**Context menu da linha de agente** (cabeçalho `Terminal`): igual ao context menu da tab (§3.5) mais `Show Pane`.

### 2.8 Linha filha (subagente, worker, computador)

24 de altura, recuo +12 em relação à linha de agente, com conector em L de 1 pt `border` (desenha-se com M-213). Profundidade máxima visível 3 (`audit/08 N3`); além disso, `+N more` com breadcrumb no hover.

| Tipo | Conteúdo | Clique |
|---|---|---|
| Subagente nativo (Claude/Codex) | indicador `sm` · logo 12 · nome (`agent_type` ou nome dado) · último texto/`DOING` do journal · tempo | Abre o painel direito › Conversations no transcript do filho (`audit/08 N4`) |
| Worker em container (v1.1) | indicador · logo · selo `Box` · nome · última nota · tempo | Foca a tab do filho (é um terminal real) |
| Computador | ícone de estado DS §2.8 (`Monitor` 12 / provisioning / hourglass) · nome (`phoenix-az`) · estado curto (`Claude is using` / `You're in control` / `Needs you · CAPTCHA` / `Queued`) · uso do proxy `$0.12` (só quando informado, P13) · tempo | Abre o viewer (tab de computador) |
| Subagente com computador (On This Mac) | linha do subagente + linha do computador aninhada um nível abaixo | idem |

Estados especiais: `Interrupted` após reboot (R8.2) com ação no hover `Ask Parent to Relaunch` (popover §16.12 com o texto, colado no prompt do pai sem Enter, R5.1); `Stalled?` (R4.10, v1.1) com `CircleDashed`.

ID: `sidebar.session.<id>.child.<childId>`.

**Context menu da linha filha** (cabeçalho `Subagent` ou `Computer`):
- Subagente: `Show Transcript` · `Show Computer` (se tem) · `Copy Agent ID` · `Message…` (v1.1, R4.11; a mensagem do pai ao filho com Enter é P12 e não passa por aqui) · `Stop Subagent` (só renderiza quando o adapter declara a capacidade, 06; senão não aparece).
- Computador: `Open Viewer` · `Take Over` ⇧⌘R · `Open in New Window` · `Show Network` · `Show Journal` · `Show Files` · separador · `Stop Computer…` · `Delete Computer…` (destrutivo) · com ⌥: `Copy Computer ID` · `Open Shell` (abre tab de terminal com shell no container `work` do computador e banner `Commands here run inside <computer>.`; mecânica em 07).

### 2.9 Linha pendente (sessão sendo criada)

Aparece **na hora** em que o composer fecha (P9, M-204), no topo do projeto (ou da seção Sessions):
- 32 de altura; coluna de status com `Spinner` 16; nome `body` 13 `textSecondary`; linha 2 `small` com a fase atual: `Preparing…` → `Fetching origin…` → `Creating worktree…` → `Copying .env files…` (v1.1) → `Starting Claude Code…`.
- Clique: seleciona; o centro mostra a **PhaseList** completa (§4.6) com `[Cancel]`.
- Erro (M-205): spinner vira `AlertCircle` `destructive`, linha 2 `Couldn't create worktree` e, no centro, a mensagem e ações (§6.4).
- ID: `sidebar.pending.<id>`, `.cancel`.

### 2.10 Seção Sessions (sessões limpas, P10/P11)

- Header igual a "Projects" (32): label `"Sessions"`, tooltip do label `Sessions without a project or Git`. Ação única `Plus` (tooltip `New Clean Session ⇧⌘N`) → **New Clean Session**: cria na hora `~/Racky/sessions/<auto-name>` e abre o agente padrão, com foco no terminal, sem diálogo (AC-1101). ⌥-clique no `+` abre o composer com `No Project (Clean Session)` pré-selecionado.
- **New Clean Session in Folder…** (⌥⇧⌘N, menu File): `NSOpenPanel` escuro; a sessão usa a pasta escolhida e o app não cria nem apaga nada nela (AC-1105).
- Nome automático: adjetivo + substantivo (`quiet-harbor`, P15), nunca reaproveita pasta existente (AC-1102). Renomear a sessão não renomeia a pasta.
- Cards iguais (§2.6), linha 2 com pasta; sem branch, chip de PR nem `Create Pull Request…`.
- Seção some se não há sessão limpa; o `+` continua acessível no menu `File`, na landing e no composer.
- ID: `sidebar.cleanSessions`, `sidebar.cleanSessions.new`.

### 2.11 Renomear inline

Regras (`audit/07 #31`, M-208): gatilhos duplo clique, `Rename…`, ⌥⌘R (sessão) / ⌘R (tab). O texto vira `inlineRename` com tudo selecionado. ↵ confirma, Esc cancela, **perder o foco confirma**, ↵ durante composição IME é ignorado. Vazio → volta ao nome automático. Falha (ex.: renomear branch) → campo continua aberto + toast `Couldn't rename session.` (60 s, `Copy Details`). Renomear a sessão **não** renomeia a branch nem a pasta; branch tem item próprio `Rename Branch…` (com ⌥; §16.13).

### 2.12 Rodapé

32, `border-top`, padding 8×6:
- Esquerda: `Settings` (`row`, ícone 14), tooltip `Settings ⌘,` — ID `sidebar.footer.settings`.
- Direita: `Crosshair` 14, tooltip `Reveal Current Session` (rola até o card ativo, M-211 no card) — ID `sidebar.footer.reveal`.

### 2.13 Estados vazios da sidebar

| Caso | Conteúdo |
|---|---|
| Nenhum projeto e nenhuma sessão | Seções somem; no lugar, `small` centralizado: `No projects yet.` + `[Add Project…]` (`outline sm`) + `[New Clean Session]` (`ghost sm`). O centro mostra a landing (§19) |
| Projeto sem sessões | Linha `small` `textTertiary` recuada: `No sessions` + link `New Session` (abre o composer com o projeto) |
| `Show` sem resultado | `No sessions match these filters.` + `[Clear Filters]` (mesmo efeito de `[Reset]`) |

### 2.14 Teclado e arrastar

- `⇧⌘0` foca a lista. ↑/↓ percorrem cards e linhas de agente; → expande, ← recolhe; ↵ foca o pane; Space abre o hover card; Esc devolve ao terminal.
- `⌘1…9`: seleciona a sessão N na ordem visível (projetos expandidos + Sessions). `⇧⌘↑/↓`: sessão anterior/seguinte.
- Arrastar card: só com sort `Manual` (reordena no projeto, M-214); sessão limpa → projeto = Move to Project (§16.8). Arrastar card para a tab row não faz nada.
- Arrastar arquivo do Finder sobre um card: nada na v1 (anexos no composer são later, R3.6).

---

## 3. Tab row

### 3.1 Anatomia

32 de altura abaixo de 4 de arrasto (total 36), fundo `chrome #171717`, `border-bottom`. Uma tab row por sessão (as tabs são **da sessão selecionada**). Arrastar uma tab para a área de panes cria splits ou troca de lugar (§3.4, v1, F11); não há tab row por grupo.

```
[tab][tab][tab]  [+]                      [▷ Command](v1.1) [⋯] [▯]
```

### 3.2 Tab

DS §12.7. Largura 180 (220 com janela ≥ 1280), mínimo 72; overflow com fade 24 e chevrons 20×24.

Tipos de tab: **terminal** (agente ou shell), **computer** (viewer de computador, §11), **diff** (v1.1), **file** (SKILL.md/agente da Library aberto em leitura, v1.1).

Título:
- Agente: título dinâmico do OSC 0/2 se o agente define, senão o nome do agente (`Claude Code`). Renomeado pelo usuário: fica fixo.
- Shell: comando rodando (`pnpm test`) ou nome da pasta.
- Computer: nome do computador (`phoenix-az`).

Estado no começo da tab: `AgentStateIndicator md` (agentes) / estado de processo (DS §2.7) / estado do computador (DS §2.8).

Chip `Restart` (aparece quando o processo saiu; mesma ação do menu, §24): `xs ghost` 20 de altura dentro da tab, à direita do título, só na tab ativa ou no hover. ID `tabs.tab.<id>.restart`.

Hover card da tab (500 ms): título completo, `Claude Code · opus-4.5`, cwd (mono, truncado no meio), estado + tempo, `Conversation <short id>` (com ⌥), ações `Copy Resume Command`.

Overflow: fade 24 + chevrons (M-305), `tabs.overflow.leading` / `.trailing`; indicador ativo `tabs.activeIndicator`.

ID: `tabs.tab.<terminalId>`, `.close`, `.title`, `.restart`.

### 3.3 Botões da tab row

| Botão | Spec | Ação | Tooltip | ID |
|---|---|---|---|---|
| `+` | `toolbar` 28×28, `Plus` 14 | Abre **Quick Launch** ancorado (§7) | `New Tab ⌥⌘N` | `tabs.new` |
| `▷ Command` (v1.1) | 28 de altura, `Play` 14 + `"Command"` 12/500 muted; vira split button com comandos salvos | Quick Commands | `Quick Commands` | `tabs.quickCommands` |
| `⋯` | `toolbar`, só com 2+ panes na tab | Menu: `Split Right ⌘D`, `Split Down ⇧⌘D`, `Equalize Pane Sizes`, `Expand Pane ⇧⌘↵`, `Close Other Panes` (ações em §24) | `Pane Actions` | `tabs.paneActions` |
| Toggle painel direito (Fatia 2 em diante; na Fatia 1 o painel é oculto e o botão não existe) | `titlebar`, `PanelRight` 16 | Abre/fecha painel (§10) | `Toggle Right Panel ⌘L` | `tabs.rightPanelToggle` |

Duplo clique no espaço vazio da tab row: nova tab com o agente padrão (⌥⌘T). Área vazia arrasta a janela.

### 3.4 Interações

- Clique seleciona (M-304); **se o terminal já está visível num pane da tab, só foca**; nunca substitui o conteúdo de outro pane (`audit/03 bug 5`).
- Clique do meio ou ✕ fecha (confirmação se processo rodando, §16.1; M-302); ⇧⌘T reabre (até 10 por sessão; relança com `--resume` quando há ID).
- Arrastar reordena (ativação 12 pt; Esc cancela; M-303). Arrastar para fora da janela: `Open in New Window` só para tabs de computador.
- **Arrastar tab para os panes (v1, F11, M-306).** Ao sair da tab row sobre a área de panes, o pane sob o cursor mostra as zonas de drop: esquerda, direita, cima e baixo (25% de cada lado) criam um split com a tab arrastada naquele lado (todos os panes dela entram juntos); o miolo (centro) troca de lugar o pane principal da tab com o pane de destino. Prévia translúcida (`locate` a 14%) da área resultante, 200 ms `standard`; sem espaço para 240 × 120 a prévia fica vermelha e soltar mostra o toast do §4.3. Soltar aplica e persiste; os terminais **não** são recriados (mesma sessão do daemon, um resize de PTY por pane). Esc, soltar fora dos panes ou perder o foco da janela cancela e o teclado volta ao terminal. Uma tab não pode ser solta sobre os próprios panes.
- **Pane ↔ tab (v1, F11).** Arrastar o cabeçalho de um pane sobre a tab row o transforma em tab (barra de inserção `tabs.dropIndicator`); sobre outro pane usa as mesmas zonas (mover pane; centro troca de lugar). Mesmas regras de Esc e foco. Equivalentes por ação: `tab.dropOnPane`, `pane.move`, `pane.detach` (§24).
- Duplo clique no título renomeia (§2.11).
- `⌃1…9` seleciona; `⇧⌘]`/`⇧⌘[` próxima/anterior; `⌃⇥` recente.

### 3.5 Context menu da tab (terminal)

- `Rename…` ⌘R · `Reset Title` (volta ao título dinâmico)
- `Split ▸` → `Split Right` ⌘D · `Split Down` ⇧⌘D
- `Restart` (processo saiu) / `Restart with ▸` (perfis do mesmo agente; encerra e relança com o perfil escolhido, sem resume) · `Resume Conversation` (se há ID e o processo não está vivo)
- `Open Computer` (se o agente tem computador) · `Reveal in Finder` · `Open in Editor`
- `Copy Resume Command` (agentes) · `Copy Path`
- separador
- `Close Tab` ⌘W · `Close Other Tabs` · `Close Tabs to the Right`
- com ⌥: `Copy Terminal ID` · `Copy Conversation ID` · `Show Launch Details` · `Show Hook Log`

Tab de computador: `Rename…` · `Open in New Window` · `Take Over` ⇧⌘R · `Stop Computer…` · `Close Tab` (fechar a tab **não** para o computador).

---

## 4. Pane de terminal

### 4.1 Superfície

- Fundo `terminalBackground #282c34`, sem moldura, inset 4 (DS §3). Ocupa todo o pane.
- Pane inativo: opacidade 0,8 (DS4), transição M-308.
- Foco: clique no terminal (via `mouseDown` do host, não gesto SwiftUI, `audit/07 #16`).
- Arrastar arquivos do Finder: overlay de 2 pt `ring` na borda + rótulo `Drop to paste path` centralizado (12/500 em pílula `chrome`); soltar insere caminhos com escape de shell; imagem vai por bracketed paste (`audit/07 #5`). Detalhes em `06`.
- A view é `TerminalView` do SwiftTerm com delegate próprio; **nunca `LocalProcessTerminalView`** e nunca resposta a OSC 52 de leitura (`clipboardRead → nil`, T6, DS §3).
- ID: `pane.<terminalId>`, `pane.<terminalId>.terminal`.

### 4.2 Header do pane

Visível quando a tab tem **2 ou mais panes**. Com 1 pane, só os botões de ação aparecem no canto superior direito, no hover (variante chromeless).

24 de altura, sobreposto ao topo do pane, padding 0×8, `monoPane` 13 `paneTitle` (`white/52`; pane focado `white/70`), separador inferior `white/6`.

Esquerda: indicador `sm` · logo 12 · título · selo de modo (v1.1; clicável: popover `Container` com CPU, memória, imagem e `[Stop Container…]`, `pane.<id>.containerPopover`) · `ShieldOff` 12 `textSecondary` se o perfil pula permissões (tooltip `Skip permissions (<flag exata>)`, ex. `Skip permissions (--dangerously-skip-permissions)`) · `Monitor` 12 se o agente tem computador (clicável: abre o viewer; tooltip `Open Computer`).

Direita (botões `pane` 24, ícone 12; split visível no pane ativo ou no hover; fechar só no hover; fade 120 ms):

| Botão | Ícone | Ação | Tooltip | ID |
|---|---|---|---|---|
| Split right | `SquareSplitHorizontal` | Novo pane à direita com o **mesmo agente e perfil** (⌥-clique: shell) | `Split Right ⌘D` | `pane.<id>.splitRight` |
| Split down | `SquareSplitVertical` | idem abaixo | `Split Down ⇧⌘D` | `pane.<id>.splitDown` |
| Expand | `Maximize2` / `Minimize2` | Expande/recolhe o pane | `Expand Pane ⇧⌘↵` | `pane.<id>.expand` |
| Close | `X` | Fecha o pane (confirmação se rodando) | `Close Pane ⌘W` | `pane.<id>.close` |

Duplo clique no título renomeia (§2.11).

### 4.3 Splits e divisor

- Divisor DS §12.23 (3 pt `#3f3f46`, hit 9, cursor de resize). Arrasto imediato; duplo clique iguala; salva com debounce.
- ⌘D / ⇧⌘D dividem o pane focado (M-306). **Sem limite fixo de 5** (`audit/03 bug 4`): o limite é o mínimo de 240×120 por pane; se não couber, toast `Not enough room to split. Close a pane or widen the window.`.
- `⌘]`/`⌘[` focam o próximo/anterior (M-308); `⇧⌘↵` expande (os outros ficam ocultos, com indicador `2 hidden panes` no canto do header, clicável: recolhe a expansão; `pane.<id>.zoomPill`).
- Fechar pane: o irmão ocupa o espaço (M-307). Fechar o último pane fecha a tab.
- Nunca animar o frame do terminal (DS §1.7); um resize do PTY por transição, no início (04 §4 R2; ao fechar painel, no fim); no arrasto do divisor, no máximo 1 por quadro e o final ao soltar (M-202).

### 4.4 Busca no terminal (⌘F)

Barra flutuante no canto superior direito do pane (8 das bordas, abaixo do header quando houver), 340 de largura, 32 de altura, `chrome` + borda `white/14` + `shadowFloating`, raio 8, padding 4.

| Elemento | Spec | ID |
|---|---|---|
| Campo | `findField`, placeholder `"Search…"` | `find.field` |
| Contador | `microNumeric`: `3/17`; sem resultados: `No results` em `destructive` | `find.count` |
| Case | toggle `CaseSensitive` 14, tooltip `Case Sensitive` | `find.caseSensitive` |
| Regex | toggle `Regex` 14, tooltip `Regex` | `find.regex` |
| Anterior | `ArrowUp` 14, tooltip `Previous Match ⇧↵` | `find.previous` |
| Próximo | `ArrowDown` 14, tooltip `Next Match ↵` | `find.next` |
| Fechar | `X` 14, tooltip `Close Esc` | `find.close` |

Teclas: ↵ próximo, ⇧↵ anterior, ⌘G / ⇧⌘G (enquanto a barra está aberta), Esc fecha e devolve o foco ao terminal. Implementação: busca pública do SwiftTerm; nunca a find bar embutida (`TerminalFindBarView`). Ocorrências realçadas no buffer: `#f0c674` @ 40%, atual `#fb923c` @ 70%.

### 4.5 Context menu do terminal

NSMenu via `menu(for:)` (`audit/07 #3`):
- `Copy` ⌘C (desabilitado sem seleção) · `Paste` ⌘V · `Select All` ⌘A
- separador
- `Find…` ⌘F · `Clear` ⌘K
- separador
- `Split Right` ⌘D · `Split Down` ⇧⌘D · `Equalize Pane Sizes` · `Expand Pane` ⇧⌘↵
- separador
- `Open Computer` (se há) · `Resume Conversation` (se interrompido) · `Copy Resume Command`
- `Rename…` · `Reset Title`
- separador
- `Restart` · `Close Pane` ⌘W
- com ⌥: `Copy Terminal ID` · `Copy Conversation ID` · `Copy Pane ID` · `Send Interrupt (⌃C)` · `Force Quit Process…`

Com link sob o cursor, no topo: `Open Link` · `Copy Link`; com caminho de arquivo: `Open File` · `Reveal in Finder` · `Copy Path`.

### 4.6 Estados do pane

| Estado | O que aparece | Ações | IDs |
|---|---|---|---|
| **Starting** (< 300 ms) | Nada (o terminal entra direto, M-506 regra dos 300 ms) | — | — |
| **Ignition** (≥ 300 ms ou com etapas) | Fundo `terminalBackground`; centro: logo do agente 32, abaixo **PhaseList** com as etapas reais, ex.: `Preparing launch` ✓ · `Creating worktree` ✓ · `Running setup script` (v1.1) · `Starting Claude Code…` (spinner). M-503 → M-504 | `[Cancel]` (`ghost sm`) | `pane.<id>.ignition`, `.ignition.step.<stepKey>`, `.cancel` |
| **Running** | Terminal | — | — |
| **Exited (code 0)** | Buffer intacto. Banner neutro no topo do pane (DS §12.20): `Claude Code exited.` (shell: `Process exited.`) | `[Resume]` (agente com ID) · `[Restart]` · `[Close Tab]` | `pane.<id>.exitBanner` |
| **Exited with error** (código ≠ 0 ou sinal) | Overlay no pane (M-312): escurece 35%, cartão `chrome` 360 centralizado: título `Terminal exited` (16/600), texto `The process ended with exit code <n>. Its output is preserved.` (sinal: `The process was killed (<SIGNAME>). Its output is preserved.`) | `[Close]` (outline) · `[Restart]` (primary) · `[Resume Conversation]` (agentes com ID) — agente com ID: primário = `[Resume Conversation]`, secundários `[Start Fresh]` e `[Close]`; `[Restart]` só aparece sem ID (F30) | `pane.<id>.exitOverlay`, `.restart`, `.close`, `.resume` |
| **Couldn't start** | Sem terminal. Centro: `AlertCircle` 20 `destructive`, `Couldn't start Claude Code` (16/600), erro em SF Mono 12 `textSecondary` (máx. 6 linhas, rola), M-313 / M-505 | `[Try Again]` · `[Open Agent Settings]` · `[Copy Details]` | `pane.<id>.startError` |
| **Reattached** (daemon manteve vivo) | Terminal com scrollback; nenhum aviso. Uma vez por abertura do app, toast `Reconnected to <n> running terminals.` | — | — |
| **Interrupted** (Mac reiniciou / processo morreu fora do app; M-002) | Último scrollback a 50% de opacidade + banner no topo: `This terminal stopped when your Mac restarted.` (ou `This terminal stopped while Racky was closed.`, ou `This terminal stopped unexpectedly.`) | Agente com ID: `[Resume]` (primary xs) · `[Start Fresh]`; shell: `[Restart]`; ambos `[Close]` | `pane.<id>.interrupted`, `.resume` |
| **Background service unavailable** | Terminal congelado + banner `warning`: `Lost connection to the background service. Reconnecting…` (spinner, M-003) | Após 10 s: `[Restart Background Service]` · `[Open Diagnostics]` | `pane.<id>.daemonBanner` |
| **Background agents stopped** (o serviço caiu e os PTYs morreram, AC-810) | Banner na janela `Background agents stopped unexpectedly.` + cada pane em **Interrupted** | `[Resume Agents…]` (§16.7) · `[Open Diagnostics]` | `window.daemonBanner` |
| **Closing** (depois de confirmar o fechamento) | Se o processo não sai em 5 s: banner `warning` `The process didn't exit.` | `[Force Quit]` (SIGKILL no grupo) · `[Cancel]` | `pane.<id>.closing.forceQuit` |
| **In container: preparing** (v1.1) | PhaseList com etapas do container: `Checking Docker` · `Pulling image` (barra com bytes) · `Creating container` · `Starting network proxy` · `Mounting workspace` · `Signing in to Claude Code` · `Starting Claude Code` | `[Cancel]` | `pane.<id>.containerPhases` |
| **In container: stopped** (v1.1) | Buffer 50% + banner `destructive`: `The container stopped.` | `[Restart Container]` · `[Close]` | `pane.<id>.containerStopped` |
| **Rate limit** (v1.1, R7.2) | Banner `warning`: `Claude hit its 5-hour limit. Resets at 2:20 PM.` | `[Continue in Codex]` · ✕ | `pane.<id>.rateLimit` |
| **Pane estreito** | < 240 de largura: título centralizado + `[Expand]` | — | `pane.<id>.tooNarrow` |

Nenhum estado usa "Ready to start" nem exige um ▶ para o processo começar (P9). A exceção é a sessão restaurada que nunca rodou (§4.7).

### 4.7 Sessão sem tabs

Acontece quando o usuário fecha a última tab, ou quando a sessão foi restaurada e nunca rodou (P15). Centro (fundo `canvas`), coluna 320 centralizada:
- Fechou tudo: `No terminals open in <session>.` (`body` `textSecondary`) · `[New Claude Code Tab ⌥⌘T]` (`secondary sm`, agente padrão) · `[New Terminal ⌘T]` (`ghost sm`) · `[Reopen Closed Tab ⇧⌘T]` (`ghost sm`, se houver).
- Restaurada (`Not started`): `Nothing is running yet.` · `[Start Claude Code]` (`primary sm`, agente padrão; o rótulo segue o agente) · `[Resume Conversation]` (`ghost sm`, só se há um ID de conversa registrado) · `[New Terminal ⌘T]`.
- ID: `pane.empty`, `.newAgent`, `.newTerminal`, `.reopen`, `.start`, `.resume`.

---

## 5. Status bar

24 de altura, fundo `chrome`, `border-top`, padding 0×12, gap 16, texto 12 (`label` 12/500 nos valores, `textSecondary`). Clique direito em qualquer ponto: menu com checkboxes de cada segmento + `Hide Status Bar` (volta em View › Show Status Bar ou Settings › Appearance). ID: `statusBar`.

| Lado | Segmento | Conteúdo | Clique | ID |
|---|---|---|---|---|
| Esq. | Claude usage | logo 12 + `5h 62%` + `·` + `7d 31%`; ≥ 80% `warning`, ≥ 95% `destructive` | Popover 300: barras 4 pt para 5h e 7d com `Resets at 2:20 PM` / `Resets Mon 9:00 AM`, fonte `From Claude Code statusline` | `statusBar.usage.claude` |
| Esq. | Codex usage | idem com logo Codex | idem (`From Codex session logs`) | `statusBar.usage.codex` |
| Dir. | Agents | indicador `sm` agregado + `4 working · 2 need you` (só os não-zero; "need you" = atenção agregada) | Abre a Inbox | `statusBar.agents` |
| Dir. | Computers | `Monitor` 12 + `3 computers · 6.1 GB` | Popover 320: lista (nome, sessão, estado, memória) com `Stop` por linha (abre §16.3) + `[Open Computers]` (página §12.3) | `statusBar.computers` |
| Dir. | Proxy usage | `Proxy $0.42 today` (P13): só aparece quando algum proxy configurado informa uso; sem limites nem cor de alerta (não há teto de orçamento) | Popover: uso por proxy, por sessão e por computador, conforme o provedor informa + `[Proxy Settings]` (Settings › Computers › Proxies) | `statusBar.proxyUsage` |
| Dir. | Docker | só quando há problema: `Docker isn't running` (`warning`) | `[Start Docker]` no popover | `statusBar.docker` |
| Dir. | Background | ponto `success` 6 + `Background on`; só aparece quando o app abriu e reencontrou processos vivos no background service (some após 1 h ou no clique) | Popover: `Agents keep running when you quit Racky.` + `[Settings]` (Settings › General) | `statusBar.background` |

Segmentos sem dados não aparecem (ex.: sem Codex instalado, sem proxy que informe uso).

---

## 6. Composer de nova sessão (⌘N)

Overlay DS §12.17, **560** de largura (máx. janela − 32). Abre por ⌘N, `+` do header Projects, `+` do projeto, palette (`New Session`), landing, menu `File` (M-101). Título `"New Session"` (`composerTitle` 16/600). Gap entre seções 16; labels `label` 12/500 `textSecondary`. **Foco inicial: Prompt** (AC-301, K-88).

### 6.1 Campos

| # | Campo | Controle | Padrão | Comportamento | ID |
|---|---|---|---|---|---|
| 1 | **Project** | `DSCombobox` com busca; itens: projetos (ícone + nome + caminho `textTertiary`), separador, `No Project (Clean Session)`, separador fixo `Add a New Project…` | Projeto da sessão atual; senão o último usado | `Add a New Project…` abre sub-overlay §16.9 preservando o que foi digitado | `overlay.composer.project` |
| 2 | **Where** | `DSSegmented` | Projeto: `New Worktree`; sem projeto: `New Folder` | Projeto: `New Worktree` · `Existing Worktree` · `Main Checkout`. Sem projeto: `New Folder` · `Choose Folder…` | `overlay.composer.where` |
| 3a | **Create from** (só New Worktree) | Input inteligente + seletor de base à direita do label (`origin/main ⌄`) | vazio = base | Aceita nome de branch, `#123` (issue/PR), URL de PR/issue do GitHub. Reconhecido: chip abaixo (`PR #412 · Fix search pagination` / `Branch exists`). Branch existente: checkbox `Reuse existing branch` (M-111). ↵ leva o foco para Agent | `overlay.composer.createFrom`, `.baseRef`, `.reuseBranch` |
| 3b | **Worktree** (Existing Worktree) | Combobox com worktrees do projeto, cada uma com branch e `Used by <session>` se já tiver sessão | — | Escolher uma em uso mostra aviso `warning` de uma linha: `Another session already uses this worktree.` | `overlay.composer.worktree` |
| 3c | **Folder** (Choose Folder…) | Campo de caminho read-only + `[Choose…]` (`NSOpenPanel` escuro) | — | Guarda o caminho; o app não usa security-scoped bookmarks (AR-533) | `overlay.composer.folder` |
| 4 | **Agent** | `DSCombobox`: `Claude Code` (padrão), `Codex`, `OpenCode`, separador, `Blank Terminal`; rodapé `Manage Agents…` | Agente padrão (Settings › Agents) | Rodapé `Manage Agents…` abre Settings › Agents. Clique direito num item: `Set as Default`. Agente não instalado: item desabilitado com `Not installed`; não logado: item com `TriangleAlert` e detalhe `Not logged in` (escolher mostra aviso com `[Log In]` que abre tab com o comando de login) | `overlay.composer.agent` |
| 5 | **Profile** | `DSCombobox` filtrado pelo agente; cada perfil mostra flags em `mono` | Perfil padrão do agente (ex.: `Claude · Skip permissions`) | Rodapé `Edit Profiles…` (Library › Profiles) | `overlay.composer.profile` |
| 6 | **Prompt** | `PromptEditor` (88–240), placeholder `What should the agent do? (optional)` | vazio | Vai como **argumento do CLI** (T11, R3.1); acima de 16 KiB vira arquivo referenciado (01, 06). Anexos por arrastar: later (R3.6). Com `Blank Terminal`, o campo some | `overlay.composer.prompt` |
| 7 | **Advanced** ⌄ | Disclosure (fechado; estado lembrado) | — | Ver §6.2 | `overlay.composer.advanced` |

### 6.2 Advanced

| Campo | Controle | Padrão | ID |
|---|---|---|---|
| Session name | input, placeholder com o nome automático | Derivado do prompt (3–5 primeiras palavras, como digitadas; pasta e branch usam o slug kebab-case, 06 §5.2); sem prompt, adjetivo + substantivo (`quiet-harbor`, P15) | `overlay.composer.name` |
| Branch name (New Worktree) | input mono | `<git user>/<session name>` (prefixo de Settings › Git) | `overlay.composer.branch` |
| Worktree location (New Worktree) | texto read-only mono `textSecondary` + `[Change…]` | `<worktree root>/<repo>/<session name>` (padrão `~/Racky/worktrees`, P21) | `overlay.composer.location` |
| Subagent computers (Fatia 3) | `DSSegmented`: `Off` · `On This Mac` · `In Container` (v1.1; na v1 o segmento não existe) | `On This Mac` | `overlay.composer.computers` |
| Subagents run as | `DSSegmented`: `Claude` · `Codex` · `OpenCode` · `Mixed` (só com Subagent computers ligado) | `Claude` | `overlay.composer.subagentHarness` |
| Save data to | `DSCombobox`: `Racky dataset (this app)` ou um lugar de uma conexão (tabela, nova tabela, pasta, aba, webhook), agrupado por conexão; texto embaixo diz o que acontece (âmbar numa conexão protegida) | `Racky` | `overlay.composer.dataDestination` |
| Computer proxy (Fatia 3, P13) | `DSCombobox`: `Default (<nome>)` · `None` · proxies de Settings › Computers › Proxies | o padrão de Settings | `overlay.composer.proxy` |
| Watch Claude subagents (Fatia 2) | switch | On (Claude) | `overlay.composer.watchSubagents` |

### 6.3 Footer e resumo

- Linha de resumo acima do footer, `small` mono `textSecondary`, uma linha truncada no meio, com tooltip completo: `claude --dangerously-skip-permissions "<prompt…>" in ~/Racky/worktrees/acme-platform/fix-search-pagination`. É a confirmação do que vai rodar (P9, `audit/07 #42`).
- Footer esquerdo: switch compacto `Create More` (mantém o overlay aberto e limpa o prompt).
- Footer direito: `[Cancel]` (outline sm, Esc) · `[Create Session]` (primary sm, keycaps `⌘↵`). Desabilitado só se faltar projeto ou pasta.
- Erro de validação (M-808): caixa `destructive/10` com borda `/40` acima do footer, ícone + uma linha (`Branch "x" already exists.` com link `Reuse it`). Erro por campo: `overlay.composer.<field>.error`.

### 6.4 Ao criar

1. Overlay fecha **na hora** (M-102 saída; M-501 chip voa para a sidebar quando aplicável, `overlay.composer.launchChip`).
2. Linha pendente na sidebar (§2.9); a sessão fica selecionada; o centro mostra a PhaseList.
3. Concluído: abre a tab já rodando o agente no diretório (P9). Sem tela vazia, sem ▶.
4. Erro (M-205): fica na linha pendente e no centro com `[Try Again]` · `[Use Existing Branch]` (se aplicável) · `[Create Without Fetching]` (fetch falhou) · `[Discard]`.

Teclado: ⌘↵ submete de qualquer campo; ↵ no trigger de Agent submete; Tab percorre; Esc fecha (com prompt digitado, Esc pede `Discard this session? [Keep Editing] [Discard]` inline no footer).

---

## 7. Quick Launch ("+" da tab row, ⌥⌘N)

Popover `DSMenuPanel` 300 de largura ancorado ao `+` (por atalho, ancorado ao `+` da sessão atual). Abre nova tab **na sessão atual** sem passar pelo composer.

| Bloco | Conteúdo | ID |
|---|---|---|
| Campo | placeholder `Start an agent or type a prompt…` (32) | `overlay.quickLaunch.input` |
| Agentes | `New Claude Code Tab` (logo) `⌥⌘T` se padrão · `New Codex Tab` · `New OpenCode Tab` · `New Terminal` `⌘T` | `overlay.quickLaunch.item.<agent>` |
| Perfis | seção "Saved profiles (agent with extra flags)": perfis do agente padrão e de outros, com flags em `mono` | `overlay.quickLaunch.profile.<id>` |
| Dados | seção "This session's data": "Open <dataset>" abre o dataset da sessão numa tab | `overlay.quickLaunch.dataset.<id>` |
| Outros | `Resume a Conversation…` (Fatia 2 em diante: abre o painel direito na aba Conversations, escopo Session; **não aparece na Fatia 1**, em que o painel direito é oculto) · `Open Computer…` (submenu com os computadores da sessão; abre o viewer; desabilitado sem computadores: `No computers in this session`) · `Agent Settings…` (abre Settings › Agents) | `overlay.quickLaunch.resume`, `.openComputer`, `.agentSettings` |
| Rodapé | `small` `textTertiary`: `↵ Open · ⌘↵ Start with prompt · Esc Close` | — |

Digitar filtra a lista; se o texto não casa com nenhum item, a primeira linha vira `Start Claude Code with "<text>"` (agente padrão) e ⌘↵ lança qualquer item selecionado com o texto como prompt. ⇧↵ abre em split à direita.

---

## 8. Command palette (⌘J)

Overlay ancorado a `min(10%, 64)` do topo, 720 de largura (máx. 96%), raio 14, `shadowPalette`. Input 48 (`paletteInput`), placeholder `Jump to a session, terminal, computer or command…`. Lista com altura máx. `min(560, janela − 224)`.

**Vazio:**
1. `Needs You` — terminais em `needsInput` e computadores pedindo ajuda, em ordem de espera.
2. `Recent Terminals` — últimos 6 panes focados (logo, título, sessão, estado, tempo).
3. `Recent Sessions` — últimas 6.

**Com texto**, grupos na ordem: `Sessions`, `Terminals`, `Computers`, `Projects`, `Skills & Agents` (só com `/`, abaixo), `Commands` (todas as ações do `KeyBindingRegistry` com o atalho à direita), `Settings` (seções e opções, abre o Settings já rolado e realçado por 3 s). Cada linha 32: ícone/logo 14 + título 13 + contexto `small` `textTertiary` + atalho/estado à direita. Trecho casado em 600.

Teclas: ↑↓, ↵ abre, ⇧↵ abre em split (terminais), ⌘↵ `New Session "<text>"` (sempre disponível), Tab alterna filtro de grupo (`All · Sessions · Terminals · Computers · Commands`), Esc fecha. Abertura: M-104.

Sem resultado: `No results for "<text>".` + linha selecionada `New Session "<text>"` `⌘↵`.

**Insert Skill or Agent** (R2 SEM #1; queixa 15). Comando `Insert Skill or Agent…` (grupo Commands, sem atalho) ou digitar `/` no início do campo põe a palette nesse modo: placeholder `Insert a skill or agent into the focused prompt…`, lista as skills e agentes da Library que o agente do pane focado entende (logo do harness, nome, fonte). ↵ cola o texto de invocação definido pelo adapter do CLI (06 §4.2; ex.: Claude `/<skill>`) no prompt do pane focado por **bracketed paste, sem Enter** (T11: é clique/tecla explícita do usuário), fecha a palette e devolve o foco ao terminal. Sem pane de agente focado, as linhas ficam desabilitadas com o motivo `Focus an agent terminal first.`. Mesma ação em `[Insert in Prompt]` na Library (§13) e no hover das linhas de skill/agente da aba Context (§10.6). Versão: v1, Fatia 4 (junto da Library).

Rodapé (28, `small`, `border-top`): `↵ Open · ⇧↵ Open in Split · ⌘↵ New Session · Tab Filter · Esc Close`.

IDs: `overlay.palette`, `overlay.palette.input`, `overlay.palette.row.<kind>.<id>`, `overlay.palette.filter`, `overlay.palette.insertMode`.

---

## 9. Notificações

### 9.1 Inbox (feed na sidebar)

Ativada pelo nav `Inbox` (⇧⌘I) ou pelo segmento `Agents` da status bar. Substitui o corpo da sidebar abaixo dos itens de nav (Search continua, filtrando o feed).

Header 32: `"Inbox"` (`sectionLabel`) + ações `header`: `Filter` (`SlidersHorizontal`: `All` · `Needs You` · `Unread`) e `Mark All as Read` (`Check` 14). Feed: M-705.

Grupos (`sectionLabel`, sticky): `Needs You` · `Working` · `Done` · `Earlier`. Item (48, duas linhas, raio 10, padding 8×10):
- Linha 1: indicador `sm` · logo 13 · `<session> · <agent>` (`body` 13; 600 se não lido) · tempo à direita.
- Linha 2: mensagem (`small` `textSecondary`, uma linha): última mensagem do agente, ou evento.
- Hover: ação `row` à direita `Mark as Read` (`Check`, tooltip `Mark as Read`) e, em pedidos de computador, `[Take Over]` (`xs outline`). Abrir é o clique na própria linha.
- Clique: vai até a sessão, pane ou viewer certo, com rim flash (M-309), e marca lido.

Tipos de evento e texto da linha 2:

| Evento | Linha 2 | Grupo |
|---|---|---|
| Agente em `needsInput` | `<last message>` | Needs You |
| Pedido de permissão (raro com skip permissions) | `Wants to run: <tool summary>` | Needs You |
| Computador pede ajuda | `<computer> needs you · CAPTCHA on <host>` | Needs You |
| Turno concluído | `<last message>` | Done |
| Agente falhou / saiu com erro | `Exited with code <n>` | Done |
| Subagentes ainda rodando | `Waiting on <n> subagents` | Working |
| PR mudou (v1.1, R5.4) | `PR #412 was merged` / `PR #412: 2 checks failing` | Done |
| Lote concluído (07 CS-326, `audit/08 N21`) | `<batch> finished · 12 done · 2 failed` (com pedidos abertos: só depois de resolvidos) | Done |
| Docker parado quando algo precisou | `Docker isn't running` + `[Start Docker]` | Needs You |
| Computador morreu / OOM | `<computer> stopped (out of memory)` | Done |
| Token Claude perto de vencer (v1.1) | `Claude token expires in 12 days` + `[Renew]` | Needs You |

Vazio: `Nothing needs you.` (`small`, centralizado). Esc ou clique em `Inbox` de novo volta à lista de sessões.

Sem eventos de orçamento: não há teto de gasto de proxy (P13).

IDs: `inbox`, `inbox.filter`, `inbox.markAllRead`, `inbox.empty`, `inbox.item.<eventId>`, `inbox.item.<eventId>.markRead`, `inbox.item.<eventId>.takeOver`.

### 9.2 Notificações do sistema

`UNUserNotificationCenter` com delegate (`audit/07 #38`; clique: M-702):
- Título: `<project> / <session> — <Agent> needs input` · `— <Agent> finished` · `— <Agent> failed`; computador: `<session> — <computer> needs you`, corpo `<Kind> on <host>` (CS-433). Sessão limpa: só `<session> — …`.
- Corpo: última mensagem (até 2 linhas) ou motivo do pedido (`CAPTCHA on aca-prod.accela.com`).
- Ação de categoria: `Open` (padrão, clique) e, para computadores, `Take Over`.
- Clique: ativa o app, seleciona sessão/pane/viewer, rim flash.
- Suprimida quando a janela é key **e** a sessão está visível (Settings › Notifications › `Suppress when the session is visible`, ligado). Cooldown 5 s por terminal. Prioridade: pedido de computador > pergunta/permissão > fim de turno (R6.4); (v1.1) pedido de computador sem resposta em 3 min gera **um** lembrete.
- Som: `System` padrão (config do dono).
- `threadIdentifier` = sessão (agrupa no Centro de Notificações).

### 9.3 Dock e atenção

- `NSApp.dockTile.badgeLabel` = nº de AttentionItems de prioridade 1–2 não resolvidos (pedidos de computador, needs input, falhas; 01 §5.12), vazio quando 0 (M-703).
- Pedido de computador com o app em segundo plano: `NSApp.requestUserAttention(.informationalRequest)`.

### 9.4 Toasts in-app

DS §12.19. Usos fixos (texto exato):
- `Session archived.` · ação `Undo` (8 s).
- `Session deleted.` · ação `Undo` (8 s; restaura só o registro, não pasta nem branch).
- `Tab closed.` · ação `Reopen` (⇧⌘T) — só quando fechada com processo vivo e confirmada.
- `Reconnected to <n> running terminals.`
- `"<title>" copied to the clipboard.` (OSC 52 write).
- `Couldn't <action>.` + descrição + `Copy Details` (60 s) — substitui o alert "Erro no workspace".
- `Copied URL.` · `Copied.` (ações de copiar, 4 s; M-809).
- `Inserted <name> into <Agent>.` (Insert Skill or Agent).
- `Not enough room to split. Close a pane or widen the window.`
- `Sort changed to <x>.` · `Undo`.
- `You can change this in Settings › <section>.` · `Open Settings` (após "Don't ask again").

---

## 10. Painel direito

Largura 310 (220–480), fundo `panel #171717`, `border-left`, resize 4/8. Abre/fecha com ⌘L (estado padrão: aberto, config do dono `rightSidebarOpenByDefault`; M-108). Recolhe sozinho abaixo de 1100 de largura de janela. Conteúdo **da sessão selecionada**. ID: `rightPanel`.

### 10.1 Activity bar

36 de altura no topo, botões `activity` 36×36 (ícone 16), ativo com sublinhado 2 (25–75%, `rightPanel.tabs.indicator`), inativo `textSecondary/60`, bolinhas de estado 7 no canto.

| Aba | Ícone | Atalho | Bolinha | ID |
|---|---|---|---|---|
| Source Control | `GitBranch` | ⇧⌘G | `gitModified` se dirty | `rightPanel.tab.sourceControl` |
| Checks | `ListChecks` | — | `checksFailing`/`checksPending` | `rightPanel.tab.checks` |
| Computers | `Monitor` | ⇧⌘C | laranja se pedido de ajuda | `rightPanel.tab.computers` |
| Conversations | `History` | ⇧⌘H | — | `rightPanel.tab.conversations` |
| Context | `Layers` | — | — | `rightPanel.tab.context` |

Overflow (largura pequena): `Ellipsis` com o resto. Tooltip com nome + atalho.

### 10.2 Source Control

Para sessões com Git. Sessão limpa: empty state `This session isn't a Git repository.`.

- **Header** (40): branch (mono 12, `GitBranch` 12) + `↑2 ↓0` (`microNumeric`) + `[Refresh]` (`RotateCw`, `row`, tooltip `Refresh`). Linha abaixo: `Based on origin/main` (`small` `textTertiary`).
- **Pull request** (bloco 56, aparece com PR): ícone de estado 16 + `#412 Fix search pagination` (13/500, link para o GitHub) + linha `Open · 2 checks failing · Review required` (`small`). Ações: `[Open on GitHub]` (`ghost xs`, `ExternalLink`) · `[Copy URL]`.
- **Sem PR, com push:** `[Create Pull Request…]` (`outline sm`): confirma em overlay pequeno com título, base, draft toggle e corpo pré-preenchidos (`gh pr create`); `Pushes <branch> and opens a pull request on GitHub.`
- **Changes** (lista): header `Changes` + contador; linhas 24: letra de status (A/M/D/U/R na cor DS §2.9, mono 11) + nome do arquivo 12 + pasta `textTertiary` + `+12 −3` (`microNumeric`, verde/vermelho git). Clique: abre diff só leitura numa tab (v1.1, R5.3); na v1 abre no editor configurado.
- **Rodapé:** `[Open in Editor]` (⇧⌘O) · `[Reveal in Finder]`.
- Sem stage/commit/push pela UI (fora do escopo, `audit/10 §11`).
- Estados: carregando (skeleton 3 linhas), sem alterações (`No changes.`), erro (`Couldn't read Git status.` + `[Try Again]`), `gh` não logado (`Log in to GitHub CLI to see pull requests.` + `[Log In]` → tab com `gh auth login`).
- IDs: `rightPanel.sourceControl.branch`, `.refresh`, `.pr`, `.createPR`, `.change.<path>`.

### 10.3 Checks

- Header: `Checks` + resumo `2 failing · 1 pending · 9 passing` + `[Refresh]`.
- Linhas 28: glifo de checks 12 + nome do job 12 + duração `microNumeric` + `ExternalLink` no hover. Agrupadas: failing, pending, passing (este recolhido por padrão).
- Ação (v1.1, R5.5): `[Send Failures to Claude Code]` (`outline sm`, cola nomes + trecho do log no prompt via bracketed paste, sem Enter, R5.1; antes mostra preview em popover com `[Paste]`).
- Estados: sem PR (`No pull request for this branch.`), sem checks (`No checks reported.`), carregando (skeleton), erro (`Couldn't read checks.` + `[Try Again]`).
- Polling: 30–60 s com a janela ativa, 5 min em segundo plano; `Updated 1m ago` no rodapé.
- IDs: `rightPanel.checks.row.<name>`, `rightPanel.checks.sendFailures`.

### 10.4 Computers (da sessão)

- Header: `Computers` + `3 running` (+ `· proxy $0.31 today` se o provedor informa) + `[+]` (`row`, tooltip `New Computer…` — cria computador manual ligado ao terminal focado, tipo padrão de Settings › Computers, modo On This Mac; desabilitado sem terminal de agente focado: `Focus an agent terminal first.`).
- Lista de **thumbnails** (DS §12.25), largura do painel − 24 (≈ 286×179 + rodapé 20), gap 12, ordenada por "needs you" > em uso > parado. Cada uma: frame vivo (≤ 1 fps, CS-403), borda de estado, rodapé com nome, dono (`logo 10` + agente), estado, uso do proxy (se informado). Hover amplia a miniatura (M-612) e mostra a URL atual e a última nota do journal.
- Clique: abre o viewer numa tab (§12). Botões no hover sobre a thumbnail: `Take Over` (`MousePointer2`), `Open in New Window`, `⋯` (menu da linha filha §2.8).
- Pedido de ajuda: a thumbnail ganha faixa `#fe6e00` no topo com `Needs you · CAPTCHA` e `[Take Over]`.
- Vazio (M-905): `No computers in this session. Agents create them when they need a browser.`
- IDs: `rightPanel.computers.new`, `rightPanel.computers.empty`, `rightPanel.computers.thumb.<computerId>`, `.takeOver`.

### 10.5 Conversations

Histórico de conversas do projeto (substitui "Retomar conversa", `audit/07 #49`).
- Header: campo de busca 28 `Search conversations` + escopo `DSSegmented xs`: `Session` · `Project` · `All`.
- Linha 48: logo 13 + primeira mensagem do usuário (13, uma linha) + `small`: `<branch> · <n> messages · 3h ago` + `Open in another terminal` (`warning`) se a conversa está ativa em outro lugar.
- Clique: menu de ações: `Resume in New Tab` (padrão, ↵) · `Resume in Split` · `Copy Resume Command` · `Show Transcript` (abre leitura no painel) · `Copy Conversation ID`.
- Transcript (leitura): substitui a lista com header `← Back` + título; mensagens em blocos `body` com papel (`You`, `Claude Code`, `Tool · Bash`) em `label`; subagentes como blocos recolhíveis; somente leitura.
- Fontes: Claude (`~/.claude/projects`), Codex (`~/.codex/sessions`), OpenCode (`session list`). Só metadados indexados.
- Estados: carregando (skeleton), vazio (`No conversations yet.`), fonte indisponível (`Couldn't read Codex sessions.` em linha `warning`).
- IDs: `rightPanel.conversations.search`, `.scope`, `.empty`, `.warning`, `.back`, `.transcript`, `.row.<id>`, `.row.<id>.resume`.

### 10.6 Context

O que está carregado nesta sessão (`audit/08 N24`, R9.1). Somente leitura na v1, com ativação aditiva por sessão.
- Grupos: `Agents`, `Skills`, `MCP Servers`, `Instructions` (`CLAUDE.md`, `AGENTS.md`).
- Linha 28: nome + fonte (`Global · ~/.claude/skills` / `Project · .claude/` / `This session`) em `small` + switch compacto nos itens que podem ser ligados só nesta sessão + `Insert in Prompt` no hover das skills e agentes (§8).
- Banner neutro quando algo mudou: `Changes apply the next time an agent starts in this session.` + `[Restart Agents with Resume]` (confirmação `Restart <n> agents?`; cada agente com ID de conversa é encerrado e relançado com `--resume` e as flags regeneradas; agentes sem ID não são tocados).
- Rodapé: `[Open Library]` (página §13).
- IDs: `rightPanel.context.item.<kind>.<id>`, `.toggle`.

### 10.7 Contêiner de módulos (Files, Insights, Computers)

Decisão P22 (spec `10-right-panel.md`): o painel direito é um contêiner de módulos, não mais uma activity bar de abas. Esta subseção vale onde divergir de §10.1–§10.6, que passam a ser módulos futuros.

- **Layout:** faixa de 36 alinhada com a tab row (os botões Files · Insights · painel flutuam no canto superior direito da janela, sobre a tab row com o painel fechado e sobre esta faixa com ele aberto) e, abaixo, até dois módulos de cima para baixo, cada um com header de 32 (ícone, título, acessório do módulo, `Minus` para minimizar; arrastar o header troca a posição). Divisor de 1 pt com área de arrasto de 9 entre os módulos; fração do módulo de cima padrão 2/3; nenhum módulo abaixo de 128 (header + 96).
- **Largura:** padrão 380 (260–720), arrastando o divisor nativo entre o centro e o painel; o centro nunca fica abaixo de 320. Persistida em `ui_state` (`rightPanel`) com a ordem, a visibilidade e a fração. Janela < 1100 recolhe o painel sozinho (reabre ao alargar); abrir por botão ou atalho abaixo disso mantém aberto até a janela alargar ou o usuário fechar. Sem largura para o mínimo de 260: toast `The window is too narrow for the right panel.`.
- **Modo compacto:** painel < 320: headers só com ícone, chip só com ícone, sem caminho nem contagem.
- **Motion (M-108):** abre 0,30 `expoOut` e fecha 0,20 `exitClip`, por recorte a partir da borda esquerda; o split muda de largura uma vez (primeiro quadro da abertura, último do fechamento); o arrasto de qualquer divisor da janela segura o resize do PTY até soltar. Reduce Motion: crossfade 0,15.
- **Files:** árvore do diretório da sessão; segue o cwd do terminal focado (OSC 7 e `cwd` dos hooks) com o chip `Following <Claude|Codex|OpenCode|Terminal>`; clicar no chip fixa a pasta (`Pinned`). Ignora `.git`, `node_modules` e o `.gitignore` (olho alterna). Alterados pelo `git status` com letra M/A/D/U/R e ponto nas pastas. Arquivo abre no visualizador (substitui a árvore, `←` volta): número de linha, realce leve, calha de alterações do git, busca, `Open in…`; ⌘-clique numa linha abre no editor externo.
- **Computers** é o terceiro módulo (sem botão na faixa): ⇧⌘C o mostra no painel.

---

## 11. Viewer de computador

Abre como **tab** (`computer`) na sessão dona; pode ir para janela própria (`Open in New Window`, `WindowGroup(for: ComputerID.self)`, `audit/07 #21`). Uma janela pop-out tem o mesmo layout sem a sidebar, título da janela `<computer> — Racky`, mínimo 640×420. Viewer: noVNC em `WKWebView` (T8).

### 11.1 Anatomia

```
┌ header 32 ──────────────────────────────────────────────────────────────┐
│ ▣ phoenix-az  [Desktop ⌄]  aca-prod.accela.com/…    (● Claude is using) [Take Over] [⧉] [⋯] │
├ thumbnail strip 72 (collapsible) ───────────────────────────────────────┤
│ [thumb][thumb][thumb]                                                    │
├ help banner 40 (only when requested) ───────────────────────────────────┤
│ ⚠ phoenix-az needs you · hCaptcha on the Accela search page  [Take Over] [Decline…] │
├ canvas (noVNC) ─────────────────────────────────────────────────────────┤
│                                                                          │
│                  (live border by control state)                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 11.2 Header (32, fundo `chrome`, `border-bottom`)

| Elemento | Spec | Ação | ID |
|---|---|---|---|
| Voltar | `ghost xs`, `ArrowLeft` + `Back to <sessão>` (nome da sessão de origem), primeiro item do header | Esc e ⌘W fazem o mesmo (Esc só com o teclado não capturado); volta à sessão/terminal anterior sem parar o computador (CS-405) | `viewer.<id>.back` |
| Ícone + nome | `Monitor` 14 + nome 13/500 | duplo clique renomeia | `viewer.<id>.name` |
| Modo | `DSCombobox xs`: `HTTP` · `Headless` · `Desktop` | Troca o tipo (preserva URL, cookies e storage, R4.4); trocar para HTTP pede confirmação `Switch <computer> to HTTP? The browser closes; cookies stay in the profile.` | `viewer.<id>.mode` |
| URL | mono 12 `textSecondary`, truncado no meio; clique copia (toast `Copied URL.`) | — | `viewer.<id>.url` |
| Pill de controle | 22 de altura, raio full, 11/500: agente `logo 10 + spinner + "Claude is using"` em `aiAccent/15` com texto `aiAccent`; agente parado há > 10 s `"Claude has control"` (sem spinner); humano `"You're in control"` em `fg10`; ajuda `"Needs you"` em `#fe6e00/15`; ocioso `"Idle"` | — | `viewer.<id>.controlPill` |
| Take Over / Hand Back | `primary xs` (`MousePointer2` / `Hand`) | ⇧⌘R; Hand Back abre o popover de nota (§11.5) | `viewer.<id>.takeOver`, `viewer.<id>.handBack` |
| Pop out | `toolbar`, `ExternalLink` 14, tooltip `Open in New Window` | Move o viewer para janela própria | `viewer.<id>.popOut` |
| Mais | `Ellipsis` → `Show Network`, `Show Journal`, `Show Files`, `Show Timeline` (abrem no painel direito › Computers › detalhe, §11.7), `Proxy ▸` (`None` · proxies de Settings › Computers › Proxies, com check no atual; P13; aplicação em 07), `Paste to Computer` (digita o texto do clipboard no computador, só com humano no controle; antes mostra o popover §16.12 com o texto), `Copy Selection from Computer` (copia a seleção do computador para o clipboard do Mac), `Reconnect`, separador, `Stop Computer…`, com ⌥ `Copy Computer ID`, `Open Shell` | — | `viewer.<id>.more` |

### 11.3 Thumbnail strip

72 de altura (thumbnails 104×65 + rodapé), fundo `canvas`, rola na horizontal; mostra **os outros computadores da sessão** (o atual com borda `ring`). Recolhível pelo chevron à direita (`Hide Other Computers`). Oculta quando a sessão tem um só computador. Clique troca o viewer para aquele computador (mesma tab). ID `viewer.<id>.strip`, `viewer.<id>.strip.thumb.<otherId>`.

### 11.4 Canvas e estados

| Estado | Visual (DS §2.8, M-604…M-611) | Texto/ações |
|---|---|---|
| `connecting` | Skeleton com brilho (M-603) | `Connecting…` (`viewer.<id>.connecting`) |
| Agente no controle | Borda viva 1,5 `aiAccent` (`viewer.<id>.controlFrame`); cursor fantasma e ripple de clique do agente (`.ghostCursor`, `.clickRipple`, M-605); input humano bloqueado (clique mostra tooltip `Claude is using this computer. Take over to interact.`) | — |
| `revoking` | Borda acelera e dessatura; botão `Requesting control…` com spinner, desabilitado (M-606) | Após 10 s sem ACK: `[Force Take Over]` (`destructive xs`) |
| Humano no controle | Borda 2 sólida `#fafafa`; teclado e mouse vão para o computador (M-607) | Selo de teclado capturado (§11.6) |
| Pedido de ajuda | Borda 2 `#fe6e00` respirando + **banner** de 40 sob a strip (fundo `#fe6e00/10`, borda inferior `/25`): `TriangleAlert` + `<computer> needs you · <reason>` + `[Take Over]` (primary xs) + `[Decline…]` (ghost xs; popover com motivo opcional `Reason (optional)` e `[Decline]`, texto `The agent will be told you declined.`; CS-432) (M-609, `viewer.<id>.helpBanner`) | — |
| `reconnecting` / `delayed` | Último frame 40% saturação + pill `Reconnecting…` / `Slow connection` (M-610, `viewer.<id>.status`) | `[Reconnect]` |
| `disconnected` | Frame escuro 30% + cartão `Disconnected from <computer>.` (M-611, `viewer.<id>.disconnected`) | `[Reconnect]` · `[Open Diagnostics]` |
| `stopped` | Último frame 30% + cartão `This computer is stopped.` (M-613) | `[Start Computer]` · `[Close Tab]` |
| `queued` | Cartão `Waiting for memory · 3 of 15 queued` + PhaseList (M-602) | `[Cancel]` |
| `provisioning` | `BoxProvisioningGlyph` 32 + PhaseList (`Checking Docker`, `Building image` ou `Pulling image`, `Creating computer`, `Starting network proxy`, `Starting browser` ou `Starting desktop`) (M-601) | `[Cancel]` |
| HTTP mode | Não há canvas: cartão `This computer is in HTTP mode and has no screen.` + `[Switch to Headless]` | — |

### 11.5 Hand Back (popover)

Ancorado ao botão `Hand Back`, 300 de largura: label `Note for Claude Code (optional)`, textarea 3 linhas placeholder `e.g. Logged in, continue from page 3`, footer `[Cancel]` · `[Hand Back ⌘↵]`. A nota segue para o agente com o estado reconciliado (R4.9; M-608). ID `viewer.<id>.handBack.note`, `.confirm`.

### 11.6 Captura de teclado

Com o humano no controle e o canvas focado, todo atalho vai para o computador (Cmd → Ctrl, 07 CS-420), **exceto** o conjunto reservado do app, que tem prioridade (08 A16) e nunca chega ao computador:

| Reservado | Efeito |
|---|---|
| ⌘Q | Quit (overlay §16.10) |
| ⌘W | Fecha a tab do viewer (escopo Viewer, §21); o computador segue rodando |
| ⇧⌘R | Hand Back |
| ⌘⎋ ou ⌃⌥ (juntos) | Solta o teclado |
| ⌘H, ⌘M, ⌃⌘F | Sistema (esconder, minimizar, tela cheia) |

Os demais atalhos **Global** de §21 (⌘N, ⌘T, ⌘J, ⌘1…⌘9, ⌘,, ⇧⌘T, ⌘B e outros) **não valem** com o canvas capturado: vão ao computador (por exemplo, ⌘T abre uma aba no browser do computador). Para usá-los, solte o teclado (⌘⎋ ou ⌃⌥) ou clique fora do canvas. ⌘C e ⌘V têm linhas próprias de escopo Viewer em §21. Ao soltar o teclado, o escopo Viewer deixa de valer e a tabela de §21 volta ao normal. Selo no canto superior esquerdo do canvas (pílula `chrome` 22, `Keyboard` 12 + `Keyboard captured · ⌃⌥ to release`), some 3 s após capturar e volta no hover do canto. ID `viewer.<id>.keyboardBadge`. Teste: XCUI com ⌘W, ⌘Q, ⌘⎋, ⌃⌥ e ⌘T (AC-414, 05).

### 11.7 Detalhe do computador ou do filho no painel

Aberto pelo `⋯` do viewer ou da linha filha: o painel direito › Computers troca a lista pelo detalhe (`← Back`), com `DSSegmented` (M-113): `Activity` · `Network` · `Journal` · `Commands` · `Files` · `Timeline` · `Result` (conjunto de 07 CS-320; comportamento em `07`). Abas sem dados não aparecem (ex.: `Result` antes do fim).
- **Activity**: chamadas de ferramenta do filho em ordem (hora, ferramenta, resumo, duração).
- **Network**: filtros chip (`All` · `XHR` · `Errors` · `Document`) + busca; linhas 28: método (mono 10 badge), status (cor: 2xx `success`, 4xx `warning`, 5xx `destructive`), host+path (mono 11), tamanho, tempo, origem (`browser`/`curl`/`python`). Clique abre detalhe (headers, body com `Copy as cURL`).
- **Journal**: entradas `PLAN`/`DOING`/`FOUND`/`BLOCKED` (badge mono, `BLOCKED` em `destructive`), texto, evidências como links para requests.
- **Commands**: comandos de `exec` (hora, comando mono, código de saída, duração); clique mostra stdout/stderr.
- **Files**: árvore de `/work` (mapeado para `~/Racky/runs/<session>/<computer>/work/`), `Reveal in Finder`.
- **Timeline**: lista combinada cronológica.
- **Result**: `result.json` formatado + evidências, `[Reveal in Finder]`.
IDs: `rightPanel.computer.<id>.tab.<name>` (`activity`, `network`, `journal`, `commands`, `files`, `timeline`, `result`).

---

## 12. Páginas do centro

Uma página substitui o pane tree e a tab row (M-109) por um **header de página** de 36 (4 de arrasto + 32, fundo `chrome`, `border-bottom`): título `label` 13/600 à esquerda, ações à direita, `X` (tooltip `Close Esc`) que volta à sessão. Esc fecha quando nenhum campo tem foco. O painel direito fica fechado enquanto a página está aberta (e volta ao estado anterior).

### 12.1 Landing vazia (sem projetos e sem sessões)

Ver §19.

### 12.2 Library — ver §13.

### 12.3 Computers (página global)

Título `"Computers"`. Ações do header: resumo `3 running · 6.1 of 16 GB` (`small`), `[Clean Up…]` (`outline xs`, v1.1, R10.4), `[Docker Settings]` (`ghost xs`, abre Settings › Docker).

- **Capacity bar** (40): barra 4 com memória usada da VM Docker + texto `≈ 9 more headless or 3 desktop computers fit` (R4.7). `warning` acima de 80%.
- **Queue** (só com fila): `Queued` + linhas com posição, pedido (`phoenix-az · Headless · requested by Claude Code in listings-oct`) e `[Cancel]`.
- **Tabela** (linhas 28, header 28 sticky `label` `textSecondary`): `Name` · `Session` · `Owner` (logo + agente/subagente) · `Mode` · `State` · `CPU` · `Memory` · `Proxy` (nome do proxy + uso se informado, ex. `zyte-us · $0.12`; sem limite) · `Last Used`. Ordenável por coluna. Clique: abre o viewer na sessão dona. Context menu = §2.8 computador. Multi-seleção com ⌘/⇧ para `Stop` e `Delete` em lote.
- **Clean Up…** (v1.1, overlay 512): lista com checkboxes: `Stopped computers older than 7 days (4 · 2.3 GB)`, `Run folders older than 30 days (12 · 1.1 GB)`, `Unused images (1 · 3.4 GB)`, `Orphaned containers (2)`; footer `[Cancel]` `[Clean Up]` (destructive). Nunca apaga resultados exportados.
- Estados: Docker parado (banner `Docker isn't running.` `[Start Docker]`, `computers.dockerBanner`, M-903), sem computadores (`No computers yet. Agents create them when they need a browser.`, `computers.empty`), erro de API (`Couldn't reach Docker.` `[Try Again]` `[Open Diagnostics]`).
- IDs: `computers.page`, `computers.cleanUp`, `computers.row.<id>`, `computers.queue.row.<id>.cancel`.

### 12.4 Batch (painel do lote, 07 CS-323)

Página do centro aberta pelo card da sessão do lote, pela notificação de lote concluído ou pela linha do pai. Título `"Batch · <name>"`. Header: resumo `12 of 15 done · 212 proxy requests · 18 min` (`small`), `[Collect All]` (`outline xs`), `[Archive Batch]` (`ghost xs`).
- Filtros chip: `All` · `Needs You` · `Blocked` · `Done`.
- Tabela (linhas 28): `Target` · `Subagent` (logo + estado) · `Computer` · `Verified` (`3/5`) · `Proxy` (uso, se informado) · `Duration`. Clique foca a linha filha e abre o detalhe no painel (§11.7). Colunas somem pela regra de §1.5 (`Proxy`, `Duration` primeiro).
- Vazio: `No targets yet.`; IDs: `batch.<batchId>.page`, `batch.<batchId>.row.<childId>`, `batch.<batchId>.collectAll`, `batch.<batchId>.archive`.

### 12.5 Datasets (lista e tabela viva, `docs/rebuild/spec/datasets.md`)

Duas páginas do centro, abertas pelo item `Datasets` da sidebar (`page.datasets`).

- **Lista** (título `"Datasets"`, resumo `3 datasets · 1,240 rows` em `small`): tabela com `Name` · `Session` · `Rows` · `Invalid` · `Columns` · `Updated`, mais recente primeiro. Clique abre o dataset (`dataset.open`). Vazio: `No datasets yet. Subagents create them when they collect tables of data.` (`datasets.empty`).
- **Dataset** (título = nome): resumo `<sessão> · 30 rows · 2 invalid · updated 3s ago`; barra com filtro `All | Invalid` (`dataset.filter`), busca (`dataset.search`) e `Export` (`dataset.export`, menu com `CSV`, `JSON Lines`, `JSON`: abre o painel de salvar; só linhas válidas saem). Corpo: tabela de 1.000 linhas por página com `Load more`; números em mono; linha inválida marcada com `Invalid` em `warning`. Atualiza a cada 1 s enquanto algum computador da sessão roda (a cada 5 s fora disso). Selecionar uma linha mostra a proveniência embaixo: `Source` (URL, abre no navegador), `Computer`, `Run`, `Request` (id, abre a evidência), selo `Observed` / `Agent-reported` / `No source`, primeira e última vez vista, `Seen` (contagem) e, se inválida, o erro.
- IDs: `datasets.page`, `datasets.empty`, `datasets.row.<id>`; `dataset.page`, `dataset.filter`, `dataset.search`, `dataset.export`, `dataset.table`, `dataset.empty`, `dataset.loadMore`, `dataset.row.<key>`, `dataset.provenance` e `dataset.provenance.{source,computer,run,request,trust,seen,error}`.

---

## 13. Library (⇧⌘L)

Página do centro. Título `"Library"`. Fonte da verdade são os arquivos nativos dos CLIs; o app indexa por referência (`audit/05 e`, `audit/10 J9`). **v1:** leitura, abrir no editor, ativação por sessão, perfis editáveis (perfis são do app). **v1.1:** criar/editar agentes e skills com backup (R9.2–R9.4).

### 13.1 Layout

```
┌ header 36: Library  [Agents | Skills | Profiles]          [+ New ▾] [X] ┐
├ list 320 ──────────────────┬ detail ──────────────────────────────────────┤
│ [Search agents]            │ name (pageTitle 24/600)                      │
│ Source: [All ⌄]            │ description                                   │
│ ─────────────────────────  │ meta table                                    │
│ row 48                     │ actions                                       │
│ row 48                     │ content preview (editor surface, mono 12)     │
└────────────────────────────┴───────────────────────────────────────────────┘
```

Segmented no header: `Agents` · `Skills` · `Profiles` (lembrado). Lista: busca 28 (`Search agents` / `Search skills` / `Search profiles`) + filtro de fonte `DSCombobox xs` (`All Sources`, `~/.claude`, `~/.codex`, `~/.agents`, `Plugins`, `This Project`, `Racky`) com contagem. Linhas 48 (DS §12.8 genérico): ícone/logo 16 + nome 13/500 + descrição `small` (1 linha) + chips de harness (logos 10 dos CLIs que entendem o item).

### 13.2 Agents

Detalhe:
- Título + descrição.
- Tabela de meta (`small`, rótulo `textSecondary` 96 de largura): `Source` (caminho mono + `Reveal`), `Works with` (logos), `Model`, `Tools`, `Skills` (chips), `MCP Servers` (chips; `racky computer` destacado), `Used by` (`2 running sessions`).
- Ações: `[New Session with Agent]` (primary sm → composer com agente `Claude Code` e `--agent <name>`), `[Enable in This Session]` (outline sm; ativação aditiva, aplicada no próximo lançamento), `[Insert in Prompt]` (ghost sm, §8), `[Open in Editor]` (ghost sm), `[Reveal in Finder]`. v1.1: `[Edit]`, `[Duplicate]`, `[Make Available to Codex]`, `Delete…`.
- Conteúdo: o `.md` em `editor` surface, SF Mono 12, rolável, somente leitura.
- Vazio: `No agents found in ~/.claude/agents or ~/.codex/agents.`

### 13.3 Skills

Detalhe: título, descrição, `Source`, `Files` (lista de arquivos da pasta da skill com tamanho; scripts marcados com `TriangleAlert` `warning` e tooltip `Contains executable scripts`), `Activation` (`Always on (global)` / `On in this session` / `Off`), `Used by`. Ações: `[Enable in This Session]` / `[Disable in This Session]` (só para skills não globais; para globais o botão não aparece e há a linha `Global skills load in every Claude Code session.`), `[Insert in Prompt]` (§8), `[Open in Editor]`, `[Reveal in Finder]`. Conteúdo do `SKILL.md`.

Conflito detectado (R1.6): a skill global `racky` aparece com badge `warning` `Conflicts with Racky` e ações `[Block in Racky]` (padrão; `permissions.deny` por lançamento, nada global muda) · `[Disable Globally…]` (move para backup, confirmação) · `[Keep]`. Texto: `A global "racky" skill is installed and may compete with Racky tools.`

### 13.4 Profiles

Perfis de lançamento (`LaunchProfile`): agente + modelo + modo de permissão + args + env.
- Lista: perfil padrão por agente (inclui `Claude · Skip permissions` / `Codex · Bypass approvals`, com o selo `Built-in` em `small`), perfis do usuário.
- Detalhe = **formulário editável** com a mesma regra de salvamento do Settings (§14.1):

| Campo | Controle | ID |
|---|---|---|
| Name | input | `library.profile.name` |
| Agent | combobox | `library.profile.agent` |
| Model | combobox com `Default` + modelos conhecidos | `library.profile.model` |
| Permissions | `DSSegmented`: `Ask` · `Accept Edits` · `Skip Permissions` (mostra uma linha `warning`: `Runs with --dangerously-skip-permissions.`) | `library.profile.permissions` |
| Extra arguments | input mono | `library.profile.args` |
| Environment | tabela chave/valor (+/−), valores podem referenciar segredos `$secret:NAME` | `library.profile.env` |
| Default for agent | switch | `library.profile.default` |

- Rodapé: linha de comando resultante (mono `small`): `claude --model opus --dangerously-skip-permissions`.
- Ações: `[New Session with Profile]`, `Duplicate`, `Delete…` (desabilitado no último perfil do agente: `An agent needs at least one profile.`).

### 13.5 Botão New ▾

`[+ New ▾]` (`outline xs`): `New Profile` (v1) · `New Agent…` (v1.1) · `Import Skill Folder…` (v1.1). ID `library.new`.

Lista → detalhe sem morph de card (M-112 como lista → detalhe; DS §15). IDs gerais: `library.page`, `library.section`, `library.search`, `library.source`, `library.empty`, `library.row.<kind>.<id>`, `library.detail.newSession`, `library.detail.enable`, `library.detail.insert`, `library.detail.openInEditor`, `library.detail.reveal`.

---

## 14. Settings (⌘,)

Página da janela inteira (sidebar, centro e painel dão lugar ao Settings; a faixa de titlebar fica). Não existe cena `Settings` separada nem sheet (`audit/03 bug 10`). Abre por ⌘,, menu do app, rodapé da sidebar, palette e deep links de erro (`audit/07 #47`). Entrada e saída: M-109.

### 14.1 Layout e regra de salvamento

- **Nav** 240, fundo `panel`, padding 8: `[← Back to App]` (`ghost sm`, Esc) · busca 28 `Search settings` (⌘F) · grupos com label uppercase 11/500 tracking 0,18 em (`AGENTS`, `WORKSPACE`, `COMPUTERS`, `INTERFACE`, `SYSTEM`) · itens 30 (DS §12.8 Settings nav).
- **Conteúdo** centralizado até 720, padding 40/32/96, fundo `canvas`. Título da seção `pageTitle` 24/600; seções internas com título 13/600 e gap 40; cada linha de configuração: rótulo `body` 13/500 + ajuda `small` `textSecondary` (≤ 1 linha) à esquerda, controle à direita (largura 240 para inputs/selects). Abaixo de 560 de conteúdo, rótulo em cima e controle embaixo (§1.5).
- Busca: filtra itens e seções; sem resultado `No settings found for "<query>".`; deep link realça a linha alvo com fundo `fg/6` que esmaece em 3 s.
- Seção escolhida é lembrada (`audit/07 #47`). Troca de seção: M-109.
- IDs: `settings.page`, `settings.back`, `settings.search`, `settings.nav.<section>`, cada controle `settings.<section>.<key>`.

**Regra de salvamento** (03-B22, queixa 8). Vale também para Library › Profiles e para o formulário de proxy:
1. Não existe botão Save nem Apply. Switch, checkbox, segmented, combobox e stepper salvam **na hora** em que mudam.
2. Campo de texto salva ao sair do campo (blur) ou com ↵; Esc dentro do campo desfaz a edição e volta ao valor salvo. Enquanto o texto difere do salvo, o campo mostra um ponto 6 `textTertiary` à direita (mudança pendente).
3. Valor inválido: borda `destructive` + mensagem de uma linha abaixo (M-808); o valor anterior continua valendo e salvo; sair do Settings com campo inválido descarta a edição inválida sem perguntar.
4. Sucesso não mostra toast; a confirmação é o próprio controle (M-809 só em ações de botão, como `[Test Connection]`). Erro de gravação: toast `Couldn't save <setting>.` (60 s, `Copy Details`) e o controle volta ao valor salvo.
5. Configuração que só vale para o que for lançado depois mostra a ajuda fixa `Applies to new terminals.`; nada pede reiniciar o app.
6. Gravação com debounce de 300 ms (§20).

### 14.2 Seções

**AGENTS**

`Agents` (`settings.nav.agents`)
- `Default agent` — combobox (Claude Code / Codex / OpenCode / Blank Terminal).
- Por agente (bloco com logo 16 + nome + versão + status `Logged in` `success` / `Not logged in` `warning` / `Not installed`):
  - `Executable` — caminho mono read-only + `[Change…]` (`NSOpenPanel`, valida que é executável) + `[Detect Again]` (refaz a busca no PATH do shell de login).
  - `Default profile` — combobox + `[Edit Profiles…]` (abre Library › Profiles).
  - `Status hooks` — `Installed for each launch` (`success`) + `[Show Details]` (popover com eventos suportados pela versão, T10).
  - Ações: `[Log In]` (abre tab com `claude /login` ou `codex login`), `[Check Again]` (refaz a detecção de versão e login).
- `Watch Claude subagents` — switch, on.
- `Racky skill` — linha de conflito (R1.6) quando aplicável: `A global "racky" skill is installed and may compete with Racky tools.` `[Block in Racky]` (padrão) · `[Disable Globally…]` · `[Keep]`. Depois de `Disable Globally…`: `[Restore Skill]` desfaz a partir do backup.

`Accounts` (`settings.nav.accounts`)
- `Claude Code` — `Logged in with Claude.ai (Team)`; sem `[Log Out]` (gerido pelo CLI); `[Open Login in Terminal]`.
- `Codex` — `Logged in with ChatGPT`.
- `GitHub CLI` — `Logged in as octocat · repo, workflow` / `[Log In]` (tab com `gh auth login`).
- `Isolated agents` (v1.1) — `Claude token` `Valid until Oct 2027` + `[Generate New Token]` (abre tab `claude setup-token`) + `[Test in a Container]`; aviso de uma linha: `Agents in containers can use this token.` (P7).

`Credentials` (`settings.nav.credentials`)
- Tabela: `Name` · `Scope` (`All sessions` / projeto / sessão) · `Value` (mascarado `••••3f9a`) · ações `Reveal` (Touch ID), `Edit`, `Delete…`.
- `[Add Credential]` (overlay pequeno: Name, Value, Scope) · `[Import .env File…]` (lista as chaves com checkbox antes de importar).
- Valores ficam no Vault do app (08 AR-510/511). Credenciais de proxy ficam em Settings › Computers › Proxies.
- Vazio: `No credentials saved.`

**WORKSPACE**

`General` (`settings.nav.general`)
- `Keep agents running when you quit` — switch, on (P4). Ajuda: `Terminals keep running in the background and reappear when you reopen Racky.` Se o item de login não foi aprovado: `warning` + `[Allow in Login Items]`.
- `Show menu bar icon` — `Always` · `When agents are running` (padrão). Não existe `Never` (P4: com o app em modo accessory, o ícone é a única porta de volta).
- `Ask before quitting with running agents` — switch, on (é o "Don't ask again" do §16.10).
- `Worktree folder` — caminho + `[Change…]`; padrão `~/Racky/worktrees` (P21).
- `Clean session folder` — caminho + `[Change…]`; padrão `~/Racky/sessions`.
- `Projects folder` — caminho + `[Change…]`; padrão `~/Racky/projects`. Onde `Clone from GitHub…` cria `<pasta>/<repo>` (F24).
- `Branch prefix` — `Git user name` (padrão) · `Custom` (input) · `None`.
- `Open in editor` — combobox com os editores detectados em `/Applications` e no PATH (Cursor, VS Code, Zed, Xcode, Sublime Text) + `Other…` (`NSOpenPanel` de app); é o destino de `Open in Editor` (⇧⌘O) em todo o app.
- `Open in terminal` — combobox (`Terminal`, `iTerm`, `Ghostty`, `Warp`, detectados) para "Open in another terminal".
- `Confirm before closing a running terminal` — switch, on.
- `Confirm before deleting a session` — switch, on.
- `Reset "Don't ask again" choices` — `[Reset]` (religa todas as confirmações; toast `Confirmations restored.`).

`GitHub` (`settings.nav.github`)
- `Source` — `GitHub CLI (gh)` (detectado) com status.
- `Refresh pull requests` — `Every 60 seconds while active` (padrão) · `Every 5 minutes` · `Manually`.
- `Show pull request on session cards` — switch, on.

`Import` (`settings.nav.import`)
- `racky CLI runs` (v1.1) — `[Import Runs…]`.

**COMPUTERS**

`Docker` (`settings.nav.docker`)
- `Docker context` — combobox com contextos (`desktop-linux` ativo) + status `Running · Docker Desktop 4.x` / `Not running` + `[Start Docker]` (T7).
- `Computer image` — `ghcr.io/…@sha256:…` (mono, truncado) + `Up to date` / `Update available` + `[Update]` · `[Build Locally]` (progresso inline com barra e bytes).
- `Docker memory` — `16 GB available to Docker` + `≈ 14 headless or 6 desktop computers` + link `Change in Docker Desktop`.

`Computers` (`settings.nav.computers`)
- `Let agents create computers` — switch, on (corrige o padrão `disabled` do app atual, `audit/03 bug 8`).
- `Default type` — `Headless` (padrão) · `Desktop` · `HTTP`.
- `Memory per computer` — stepper `2 GB` (mín. 2 GB para Desktop, 1 GB Headless).
- `CPUs per computer` — stepper `2`.
- `Max running computers` — stepper `15`; ajuda `More requests wait in a queue.`
- `Max desktop viewers streaming at once` — stepper `2`.
- `Keep run folders for` — `30 days` · `90 days` · `Forever`.
- `Subagent mode` (v1.1) — `On This Mac` · `In Container`.
- Não há orçamento nem corte automático de gasto (P13).

Subseção **Proxies** de `Computers` (P13; `ProxyProfile` de 07 CS-160; deep link `settings.computers.proxies`):
- Lista de proxies (linha 32: nome, tipo, host, geo, uso informado se houver; `settings.computers.proxies.row.<proxyId>`) + `[Add Proxy]` (`settings.computers.proxies.add`). Vazio: `No proxies. Computers connect directly.`
- `Default proxy for computers` — combobox `None` (padrão) · proxies da lista. É o que o composer (`Computer proxy`), o `New Batch…` e as ferramentas usam quando nada mais específico foi escolhido (cascata global → lote → reserva → menu do viewer, 07 CS-161).
- Formulário do proxy (overlay 512; depois de criado, regra de salvamento de §14.1): `Name` · `Preset` (`Custom` · `Zyte (proxy)` · `Zyte API (render)`; o preset só preenche campos) · `Type` (`HTTP` · `HTTPS` · `SOCKS5`) · `Host` · `Port` · `Username` · `Password` (Vault, mascarado) · `Country` (opcional) · `Extra CA certificate` (opcional, `[Choose…]`) · `Render endpoint` e `API key` (só com render) · `Price per request` / `Price per render` (opcionais, só informativos). `[Test Proxy]` (`settings.computers.proxies.test`; sobe um egress descartável e mostra `Exit IP 203.0.113.7 · US · 312 ms` em `success` ou o erro em uma linha) · `Delete…`.
- `Import from racky CLI…` — só aparece se o `.env` do CLI antigo tem chave Zyte: cria um proxy com preset `Zyte (proxy)`.
- Uso: medido pelo egress (requests, bytes, renders) e custo só informativo; nunca bloqueia nada.

**INTERFACE**

`Appearance` (`settings.nav.appearance`)
- `Theme` — `Dark` (único na v1; sem outras opções visíveis).
- `Interface font` — `Geist` (padrão) · `System`.
- `Show app name in titlebar` — switch, on (`Hide App Name` desliga).
- `Sidebar` — checkboxes dos itens de nav (`Inbox`, `Computers`, `Library`); `Show agent rows in session cards` (on); `Show session notes` (on).
- `Status bar` — switch `Show status bar` + checkboxes por segmento.
- `Reduce motion` — `Follow System` (padrão) · `On`.

`Terminal` (`settings.nav.terminal`) — todos os itens de DS §3 com os mesmos padrões: `Font`, `Size`, `Weight`, `Line height`, `Cursor` (`Block` · `Bar` · `Underline` + `Blink`), `Inactive pane opacity`, `Padding`, `Scrollback`, `Option key as Meta` (`Auto`…), `Copy on select`, `Trim trailing whitespace on copy`, `Allow apps to copy to the clipboard (OSC 52)`, `Ask before closing a running terminal`, `Renderer` (`Metal` · `Compatibility`). Preview de 6 linhas com o tema aplicado. `[Reload Shell Environment]` (recaptura o ambiente do shell de login, 06 §1.7; vale para terminais novos).

`Notifications` (`settings.nav.notifications`)
- Cartão de permissão (quando negada ou não pedida): `Notifications are off for Racky.` + `[Open System Settings]` (`audit/07 #39`).
- Switches: `Agent needs input` (on) · `Agent finished` (on) · `Agent failed` (on) · `Computer needs you` (on) · `Pull request and checks` (v1.1, on) · `Terminal bell` (off).
- `Suppress when the session is visible` (on).
- `Sound` — combobox (`System`, sons do macOS, `None`).
- `Dock badge` — switch, on.
- `[Send Test Notification]`.

`Shortcuts` (`settings.nav.shortcuts`)
- Tabela agrupada como §21 (grupo, ação, atalho em keycaps, escopo). Busca por ação ou tecla. v1: somente leitura com `[Reveal Keybindings File]` (mostra no Finder o JSON gerado do `KeyBindingRegistry`); v1.1: gravar atalho (`Record Shortcut`, conflitos em `warning`). Filtros `All` · `Modified` (v1.1) · `Conflicts` (v1.1).

**SYSTEM**

`Diagnostics` (`settings.nav.diagnostics`) — mesma checklist do onboarding (§15) em modo completo, mais:
- `Background service` — `Running · protocol v1 · 6 terminals` + `[Restart Background Service]` (confirma: `Running terminals will reconnect.`).
- `Database` — `OK · 3.2 MB · last backup today` + `[Back Up Now]` · `[Reveal]`.
- `Hooks` — últimos 20 eventos recebidos (hora, terminal, evento) em tabela mono.
- `Logs` — `[Reveal Logs in Finder]` · `[Export Diagnostics…]` (pacote .zip redigido; antes mostra a lista de arquivos; AR-603).
- `[Run All Checks Again]`.

`Advanced` (`settings.nav.advanced`)
- `Automation channel (racky ctl)` — switch, off (T13); ajuda `Lets scripts and agents drive Racky. Off by default.` Enquanto ligado, a faixa da titlebar mostra `Automation on` (AR-806).
- `Security model` — linha com `[Read]` que abre o texto publicado (AR-501).
- `Data location` — caminho read-only + `[Reveal]`.
- `Database` — `[Export Database…]` · `[Restore from Backup…]` (lista de backups com data; confirmação; AR-332).
- `Show technical details in menus` — switch off (mostra itens ⌥ sem precisar segurar ⌥).
- `Reset Racky…` — destrutivo, confirmação digitando `reset` (apaga banco e configurações do app; nunca pastas de sessão, worktrees nem run folders).

---

## 15. Onboarding (primeira abertura)

Overlay sobre a janela já no visual final (sidebar vazia), **640** de largura (máx. janela − 32), raio 14, padding 24. Não bloqueia: pode ser fechado e reaberto em Settings › Diagnostics ou no menu `Racky › Set Up Racky…`. Todas as detecções rodam em paralelo ao abrir (R1.1). Motion: M-004.

Título `"Set Up Racky"` (18/600). Descrição: `Racky checks what's on this Mac. Fix what you need now; the rest can wait.`

**Checklist** (linhas 56, cada uma: ícone de estado 16 [spinner / `CircleCheck` emerald / `TriangleAlert` warning / círculo vazio] + título 13/500 + detalhe `small` + ação à direita):

| # | Item | Detalhe (exemplos) | Ação | ID |
|---|---|---|---|---|
| 1 | `Claude Code` | `2.1.302 · Logged in` / `Not logged in` / `Not installed` | `[Log In]` (tab inline com `claude /login` dentro do onboarding, 6 linhas de terminal) / `[Install…]` (abre a página de instalação no navegador) | `onboarding.item.claude` |
| 2 | `Codex` | `0.160.0 · Logged in` | idem | `onboarding.item.codex` |
| 3 | `OpenCode` (opcional) | `1.18.34 · Login can't be verified` | — | `onboarding.item.opencode` |
| 4 | `GitHub CLI` | `Logged in as octocat · repo, workflow` | `[Log In]` (tab com `gh auth login`) | `onboarding.item.gh` |
| 5 | `Docker` | `Docker Desktop is installed but not running` / `Running · 16 GB · ≈ 14 headless computers` | `[Start Docker]` (espera o socket, spinner) | `onboarding.item.docker` |
| 6 | `Computer image` | `Not downloaded · 1.2 GB` / barra com bytes / `Ready` | `[Download]` (continua em segundo plano) | `onboarding.item.image` |
| 7 | `Notifications` | `So you know when an agent needs you.` | `[Allow]` | `onboarding.item.notifications` |
| 8 | `Keep agents running` | `Terminals survive quitting Racky.` | `[Allow in Login Items]` | `onboarding.item.background` |
| 9 | `Conflicts` (só se houver) | `A global "racky" skill may compete with Racky.` · `Codex notify is used by another app (left untouched).` | `[Block in Racky]` · `[Disable Globally…]` · `[Keep]` | `onboarding.item.conflicts` |

Itens 5 e 6 são da Fatia 3: antes dela, não renderizam.


**Footer da checklist:** esquerda `[Skip for Now]` (`ghost`; confirma inline: `Skip setup? You can finish it in Settings › Diagnostics.` `[Keep Setting Up]` `[Skip]`); direita `[Done]` (primary). `Done` fecha e abre o composer com o último projeto usado pré-selecionado (`audit/10 J1.5`); sem projetos, mostra a landing (§19).

IDs: `onboarding`, `onboarding.step.<name>`, `onboarding.item.<key>`, `onboarding.done`, `onboarding.skip`.

---

## 16. Dialogs e confirmações

Todos são overlays DS §12.18 (448), inclusive o do ⌘Q (§16.10). Nenhum usa `NSAlert`. Botão primário à direita; Esc = Cancel. Motion: M-103.

### 16.1 Fechar terminal com processo rodando

Gatilho: ⌘W, ✕ da tab/pane, `Close Tab`, quando o processo não é um shell ocioso (shell ocioso = o grupo de processos em primeiro plano do PTY é o próprio shell, segundo o daemon) e `Confirm before closing a running terminal` está ligado.
- Título: `Close this terminal?`
- Texto: agente — `Claude Code is still working. Closing ends the process; you can resume the conversation later.`; shell com comando — `"pnpm test" is still running. Closing ends it.`; em container (v1.1) — `This also stops the container and its computer.`
- Checkbox: `Don't ask again`
- Botões: `[Cancel]` · `[Close Terminal]` (destructive). Depois: SIGHUP/SIGTERM no grupo; se não sair em 5 s, o pane mostra `The process didn't exit.` `[Force Quit]` (§4.6).
- IDs: `overlay.confirmClose`, `.dontAsk`, `.cancel`, `.confirm`.

Fechar vários (Close Other Tabs, fechar sessão com 3 rodando): `Close 3 terminals?` com lista dos que rodam.

### 16.2 Archive session

- Título: `Archive "<session>"?`
- Texto: `Stops its terminals and computers. The folder, worktree and branch stay; you can restore it from Archived Sessions.`
- Botões: `[Cancel]` · `[Archive]` (primary). Depois: toast `Session archived.` `Undo`.
- IDs: `overlay.confirmArchive`, `.confirm`.

### 16.3 Stop computer

- Título: `Stop "<computer>"?`
- Texto On This Mac: `Claude Code keeps running on your Mac. The browser session is saved in the computer's profile.`; com agente usando: `Claude Code is using it right now.`; em container (v1.1): `This also stops Claude Code running in this container. Its conversation can be resumed.`
- Botões: `[Cancel]` · `[Stop Computer]` (destructive).
- IDs: `overlay.confirmStopComputer`, `.cancel`, `.confirm`.

### 16.4 Delete computer

- Título: `Delete "<computer>"?`
- Texto: `Removes the container and its profile (logins, cookies). Run files in ~/Racky/runs stay.`
- Botões: `[Cancel]` · `[Delete Computer]` (destructive).
- IDs: `overlay.confirmDeleteComputer`, `.confirm`.

### 16.5 Delete session

- Título: `Delete "<session>"?`
- Texto (worktree nova): `Stops its terminals and computers, removes the worktree folder and deletes the local branch "<branch>".`; aviso adicional `destructive` quando há alterações não commitadas ou commits não enviados: `3 uncommitted files and 2 unpushed commits will be lost.`; checkbox `Keep the branch`. Main checkout / pasta existente / sessão limpa com pasta escolhida: `Stops its terminals and computers. The folder stays on disk.` (sem checkbox de Lixo, AC-1105).
- Sessão limpa com pasta criada pelo app: texto `Stops its terminals and computers.` + checkbox `Move folder to Trash` (marcada; move `~/Racky/sessions/<name>` para o Lixo do macOS) + checkbox `Also delete run folders` (desmarcada; AC-1108).
- Sessão de worktree: antes de abrir o overlay o app lê o worktree (`GitService.inspectRemoval`, 06 §5.2); a leitura termina antes de o overlay abrir. Com perda (`.changes`, `destructive`): a lista dos primeiros arquivos alterados ou não rastreados e as contagens; sem `Don't ask again` e o overlay aparece mesmo com a confirmação desligada em Settings. Confirmar é a confirmação explícita do `--force`. `Keep the branch` desmarcada = `git branch -d` (nunca `-D`; se a branch não está mesclada ela fica e o toast avisa). Se surgir trabalho novo entre a abertura do overlay e o clique (mais arquivos ou commits que os listados), nada é apagado e o toast `The worktree changed.` pede para revisar. Falha ao ler: `Couldn't check the worktree.`; falha ao remover: `Couldn't delete the worktree.` com o erro e a sessão continua na sidebar. Sem Undo (a pasta saiu do disco).
- Checkbox: `Don't ask again` (só quando não há perda de dados).
- Botões: `[Cancel]` · `[Delete Session]` (destructive). Depois: toast `Session deleted.` `Undo` (8 s, restaura só o registro).
- IDs: `overlay.confirmDelete`, `.keepBranch`, `.trashFolder`, `.deleteRuns`, `.dontAsk`, `.cancel`, `.confirm`.

### 16.6 Remove project

- Título: `Remove "<project>" from Racky?`
- Texto: `Its <n> sessions are archived. No files, worktrees or branches are deleted.`
- Botões: `[Cancel]` · `[Remove Project]` (destructive).
- IDs: `overlay.confirmRemoveProject`, `.cancel`, `.confirm`.

### 16.7 Resume agents (após reboot ou em lote)

Overlay 512. Gatilho: abrir o app com terminais interrompidos (uma vez por boot), `Resume Agents…` da sessão, banner `Background agents stopped unexpectedly.`
- Título: `Resume interrupted agents?`
- Texto: `<n> agents stopped when your Mac restarted. Resuming uses your usage limits.` (R2.5)
- Lista agrupada por sessão, linhas 40 com checkbox (marcadas por padrão as que estavam `working`/`needsInput`): logo + agente + `<session>` + última mensagem (`small`) + modelo.
- Footer esquerdo: `Select All` / `Select None`. Direito: `[Not Now]` · `[Resume <n>]` (primary).
- Nunca retoma sozinho.
- IDs: `overlay.resume`, `overlay.resume.row.<terminalId>`, `overlay.resume.confirm`, `.cancel`, `.selectAll`, `.selectNone`.
- Custo à vista (R2.5): cada linha mostra o contexto que a retomada recarrega (`~84k tokens`, do último `usage` do transcript, ou bytes/4) e o texto do topo soma os marcados. Conversa que já roda noutro processo (F32): linha desabilitada com `Open in another terminal`, nunca marcada nem relançada. Agente que saiu sozinho (`exited`) aparece desmarcado. O botão relança com `--resume <id>` a cada 300 ms.

### 16.8 Move to Project (sessão limpa)

Gatilhos: `Move to Project…`, `Convert to Project…`, arrastar o card até um projeto (M-212).
- Título: `Move "<session>" to a project?`
- Campo: `Project` (combobox com os projetos; primeira opção `Convert to Project (use this folder as the project root)`).
- Texto: `The folder stays where it is. Agents keep running.` (mesmo PID, AC-1106). Convert cria projeto do tipo `git` se a pasta já é repositório, senão `folder`; o app não roda `git init` (v1.1).
- Botões: `[Cancel]` · `[Move]` (primary; vira `[Convert]` com a primeira opção).
- `Move Folder into Project…` (v1.1) é outra ação: só habilita com todos os terminais parados (tooltip `Stop all terminals in this session first`), move a pasta para dentro do projeto e atualiza caminhos.
- IDs: `overlay.moveToProject`, `.project`, `.cancel`, `.confirm`.

### 16.9 Add a Project

Overlay 512 (`audit/04 §5.1`). Título `Add a Project`.
- Ação principal grande (`secondary`, 56 de altura, ícone `FolderOpen` 20): `Choose a Folder…` / `A Git repository or any folder on this Mac.`
- `OTHER WAYS` (label 11/500): linhas navegáveis por ↑↓ com chip `↵` na selecionada: `Clone from URL` (v1.1; abre campos `Git URL` + `Parent folder` + `[Clone]` com `Cloning…`).
- Pasta com vários repos: `Found 4 repositories in this folder.` + checkboxes + `[Add 4 Projects]` (`[Stop Scan]` durante o scan).
- Depois de adicionar: detecta a base (`origin/main`) e volta ao chamador (composer ou sidebar).
- IDs: `overlay.addProject.choose`, `.clone`, `.clone.url`, `.clone.submit`.
- F24: o fluxo Add Project e o combobox Project do composer têm o item `Clone from GitHub…` (ação `project.cloneFromGitHub`), que abre o overlay §16.9b. A sidebar (ícone `Download` do header, estado vazio) e a landing (`Clone from GitHub…`) abrem o mesmo overlay.

### 16.9b Clone from GitHub (F24)

Overlay 512 (sub-overlay quando aberto pelo composer; o composer mantém o que foi digitado). Título `Clone from GitHub`.
- Campo (28, foco ao abrir): placeholder `Paste a repository URL or owner/repo`. Aceita URL https, SSH (`git@github.com:owner/repo.git`, `ssh://`) e `owner/repo`. Digitar também filtra a lista (nome, dono, linguagem, descrição). Quando o texto é uma referência válida, a primeira linha vira `Clone <owner/repo>` e fica selecionada.
- Lista `RECENT REPOSITORIES` (label 11/500; vira `RESULTS` com busca): repositórios da conta e das organizações via `gh repo list`, ordenados por `pushedAt`/`updatedAt` (mais recente primeiro), com cache de 5 min. Linha 44: nome 13/500 + `owner` em `textTertiary`, badge `Private`/`Public`, linguagem e `Updated 3 days ago` em `small`. ↑↓ navegam, ↵ clona o selecionado, Esc cancela.
- Sem `gh` logado (ou sem `gh`): faixa `Log in to GitHub to see your repositories.` com `[Log in to GitHub]` (abre uma tab com `gh auth login`); o campo continua aceitando URL pública.
- Clonar (↵ ou `[Clone]`): a lista dá lugar ao progresso no próprio painel (`Cloning octocat/Hello-World…`, barra determinada, fase `Receiving objects 42%`, `[Cancel]`) e a sidebar mostra a linha pendente `Cloning… 42%` com `Cancel`. Destino: `<Projects folder>/<repo>` (Settings › General › Folders › `Projects folder`, padrão `~/Racky/projects`). Pasta já existente com o mesmo remote vira o projeto sem clonar; pasta com outro conteúdo usa `<repo>-<owner>` ou falha com mensagem clara.
- Erro: mensagem de uma linha (`Repository not found. If it is private, log in to GitHub.`, `Couldn't reach GitHub.`, `A folder named x already exists and isn't this repository.`) com `[Try Again]`; nada fica pela metade (a pasta parcial é removida).
- Ao concluir: o painel fecha, o projeto é registrado e fica selecionado no composer (quando aberto por ele) ou aparece expandido na sidebar. Toast `Cloned <repo>.`
- IDs: `overlay.cloneRepo`, `.input`, `.list`, `.row.<id>`, `.progress`, `.logIn`, `.error`, `.retry`, `.cancel`, `.submit`.

### 16.9c Create Pull Request (overlay, T2-05)

Largura 480. Abre por `Create Pull Request…` (Source Control, menu da sessão, `ctl ui action git.createPR`). Nada é enviado até `[Create]` (AC-503).

- Título `Create Pull Request`. Campos: `Title` (input; pré-preenchido com o assunto do último commit, senão o nome da sessão), `Base` (input mono; `baseRefName` da origem ou branch padrão), `Description` (textarea, vazio), checkbox `Draft`.
- Prévia dos comandos, em mono `small` `textTertiary`: `git push -u origin <branch>` (só se não há upstream ou há commits à frente) e `gh pr create --base … --head … --title … --body-file … [--draft]`. Texto abaixo: `Pushes <branch> and opens a pull request on GitHub.` (ou `Opens a pull request on GitHub.` sem push).
- `[Create]` (primary) roda os passos na ordem com o botão em `loading` (`Creating…`); erro mantém o overlay com o texto do `git`/`gh` (token nunca aparece) e `[Try Again]`. Sucesso fecha o overlay, toast `Opened PR #<n>.` e o chip aparece na hora.
- `[Open Compare on GitHub]` (`ghost sm`) roda `gh pr create --web` (sem push, sem criar nada pelo app). `[Cancel]` (Esc). Título vazio: `Create` desabilitado, `Add a title.`.
- IDs: `overlay.createPR`, `.title`, `.base`, `.body`, `.draft`, `.preview`, `.error`, `.retry`, `.compare`, `.cancel`, `.submit`.

### 16.10 Quit with running agents (⌘Q)

Overlay de confirmação na janela (T5, P15, K-90). **Nunca `NSAlert`.** Se nenhuma janela está aberta (quit pelo Dock ou pela barra de menus), o app abre a janela principal e mostra o overlay nela. Só aparece se há processos de agente vivos e `Ask before quitting with running agents` está ligado.
- Título: `Quit Racky?`
- Texto: `4 agents are working and 2 computers are running. They keep running in the background and come back when you reopen Racky.`
- Botões: `[Cancel]` (Esc) · `[Stop All and Quit…]` (abre segunda confirmação: `Stop 4 agents and 2 computers? Unsaved work in those terminals is lost.` `[Cancel]` `[Stop All and Quit]`) · `[Keep Running]` (primary, ↵; fecha a janela e deixa o app em modo accessory, AR-108).
- Checkbox de supressão: `Don't ask again` (desliga `Ask before quitting with running agents`). Com a opção desligada, ⌘Q faz direto o `Keep Running`.
- Com `Keep agents running when you quit` desligado, o texto vira `4 agents are working. Quitting stops them.`, o primário vira `[Stop All and Quit]` (destructive) e o padrão (↵) é `Cancel`.
- `Quit Racky Completely` (menu bar, §17) encerra o app e tira o ícone; os agentes seguem no background service.
- IDs: `overlay.confirmQuit`, `.keepRunning`, `.stopAll`, `.cancel`, `.dontAsk`.

### 16.11 Skip permissions (primeiro uso de um perfil `Skip Permissions` não importado)

- Título: `Run Claude Code without permission prompts?`
- Texto: `The agent can run any command and edit any file in this session without asking.`
- Botões: `[Cancel]` · `[Use Skip Permissions]`.
- IDs: `overlay.confirmSkipPermissions`, `.confirm`.

### 16.12 Paste to agent (ação explícita, R5.1)

Popover ancorado ao botão que disparou (Send Failures, Ask Parent to Relaunch, Paste to Computer, resposta rápida): título `Paste into Claude Code`, preview do texto (mono 12, editável, máx. 8 linhas), texto `Pasted without pressing Return.`, `[Cancel]` · `[Paste]`. IDs: `popover.paste`, `.text`, `.confirm`.

### 16.13 Rename branch (com ⌥)

Overlay 448: título `Rename branch "<branch>"?`, input mono com o nome atual, texto `Renames the local branch. The remote branch isn't changed.`, `[Cancel]` · `[Rename Branch]`. Desabilitado (no menu) quando a branch já tem upstream: tooltip `This branch is already pushed.` IDs: `overlay.renameBranch`, `.name`, `.submit`.

### 16.14 About Racky

Overlay 448: tile do logo 64, `Racky`, versão e build (mono `small`), `Protocol v1 · Schema v<n>`, `[Licenses…]` (lista com Geist/OFL, SwiftTerm, GRDB, noVNC), `[Copy Version Info]`. IDs: `overlay.about`, `.licenses`, `.copy`.

### 16.15 New Batch… (07 CS-324)

Overlay 560 aberto pelo menu `File › New Batch…`, pela palette ou pelo `+` do header da página Computers. Título `New Batch`.
- `Targets` — textarea mono (uma linha por alvo) ou `[Import CSV…]`; contagem `15 targets`.
- `Brief` — `PromptEditor` com o template (`{{TASK}}`, `{{CONTEXT}}`, `{{OUTPUT_SPEC}}` e colunas do CSV, ex. `{{city}}`).
- `Computer type` (`Headless` · `Desktop` · `HTTP`) · `Proxy` (padrão de Settings, `None` ou proxies) · `Allowed proxies` (checkboxes).
- `Session` — sessão atual ou `New clean session` (padrão).
- Footer: `[Cancel]` · `[Start Batch]` (primary, ⌘↵). Ao criar: abre um terminal Claude pai com a skill de orquestração e o pedido como prompt inicial (T11); o app não orquestra sozinho.
- IDs: `overlay.newBatch`, `.targets`, `.importCSV`, `.brief`, `.display`, `.proxy`, `.allowedProxies`, `.session`, `.submit`.

---

## 17. Menu bar extra

Ícone na barra de menus enquanto o app roda (P4; Settings › General › `Show menu bar icon`: `Always` ou `When agents are running`). Depois do ⌘Q (`Keep Running`) o app fica em modo accessory e o ícone continua (AR-108); não há helper de login. `Quit Racky Completely` tira o ícone até reabrir. Motion: M-704.

- **Ícone:** template 18×18 (glifo da marca simplificado, monocromático, DS §9.2). Com AttentionItems de prioridade 1–2: número ao lado (`2`, 12/500 monoespaçado, via `button.title`). Com só não lidos: ponto âmbar 4 no canto. Trabalhando sem pendências: glifo normal (sem animação na barra de menus).
- **Menu** (`NSMenu`):
  - Cabeçalho desabilitado: `4 working · 2 need you · 3 computers`
  - `Needs You` (cabeçalho de seção) → itens: logo 16 + `<session> — <agent>` + subtítulo com a mensagem; clique abre a sessão (abre a janela se fechada). Pedido de computador: `<computer> needs you · CAPTCHA` (clique abre o viewer; submenu `Take Over` / `Open`: v1.1).
  - `Working` → até 8 itens; `+3 more…` abre a Inbox.
  - `Computers ▸` submenu com cada computador e estado; `Stop` por computador: v1.1.
  - separador
  - `Open Racky` · `New Session…` (abre a janela e o composer) · `New Clean Session`
  - `Pause Notifications for 1 Hour` / `Resume Notifications` (v1.1)
  - separador
  - `Stop All Agents…` (abre a janela com a confirmação `Stop <n> agents and <m> computers?`) · `Quit Racky Completely` (os agentes continuam; o ícone some até reabrir)
- IDs: `menuBar.icon`, `menuBar.item.<sessionId>`, `menuBar.open`, `menuBar.newSession`, `menuBar.newCleanSession`, `menuBar.stopAll`, `menuBar.quitCompletely`.

---

## 18. Menus do app (`.commands`)

Gerados do `KeyBindingRegistry` e do registro de ações (§24; `audit/07 #13`). Itens da versão atual que não se aplicam ficam desabilitados (nunca escondidos), com o motivo no Help do item; itens de versão futura não aparecem. Cada item tem efeito definido em §24.

**Racky**
- `About Racky`
- `Settings…` ⌘,
- `Set Up Racky…`
- separador · `Services ▸` · separador
- `Hide Racky` ⌘H · `Hide Others` ⌥⌘H · `Show All`
- `Quit Racky` ⌘Q (§16.10)

**File**
- `New Session…` ⌘N
- `New Clean Session` ⇧⌘N
- `New Clean Session in Folder…` ⌥⇧⌘N
- `New Batch…` (Fatia 3)
- `New Tab…` ⌥⌘N (Quick Launch)
- `New Agent Tab` ⌥⌘T
- `New Terminal` ⌘T
- separador
- `Add Project…`
- `Open in Editor` ⇧⌘O · `Reveal in Finder`
- separador
- `Close Pane` ⌘W · `Close Tab` · `Reopen Closed Tab` ⇧⌘T · `Close Window` ⇧⌘W

**Edit**
- `Undo` ⌘Z · `Redo` ⇧⌘Z · separador · `Cut` ⌘X · `Copy` ⌘C · `Paste` ⌘V · `Select All` ⌘A
- separador
- `Find ▸` → `Find…` ⌘F (roteado pelo escopo, §21) · `Find Next` ⌘G · `Find Previous` ⇧⌘G (só com a find bar aberta)
- `Clear Terminal` ⌘K
- separador · `Start Dictation` · `Emoji & Symbols` (sistema)

**View**
- `Toggle Sidebar` ⌘B · `Toggle Right Panel` ⌘L · `Show Status Bar` (check)
- separador
- `Source Control` ⇧⌘G · `Checks` · `Computers Panel` ⇧⌘C · `Conversations` ⇧⌘H · `Context`
- separador
- `Inbox` ⇧⌘I · `Library` ⇧⌘L · `Computers` (página)
- separador
- `Bigger` ⌘= · `Smaller` ⌘- · `Actual Size` ⌘0 (terminal focado: fonte do pane; fora do terminal: desabilitado na v1 com `Interface zoom isn't available yet.`; zoom da UI é later)
- separador · `Enter Full Screen` ⌃⌘F

**Session**
- `Jump To…` ⌘J
- `Insert Skill or Agent…`
- `Next Needing Attention` ⇧⌘A
- `Previous Session` ⇧⌘↑ · `Next Session` ⇧⌘↓
- `Back` ⌥⌘← · `Forward` ⌥⌘→
- `Focus Session List` ⇧⌘0
- separador
- `Rename Session…` ⌥⌘R · `Edit Note…` · `Mark as Read` (`Pin Session`: v1.1)
- `Resume Agents…`
- `Move to Project…` · `Convert to Project…` (sessão limpa)
- separador
- `Archive Session…` · `Delete Session…` ⇧⌘⌫

**Terminal**
- `Split Right` ⌘D · `Split Down` ⇧⌘D
- `Next Pane` ⌘] · `Previous Pane` ⌘[
- `Expand Pane` ⇧⌘↵ · `Equalize Pane Sizes`
- separador
- `Next Tab` ⇧⌘] · `Previous Tab` ⇧⌘[ · `Recent Tab` ⌃⇥ · `Select Tab ▸` (⌃1…⌃9)
- `Rename Tab…` ⌘R
- separador
- `Restart` · `Resume Conversation` · `Copy Resume Command`
- `Send Interrupt (⌃C)` · `Force Quit Process…`

**Computer** (Fatia 3)
- `Open Viewer` · `Open in New Window`
- `Take Over` / `Hand Back` ⇧⌘R
- `Release Keyboard` ⌘⎋
- separador
- `Show Network` · `Show Journal` · `Show Files`
- separador
- `Stop Computer…`

**Window**
- `Minimize` ⌘M · `Zoom` · separador · `Bring All to Front` · lista de janelas (principal + pop-outs de computador)

**Help**
- `Racky Help` · `Keyboard Shortcuts` ⌘/ · `Run Diagnostics` · `Reveal Logs in Finder` · `Export Diagnostics…`

Builds de desenvolvimento têm ainda o menu **Debug** com `Motion Lab` ⌃⌥⌘M (04); não existe em release.

IDs: os itens de menu recebem `accessibilityIdentifier` `menu.<group>.<action>` (ex.: `menu.terminal.splitRight`), com `<action>` = o `ActionID` de §24.

---

## 19. Tela vazia inicial (landing)

Quando não há projetos nem sessões (primeiro uso, depois do onboarding pulado). Centro `canvas`, coluna de 400 centralizada vertical e horizontalmente (M-901, só fade):
1. Tile do logo 64×64, raio 18, fundo `secondary`, glifo da marca 32 `textPrimary`.
2. `"Racky"` (`display` 28/600), margem superior 16.
3. `Run Claude Code, Codex and OpenCode side by side, each in its own folder.` (`dialogBody` 14 `textSecondary`), margem 8.
4. Botões (margem 24, gap 8): `[Add Project…]` (primary default) · `[New Clean Session]` (secondary default).
5. Lista de atalhos (320, margem 32), linhas 24 com label `small` à esquerda e keycaps à direita: `New session` ⌘N · `New clean session` ⇧⌘N · `Jump to…` ⌘J · `Settings` ⌘,.

Sem ilustração, sem texto de boas-vindas (DS §15). Com projetos mas nenhuma sessão selecionada (raro): o mesmo layout sem o item 3 e com `[New Session…]` primário.

IDs: `landing`, `landing.addProject`, `landing.cloneProject`, `landing.newCleanSession`, `landing.newSession`.

---

## 20. Comportamentos transversais de UI

| Tema | Regra |
|---|---|
| Seleção ↔ foco | Selecionar sessão restaura a tab e o pane focados dela. Foco do teclado vai para o terminal, salvo quando a ação veio da sidebar por teclado (foco fica na sidebar) |
| Persistência | Larguras, painéis abertos, seções recolhidas, aba do painel, seção do Settings, ordem manual, estado de Advanced do composer: salvos com debounce 300 ms (`audit/07 #55`, AR-711) |
| Ações longas | Sempre com estado no lugar onde foram pedidas (linha pendente, PhaseList, botão `loading`) e fim em sucesso ou erro com ação (RT.3, M-906) |
| Erros | Nunca `NSAlert`; toast de 60 s (não bloqueante) ou estado inline (bloqueante para aquela região) |
| Atalhos visíveis | Todo controle com atalho mostra o atalho no tooltip e no menu |
| Itens técnicos | Só com ⌥ ou com `Show technical details in menus` |
| Overlays | Contrato de foco DS §12.17; nunca mais de um sub-nível |
| Fatias | Controle de fatia ou versão futura não renderiza (feature flag por fatia); controle da fatia atual que não pode agir fica desabilitado com tooltip do motivo |
| Toda interação tem ação | Todo controle e item de menu é uma linha de §24; o teste de cobertura cruza §24 com os testes (AC-T02) e cada `ActionID` tem um XCUITest com clique ou atalho real |
| Fidelidade | Toda tarefa visual fecha com o OK do dono (P14) |
| Largura | Nada sai da caixa em 760×480 (§1.5) |

---

## 21. Tabela completa de atalhos (canônica)

Esta tabela é a fonte única de atalhos; 02, 04, 05, 06 e 07 a citam. 

Escopos: **Global** (funciona com o terminal focado; o app intercepta antes do PTY), **App** (fora do terminal ou via menu), **Terminal** (pane de terminal focado), **Find** (find bar aberta), **Viewer** (canvas do computador com controle humano), **Sidebar** (lista focada), **Settings** (página Settings aberta), **Overlay** (overlay aberto), **Palette** (palette ⌘J ou Quick Launch aberta) e **Menu** (menu ou context menu aberto). **Palette é escopo próprio, mais específico que Overlay:** enquanto a palette ou o Quick Launch está aberto, as linhas de escopo Overlay `Submit` (⌘↵) e `Next / Previous field` (⇥ / ⇧⇥) **não valem**; ⌘↵ e ⇥ têm só o significado das linhas Palette. Em conflito, o escopo mais específico vence. Teclas não listadas com o terminal focado vão para o PTY (teclado do terminal e tabela tecla → bytes em `06`).

Implementação: `KeyBindingRegistry` com escopo explícito por atalho. Um teste falha se dois atalhos colidem no mesmo escopo, se um atalho Global colide com a lista reservada ao terminal (fim desta seção) ou se um atalho de escopo Overlay colide com um de Palette sem que a tabela declare qual substitui qual (a verificação trata Palette como um escopo e a regra acima como a única substituição permitida). Resultado da. Item de menu cujo escopo não está ativo (ex.: ⇧⌘⌫ com o terminal focado) tem o key equivalent removido na validação do menu, e a tecla vai para o PTY.

| Grupo | Ação | Atalho | Escopo | Nota |
|---|---|---|---|---|
| App | Settings | ⌘, | Global | DS8 |
| App | Keyboard Shortcuts | ⌘/ | Global | abre Settings › Shortcuts |
| App | Quit | ⌘Q | Global | overlay §16.10 |
| App | Hide / Hide Others | ⌘H / ⌥⌘H | Global | sistema |
| Sessions | New Session (composer) | ⌘N | Global | |
| Sessions | New Clean Session | ⇧⌘N | Global | cria e abre o agente padrão na hora (P11) |
| Sessions | New Clean Session in Folder… | ⌥⇧⌘N | Global | escolhe a pasta antes |
| Sessions | Jump To… (palette) | ⌘J | Global | DS7 |
| Sessions | Next Needing Attention | ⇧⌘A | Global | R6.2 |
| Sessions | Select Session 1–9 | ⌘1 … ⌘9 | Global | ordem visível da sidebar (Fatia 2) |
| Sessions | Previous / Next Session | ⇧⌘↑ / ⇧⌘↓ | Global | |
| Sessions | Back / Forward | ⌥⌘← / ⌥⌘→ | Global | histórico de navegação; não é foco de pane |
| Sessions | Focus Session List | ⇧⌘0 | Global | |
| Sessions | Rename Session | ⌥⌘R | Global | inline |
| Sessions | Delete Session | ⇧⌘⌫ | App / Sidebar | confirmação §16.5; nunca com o terminal focado |
| Sessions | Open in Editor | ⇧⌘O | Global | editor de Settings › General |
| Tabs | New Tab (Quick Launch) | ⌥⌘N | Global | §7 |
| Tabs | New Agent Tab (default agent) | ⌥⌘T | Global | |
| Tabs | New Terminal | ⌘T | Global | shell na pasta da sessão (não abre lançador) |
| Tabs | Close Pane / Tab | ⌘W | Global | fecha o pane; com 1 pane, a tab; confirma se rodando |
| Tabs | Reopen Closed Tab | ⇧⌘T | Global | até 10 por sessão; nunca é atalho de viewer |
| Tabs | Close Window | ⇧⌘W | Global | |
| Tabs | Next / Previous Tab | ⇧⌘] / ⇧⌘[ | Global | |
| Tabs | Recent Tab / reverse | ⌃⇥ / ⌃⇧⇥ | Global | tirado do PTY de propósito |
| Tabs | Select Tab 1–9 | ⌃1 … ⌃9 | Global | tirado do PTY de propósito |
| Tabs | Rename Tab | ⌘R | Global | |
| Panes | Split Right | ⌘D | Global | mesmo agente e perfil |
| Panes | Split Down | ⇧⌘D | Global | |
| Panes | Next / Previous Pane | ⌘] / ⌘[ | Global | único atalho de foco de pane (sem ⌥⌘ setas) |
| Panes | Expand / Collapse Pane | ⇧⌘↵ | Global | |
| Find | Find | ⌘F | roteado | terminal focado: find bar; sidebar focada: busca da sidebar; Settings aberto: busca do Settings; página Library/Computers: busca da página; viewer com controle humano: vai ao computador |
| Find | Find Next / Previous | ⌘G / ⇧⌘G, ↵ / ⇧↵ | Find | ⇧⌘G só vale com a barra aberta |
| Find | Close Find | Esc | Find | devolve foco ao terminal |
| Terminal | Clear | ⌘K | Terminal | DS7 |
| Terminal | Copy / Paste / Select All | ⌘C / ⌘V / ⌘A | Terminal | |
| Terminal | Send Interrupt | ⌃C | Terminal | reservado ao terminal: vai ao PTY como ^C (o app não captura). O item de menu `Send Interrupt` (`terminal.sendInterrupt`) envia SIGINT ao grupo em primeiro plano pelo daemon |
| Terminal | Font Bigger / Smaller / Reset | ⌘= / ⌘- / ⌘0 | Terminal | por pane; fora do terminal desabilitado na v1 (zoom da UI: later) |
| Terminal | Open link | ⌘-clique | Terminal | |
| Panels | Toggle Sidebar | ⌘B | Global | |
| Panels | Toggle Right Panel | ⌘L | Global | **Fatia 2 em diante.** Na Fatia 1 o painel direito é oculto (09 T1-10): o atalho e o item de menu não existem |
| Panels | Toggle Files / Insights / Right Panel | ⌥⌘1 / ⌥⌘2 / ⌥⌘0 | Global | 10-right-panel §1: liga/desliga o módulo (botões Files e Insights da faixa de topo) e o painel inteiro; ⌥ com dígito não é do terminal (só ⌥ + letra é) |
| Panels | Source Control | ⇧⌘G | Global (exceto Find) | |
| Panels | Computers panel | ⇧⌘C | Global | aba da sessão; a página global Computers não tem atalho |
| Panels | Conversations | ⇧⌘H | Global | |
| Pages | Inbox | ⇧⌘I | Global | |
| Pages | Library | ⇧⌘L | Global | |
| Pages | Close page | Esc | App | sem campo focado |
| Computer | Take Over / Hand Back | ⇧⌘R | Global (com viewer ativo) / Viewer | Hand Back abre a nota; ⌘↵ confirma |
| Computer | Release Keyboard | ⌘⎋ ou ⌃⌥ | Viewer | sempre reservado, nunca vai ao computador |
| Computer | Close Viewer Tab | ⌘W | Viewer | o app mantém ⌘W com o teclado capturado (08 A16): fecha a tab do viewer, nunca vai ao computador; o computador segue rodando |
| Computer | Copy (dentro do computador) | ⌘C | Viewer | vai ao computador como ⌃C (Cmd → Ctrl, 07 CS-420); não toca o clipboard do Mac (07 CS-422) |
| Computer | Paste to Computer | ⌘V | Viewer | só com controle humano: digita no computador o texto do clipboard do Mac (07 CS-422, §11.2); sem controle humano não faz nada |
| Overlay | Submit | ⌘↵ | Overlay | não vale na palette nem no Quick Launch (escopo Palette) |
| Overlay | Cancel / Close | Esc | Overlay | |
| Overlay | Next / Previous field | ⇥ / ⇧⇥ | Overlay | foco preso no overlay; não vale na palette nem no Quick Launch (⇥ é `Cycle filter` lá) |
| Palette | Open in Split | ⇧↵ | Palette | palette e Quick Launch |
| Palette | New Session with text / Start with prompt | ⌘↵ | Palette | palette: `New Session "<text>"`; Quick Launch: lança o item com o texto como prompt |
| Palette | Cycle filter | ⇥ | Palette | só a palette (§8) |
| Palette | Insert mode | `/` no início do campo | Palette | §8 (Fatia 4) |
| Sidebar | Move / Expand / Collapse | ↑ ↓ / → / ← | Sidebar | |
| Sidebar | Focus terminal of item | ↵ | Sidebar | |
| Sidebar | Show details | Space | Sidebar | hover card |
| Window | Minimize / Full Screen | ⌘M / ⌃⌘F | Global | sistema |
| Menus | Itens extras (Refresh Git, Copy Project/Session/Terminal/Conversation/Pane ID, Show Launch Details, Rename Branch, Show Hook Log, Copy Computer ID, Open Shell) | ⌥ (segurar ao abrir o menu) | Menu | modificador isolado, não colide com atalho; os itens estão em §24 com a marca (⌥) |
| Debug | Motion Lab | ⌃⌥⌘M | Global | só builds de desenvolvimento (04); ⌥⌘M é "Minimize All" do sistema e não é usado |

Fora da tabela por serem convenção de campo de texto (setas, ↵ e Esc dentro de inputs) ou do sistema. Não existem: ⇧⌘E (o "Reveal Current Session" é o botão do rodapé, §2.12), ⌥⌘ setas para panes, ⇧⌘T no viewer, ⌘T como lançador.

Atalhos reservados para o terminal (nunca capturados pelo app): ⌃ + letra, ⌥ + letra (conforme Option as Meta), ⌘← / ⌘→ / ⌘⌫ (traduzidos para ^A / ^E / ^U), ⇧↵ (CSI-u), ⌥← / ⌥→ (palavra). Exceções deliberadas, todas Global: ⌃⇥, ⌃⇧⇥, ⌃1…⌃9. Detalhes em `06`.

---

## 22. Índice canônico de `accessibilityIdentifier`

**Lista única e canônica** (T13). Formato e regras em DS §17; 04, 05, 07 e 08 citam esta seção e não definem IDs próprios. O enum `A11yID` é gerado desta tabela; o teste de varredura (AC-T01) falha com ID fora dela. Mapeamento dos nomes antigos de 04 em `review/R1-consistency.md` §4. Convenções: `<id>` curto de 8 caracteres; `<host>` é o ID do elemento que contém; botão primário de formulário `.submit`, de confirmação `.confirm`, cancelar `.cancel`; o indicador de estado de qualquer linha, tab ou pane é `<host>.status` (AR-805).

| Superfície | Identificadores |
|---|---|
| Janela | `window.main`, `window.titlebar`, `window.appName`, `window.sidebarToggle`, `window.historyBack`, `window.historyForward`, `window.automationBadge`, `window.daemonBanner`, `window.databaseBanner` |
| Erros | `<region>.errorBoundary`, `<region>.errorBoundary.retry`, `<region>.errorBoundary.copy` |
| Genéricos | `<host>.status`, `<host>.hoverCard`, `<panel>.empty`, `tooltip`, `menuPanel.<name>`, `popover.<name>[.<field>/.confirm]` |
| Sidebar | `sidebar`, `sidebar.selection`, `sidebar.search`, `sidebar.search.clear`, `sidebar.search.empty`, `sidebar.search.empty.clear`, `sidebar.nav.inbox`, `sidebar.nav.inbox.badge`, `sidebar.nav.sessions`, `sidebar.nav.sessions.badge`, `sidebar.needsYou`, `sidebar.nav.computers`, `sidebar.nav.datasets`, `sidebar.nav.library`, `sidebar.projects.filter`, `sidebar.projects.filterMenu`, `sidebar.projects.add`, `sidebar.projects.newSession`, `sidebar.project.<id>[.toggle/.menu/.newSession/.showMore/.rename]`, `sidebar.session.<id>[.name/.status/.archive/.prChip/.note/.summaryPill/.hoverCard/.phase/.error/.agents/.rename/.revealGlow/.showMore/.computers/.restartToApply/.disclosure]`, `sidebar.session.<id>.pin` (v1.1), `sidebar.session.<id>.agent.<terminalId>[.status/.lastMessage/.children.toggle/.control/.handBack]`, `sidebar.session.<id>.child.<childId>[.status/.glyph/.connector/.title/.elapsed/.hoverCard/.preview/.openViewer/.control/.handBack]`, `sidebar.session.<id>.dataset.<datasetId>`, `sidebar.pending.<id>[.cancel]`, `sidebar.cleanSessions`, `sidebar.cleanSessions.new`, `sidebar.footer.settings`, `sidebar.footer.reveal` |
| Sidebar | `sidebar`, `sidebar.selection`, `sidebar.search`, `sidebar.search.clear`, `sidebar.search.empty`, `sidebar.search.empty.clear`, `sidebar.nav.inbox`, `sidebar.nav.inbox.badge`, `sidebar.nav.computers`, `sidebar.nav.datasets`, `sidebar.nav.library`, `sidebar.projects.filter`, `sidebar.projects.filterMenu`, `sidebar.projects.add`, `sidebar.projects.clone`, `sidebar.projects.newSession`, `sidebar.project.<id>[.toggle/.menu/.newSession/.showMore/.rename]`, `sidebar.session.<id>[.name/.status/.archive/.prChip/.note/.summaryPill/.hoverCard/.phase/.error/.agents/.rename/.revealGlow/.showMore]`, `sidebar.session.<id>.pin` (v1.1), `sidebar.session.<id>.agent.<terminalId>[.status/.lastMessage/.children.toggle/.control/.handBack]`, `sidebar.session.<id>.child.<childId>[.status/.glyph/.connector]`, `sidebar.pending.<id>[.cancel]`, `sidebar.cleanSessions`, `sidebar.cleanSessions.new`, `sidebar.footer.settings`, `sidebar.footer.reveal` |
| Tabs | `tabs.tab.<terminalId>[.close/.title/.restart/.status]`, `tabs.activeIndicator`, `tabs.overflow.leading`, `tabs.overflow.trailing`, `tabs.new`, `tabs.quickCommands` (v1.1), `tabs.paneActions`, `tabs.rightPanelToggle` |
| Panes | `pane.<id>`, `pane.<id>.terminal`, `pane.<id>.header`, `pane.<id>.status`, `.splitRight`, `.splitDown`, `.expand`, `.close`, `.cover`, `.rimFlash`, `.attention`, `.zoomPill`, `.feedbackPill`, `.computers`, `.approval[.allow/.allowSession/.deny/.proxy/.leftovers]`, `.ignition[.cancel]`, `.ignition.step.<stepKey>`, `.exitBanner`, `.exitOverlay[.restart/.close/.resume]`, `.startError`, `.interrupted[.resume]`, `.daemonBanner`, `.closing.forceQuit`, `.containerPopover` (v1.1), `.containerPhases` (v1.1), `.containerStopped` (v1.1), `.rateLimit` (v1.1), `.tooNarrow`; `pane.divider.<id>`; `pane.empty[.newAgent/.newTerminal/.reopen/.start/.resume]`, `pane.empty.agent.<provider>` |
| Sidebar | `sidebar`, `sidebar.selection`, `sidebar.search`, `sidebar.search.clear`, `sidebar.search.empty`, `sidebar.search.empty.clear`, `sidebar.nav.inbox`, `sidebar.nav.inbox.badge`, `sidebar.nav.computers`, `sidebar.nav.datasets`, `sidebar.nav.library`, `sidebar.projects.filter`, `sidebar.projects.filterMenu`, `sidebar.projects.add`, `sidebar.projects.newSession`, `sidebar.project.<id>[.toggle/.menu/.newSession/.showMore/.rename]`, `sidebar.session.<id>[.name/.status/.archive/.prChip/.note/.summaryPill/.hoverCard/.phase/.error/.agents/.rename/.revealGlow/.showMore]`, `sidebar.session.<id>.pin` (v1.1), `sidebar.session.<id>.agent.<terminalId>[.status/.lastMessage/.children.toggle/.control/.handBack]`, `sidebar.session.<id>.child.<childId>[.status/.glyph/.connector]`, `sidebar.pending.<id>[.cancel]`, `sidebar.cleanSessions`, `sidebar.cleanSessions.new`, `sidebar.footer.settings`, `sidebar.footer.reveal` |
| Tabs | `tabs.tab.<terminalId>[.close/.title/.restart/.status]`, `tabs.activeIndicator`, `tabs.overflow.leading`, `tabs.overflow.trailing`, `tabs.new`, `tabs.quickCommands` (v1.1), `tabs.paneActions`, `tabs.rightPanelToggle`, `tabs.dropIndicator`, `subtabs`, `subtabs.terminal`, `subtabs.computer.<computerId>` |
| Panes | `pane.<id>`, `pane.<id>.terminal`, `pane.<id>.header`, `pane.<id>.status`, `.splitRight`, `.splitDown`, `.expand`, `.close`, `.cover`, `.rimFlash`, `.attention`, `.zoomPill`, `.feedbackPill`, `.ignition[.cancel]`, `.ignition.step.<stepKey>`, `.exitBanner`, `.exitOverlay[.restart/.close/.resume]`, `.startError`, `.interrupted[.resume]`, `.daemonBanner`, `.closing.forceQuit`, `.containerPopover` (v1.1), `.containerPhases` (v1.1), `.containerStopped` (v1.1), `.rateLimit` (v1.1), `.tooNarrow`; `pane.divider.<id>`, `pane.dropOverlay`, `pane.dropZone.<zone>`, `pane.dragGhost`; `pane.empty[.newAgent/.newTerminal/.reopen/.start/.resume]`, `pane.empty.agent.<provider>` |
| Find | `find.field`, `find.count`, `find.caseSensitive`, `find.regex`, `find.previous`, `find.next`, `find.close` |
| Status bar | `statusBar`, `statusBar.usage.claude`, `statusBar.usage.codex`, `statusBar.agents`, `statusBar.computers`, `statusBar.proxyUsage`, `statusBar.docker`, `statusBar.background`, `statusBar.popover.<segment>`, `statusBar.popover.computers.stop.<computer>`, `statusBar.popover.openComputers`, `statusBar.popover.proxySettings`, `statusBar.popover.startDocker` |
| Overlays (geral) | `overlay.scrim`, `overlay.<name>`, `overlay.<name>.advanced`, `overlay.<name>.<field>.error`, `overlay.<name>.submit`, `overlay.<name>.cancel` |
| Composer | `overlay.composer`, `.project`, `.where`, `.createFrom`, `.baseRef`, `.reuseBranch`, `.worktree`, `.folder`, `.agent`, `.profile`, `.prompt`, `.advanced`, `.name`, `.branch`, `.location`, `.computers`, `.subagentHarness`, `.dataDestination`, `.proxy`, `.watchSubagents`, `.summary`, `.skipPermissions`, `.riskNote`, `.dataNote`, `.createMore`, `.cancel`, `.submit`, `.launchChip`, `.<field>.error` |
| Quick launch | `overlay.quickLaunch`, `overlay.quickLaunch.input`, `overlay.quickLaunch.item.<agent>`, `overlay.quickLaunch.profile.<id>`, `overlay.quickLaunch.dataset.<id>`, `overlay.quickLaunch.resume`, `overlay.quickLaunch.openComputer`, `overlay.quickLaunch.agentSettings` |
| Palette | `overlay.palette`, `overlay.palette.input`, `overlay.palette.row.<kind>.<id>`, `overlay.palette.filter`, `overlay.palette.insertMode` |
| Inbox | `inbox`, `inbox.filter`, `inbox.markAllRead`, `inbox.empty`, `inbox.item.<eventId>[.markRead/.takeOver/.allow/.deny/.open]` (lote concluído: `eventId` = `batch.<batchId>`) |
| Painel direito | `rightPanel`, `rightPanel.tab.<name>`, `rightPanel.tabs.indicator`, `rightPanel.sourceControl.{branch,refresh,pr,createPR,openPR,copyURL,openInEditor,revealInFinder,retry,change.<path>}`, `rightPanel.checks.{row.<name>,refresh,retry,sendFailures}`, `rightPanel.computers.{new,empty,thumb.<computerId>,thumb.<computerId>.takeOver}`, `rightPanel.conversations.{search,scope,empty,warning,back,transcript,row.<id>,row.<id>.resume}`, `rightPanel.context.item.<kind>.<id>[.toggle/.insert]`, `rightPanel.context.{banner,restart,openLibrary,empty}`, `rightPanel.computer.<id>.tab.<name>`, `rightPanel.computer.<id>.{back,reveal,openRun,summary,integrity}`, `rightPanel.computer.<id>.field.<pointer>`, `rightPanel.computer.<id>.evidence.<ref>` |
| Painel direito (contêiner e módulos, 10-right-panel) | `rightPanel.module.<id>[.header/.minimize]`, `rightPanel.divider`, `rightPanel.insights.empty`, `rightPanel.insights.showExactLimits`, `tabs.filesToggle`, `tabs.insightsToggle`, `tabs.dataToggle`, `tabs.computersToggle`, `rightPanel.computers.pick`, `rightPanel.computers.stats`, `rightPanel.computers.proxies`, `rightPanel.computers.changeExit`, `rightPanel.computers.openTraffic`, `rightPanel.computers.request.<id>`, `rightPanel.computers.filter.<filter>`, `traffic.page`, `traffic.close`, `traffic.search`, `traffic.filter.<filter>`, `traffic.host.<host>`, `traffic.row.<id>`, `traffic.detail`, `traffic.copyCurl`, `traffic.mode.<mode>`, `traffic.requestTab.<tab>`, `traffic.responseTab.<tab>`, `traffic.detailSide.<side>`, `traffic.noise`, `traffic.activity.row.<id>`, `rightPanel.data`, `rightPanel.data.empty`, `rightPanel.data.open`, `rightPanel.data.beside`, `rightPanel.data.pick`, `rightPanel.data.stats`, `rightPanel.data.row.<key>` |
| Painel direito (Files, 10-right-panel §2) | `rightPanel.files`, `rightPanel.files.chip`, `rightPanel.files.root`, `rightPanel.files.sessionFolder`, `rightPanel.files.showIgnored`, `rightPanel.files.refresh`, `rightPanel.files.tree`, `rightPanel.files.empty`, `rightPanel.files.row.<path>`, `rightPanel.files.viewer[.back/.name/.find/.findField/.findCount/.findNext/.findPrevious/.findClose/.openIn/.copyPath/.code/.empty]` |
| Viewer | `viewer.<computerId>`, `.back`, `.name`, `.mode`, `.url`, `.controlPill`, `.controlFrame`, `.ghostCursor`, `.clickRipple`, `.takeOver`, `.handBack[.note/.confirm]`, `.forceTakeOver`, `.helpBanner[.decline]`, `.connecting`, `.status`, `.disconnected`, `.popOut`, `.more`, `.strip[.thumb.<otherId>]`, `.keyboardBadge`, `.exit[.handBack/.keep]` |
| Páginas | `computers.page`, `computers.where`, `computers.where.local`, `computers.where.cloud`, `computers.where.change`, `computers.newSessions`, `computers.cloud.provider.<providerId>`, `computers.cloud.region.<regionId>`, `computers.cloud.dailyCap`, `computers.cloud.monthlyCap`, `computers.cloud.maxComputers`, `computers.cloud.connect`, `computers.cloud.save`, `computers.cloud.edit`, `computers.cloud.cancel`, `computers.cloud.summary`, `computers.cloud.status`, `computers.cloud.spend`, `computers.cloud.hosts`, `computers.cloud.host.<id>`, `computers.cloud.host.<id>.stop`, `computers.cloud.record.<id>`, `computers.cloud.link.<kind>`, `computers.newBatch`, `computers.cleanUp` (v1.1), `computers.dockerBanner`, `computers.empty`, `computers.row.<id>`, `computers.queue.row.<id>.cancel`; `batch.<batchId>.page`, `batch.<batchId>.row.<childId>`, `batch.<batchId>.collectAll`, `batch.<batchId>.archive`, `batch.<batchId>.{summary,empty,results,filter.<name>,export.csv,export.json}`; `computers.row.<id>.{result,runFolder}`, `computers.leftovers`, `computers.leftovers.showAll`, `computers.leftovers.cleanAll`, `computers.leftovers.row.<key>`, `computers.leftovers.row.<key>.{keep,delete}`; `datasets.page`, `datasets.empty`, `datasets.row.<id>`, `dataset.page`, `dataset.filter`, `dataset.search`, `dataset.export`, `dataset.export.<format>`, `dataset.notebook`, `notebook.page`, `notebook.dataset.<id>`, `notebook.apply`, `notebook.openBeside`, `notebook.close`, `notebook.status`, `notebook.web`, `dataset.table`, `dataset.empty`, `dataset.loadMore`, `dataset.row.<key>`, `dataset.provenance`, `dataset.provenance.{source,computer,run,request,trust,seen,error}`, `dataset.stats`, `dataset.chart`, `dataset.range`, `dataset.columns`, `dataset.facet.<facet>.<value>`, `dataset.filter.add`, `dataset.pill.<index>`, `dataset.pill.<index>.remove`, `dataset.column.<name>`, `dataset.column.<name>.value.<value>`, `dataset.column.<name>.range`, `dataset.chart.window`, `dataset.chart.window.clear`, `dataset.facet.<facet>.<value>.only`, `dataset.facet.<facet>.reset`, `dataset.facets.reset`, `dataset.chip.<id>.clear`, `dataset.search.clear`, `dataset.status`, `dataset.page.prev`, `dataset.page.next`, `dataset.copyRow`, `dataset.panel.tab.<tab>`; `data.page`, `data.demo`, `data.tabs.menu`, `data.rename.button`, `data.beside`, `data.ownTab`, `data.backToSession`, `data.openInSession`, `data.table.page.prev`, `data.table.page.next`, `data.moreColumns`, `data.rename.field`, `data.path`, `data.explorer`, `data.explorer.toggle`, `data.explorer.resize`, `data.explorer.node.<id>`, `data.explorer.section.<section>`, `data.addConnection`, `data.tab.<key>`, `data.tab.<key>.close`, `data.location`, `data.location.crumb.<index>`, `data.flow`, `data.flow.item.<id>`, `data.object`, `data.sendTo`, `data.table.tab.<tab>`, `data.panel.collapse`, `data.table.grid`, `data.query.editor`, `data.query.run`, `data.query.target`, `data.query.result`, `data.query.error`, `data.table.error`, `data.folder.entry.<name>`, `data.folder.preview`, `data.webhook.log`, `data.webhook.test`, `data.connect.sheet`, `data.connect.kind.<kind>`, `data.connect.form`, `data.connect.name`, `data.connect.url`, `data.connect.auth`, `data.connect.user`, `data.connect.secret`, `data.connect.save`, `data.connect.error`, `data.connect.s3mode`, `data.connect.region`, `data.connect.accessKey`, `data.connect.sessionToken`, `data.connect.profile`, `data.connect.bucket`, `data.s3.page.prev`, `data.s3.page.next`, `data.s3.error`, `data.s3.preview`, `data.runs`, `data.runs.filter`, `data.runs.row.<id>`, `data.runs.error`, `data.connection.remove`, `data.connection.remove.confirm`, `data.connection.remove.cancel`, `data.empty`, `data.production`, `data.production.pause`, `data.writer.<id>.pause`, `data.writer.<id>.open`, `data.webhook.payload`; `library.page`, `library.section`, `library.search`, `library.source`, `library.new`, `library.empty`, `library.row.<kind>.<id>`, `library.detail.{newSession,enable,insert,openInEditor,reveal,restart}`, `library.profile.{name,agent,model,permissions,args,env,default}`, `library.profile.row.<id>`, `library.profile.edit` |
| Settings | `settings.page`, `settings.back`, `settings.search`, `settings.nav.<section>`, `settings.<section>.<key>`, `settings.computers.proxies.row.<proxyId>`, `settings.computers.proxies.add`, `settings.computers.proxies.test` |
| Onboarding | `onboarding`, `onboarding.step.<name>`, `onboarding.item.<key>`, `onboarding.done`, `onboarding.skip` |
| Dialogs | `overlay.confirmClose[.dontAsk/.cancel/.confirm]`, `overlay.confirmArchive[.cancel/.confirm]`, `overlay.confirmArchiveBatch[.cancel/.confirm]`, `overlay.confirmStopComputer[.cancel/.confirm]`, `overlay.confirmRestartAgents[.cancel/.confirm]`, `overlay.confirmDeleteComputer.confirm`, `overlay.confirmDelete[.keepBranch/.trashFolder/.deleteRuns/.dontAsk/.changes/.cancel/.confirm]`, `overlay.confirmRemoveProject[.cancel/.confirm]`, `overlay.resume[.row.<id>/.confirm/.cancel/.selectAll/.selectNone]`, `overlay.moveToProject[.project/.cancel/.confirm]`, `overlay.addProject.{choose,clone,clone.url,clone.submit}`, `overlay.cloneRepo[.input/.list/.row.<id>/.progress/.logIn/.error/.retry/.cancel/.submit]`, `overlay.createPR[.title/.base/.body/.draft/.preview/.error/.retry/.compare/.cancel/.submit]`, `overlay.confirmQuit[.keepRunning/.stopAll/.stopAllConfirm/.cancel/.dontAsk]`, `overlay.confirmSkipPermissions.confirm`, `overlay.renameBranch[.name/.submit]`, `overlay.about[.licenses/.copy]`, `overlay.newBatch[.targets/.importCSV/.brief/.display/.proxy/.allowedProxies/.session/.submit/.cancel/.count]`, `overlay.newBatch.allowedProxies.<proxy>`, `popover.paste[.text/.confirm]` |
| Landing | `landing`, `landing.addProject`, `landing.cloneProject`, `landing.newCleanSession`, `landing.newSession`, `landing.agent.<provider>`, `landing.recent.<sessionId>`, `landing.computers`, `landing.data` |
| Menu bar | `menuBar.icon`, `menuBar.item.<sessionId>`, `menuBar.open`, `menuBar.newSession`, `menuBar.newCleanSession`, `menuBar.stopAll`, `menuBar.quitCompletely` |
| Menus do app | `menu.<group>.<actionId>` (actionId de §24) |
| Toasts | `toast.<kind>`, `toast.<kind>.action` |

---

## 23. (removido)

O checklist visual antigo saiu: a identidade do Racky é própria.

## 24. Tabela de ações

Toda interação da UI é uma ação do registro (`ActionRegistry`: `ActionID` → handler, `isEnabled`, motivo). Menus, botões, context menus, palette e `ctl ui action` disparam a mesma ação. Regras:
- O `ActionID` é `<grupo>.<ação>` em lowerCamelCase e dá o sufixo do ID do item de menu (`menu.<grupo>.<ação>`).
- Cada `ActionID` tem um XCUITest com clique ou atalho real que confere o efeito declarado (estado, navegação ou erro específico; "erro visível" genérico não conta), e o teste de cobertura cruza esta tabela com os testes (AC-T02).
- "Desabilitado" traz o tooltip exato do motivo. Ação de versão futura não aparece (não é desabilitada).
- A coluna **Atalho** repete o atalho canônico de §21 (`—` = sem atalho; `⌥` = item extra do menu com ⌥ pressionado, convenção de §21). A coluna **Teste (XCUITest)** dá o nome do teste: `testAction_<ActionID>` em `RackyUITests/Actions/`, que dispara a ação por atalho real quando há atalho e por clique quando não há (AC-T02 cruza esta coluna com os testes que existem). Em linhas com mais de um ActionID há um teste por ID.
- Atalhos: §21. Microcopy de cada overlay: seções citadas.
- Fatia 1 (09 §3): o painel direito é oculto, então `view.toggleRightPanel` (⌘L), `tab.quickLaunchResume` e `sidebar.search` são da Fatia 2 e **não existem** na UI da Fatia 1.
- Controles de Settings (§24.6): a Fatia 1 (09 T1-26) fixou as chaves de General, Agents e Terminal e cada uma tem linha em §24.6; as chaves das seções de fatias futuras entram com a fatia delas.

### 24.1 App e janela

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| About Racky | `app.about` | — | Overlay §16.14 | — | v1 | `testAction_app_about` |
| Settings… | `app.settings` | ⌘, | Abre Settings na última seção | — | v1 | `testAction_app_settings` |
| Set Up Racky… / Run Diagnostics | `app.setup` | — | Abre o onboarding (§15); `Run Diagnostics` abre Settings › Diagnostics e roda as checagens | — | v1 | `testAction_app_setup` |
| Check for Problems | `app.checkProblems` | — | Abre Settings › Diagnostics e roda `Run All Checks Again` | — | v1 | `testAction_app_checkProblems` |
| Hide App Name | `app.hideAppName` | — | Esconde o nome na faixa da titlebar; volta em Settings › Appearance | — | v1 | `testAction_app_hideAppName` |
| Quit Racky | `app.quit` | ⌘Q | §16.10 | — | v1 | `testAction_app_quit` |
| Quit Racky Completely | `app.quitCompletely` | — | Encerra o app e o ícone; agentes seguem no background service | — | v1 | `testAction_app_quitCompletely` |
| Open Racky (barra de menus) | `app.openMainWindow` | — | Sai do modo accessory e traz a janela principal (T1-24) | — | v1 | `testAction_app_openMainWindow` |
| Stop All Agents… (barra de menus) | `app.stopAllAgents` | — | Abre a janela com a confirmação `Stop <n> agents?` (§16.10, segunda confirmação) | Sem agentes vivos: `No agents are running.` | v1 | `testAction_app_stopAllAgents` |
| Toggle Sidebar / Right Panel | `view.toggleSidebar` / `view.toggleRightPanel` | ⌘B / ⌘L (Fatia 2) | Recolhe/expande (M-201 / M-108) | Right Panel com página aberta: `Close the page first.` | v1 (Toggle Sidebar: Fatia 1; Toggle Right Panel: Fatia 2, o painel direito é oculto na Fatia 1 e o controle não existe) | `testAction_view_toggleSidebar` · `testAction_view_toggleRightPanel` |
| Show Status Bar | `view.toggleStatusBar` | — | Mostra/esconde a status bar (também `Hide Status Bar` no menu dela) | — | v1 | `testAction_view_toggleStatusBar` |
| Status bar: abrir / mostrar-esconder segmento | `statusBar.openSegment` / `statusBar.toggleSegment` | — | `select(claude/codex/computers/proxyUsage/docker)`: abre o popover do segmento (§5) / liga ou desliga o segmento (checkbox do menu de contexto da barra) | Segmento sem dados: `Nothing to show yet.` | v1 (Fatia 4) | `testAction_statusBar_openSegment` · `testAction_statusBar_toggleSegment` |
| Back / Forward | `nav.back` / `nav.forward` | ⌥⌘← / ⌥⌘→ | Navega no histórico (§0) | `No earlier page` / `No later page` | v1 | `testAction_nav_back` · `testAction_nav_forward` |
| Bigger / Smaller / Actual Size | `terminal.fontBigger` / `.fontSmaller` / `.fontReset` | ⌘= / ⌘- / ⌘0 | Fonte do pane focado | Sem terminal focado: `Interface zoom isn't available yet.` | v1 | `testAction_terminal_fontBigger` · `testAction_terminal_fontSmaller` · `testAction_terminal_fontReset` |
| Hide from Sidebar | `sidebar.hideNavItem` | — | Esconde o item de nav | — | v1 | `testAction_sidebar_hideNavItem` |
| Racky Help | `help.open` | — | Abre no navegador a página de ajuda empacotada (`Help/index.html`: atalhos, modelo de segurança, links) | — | v1 | `testAction_help_open` |
| Keyboard Shortcuts | `help.shortcuts` | ⌘/ | Settings › Shortcuts | — | v1 | `testAction_help_shortcuts` |
| Reveal Logs in Finder | `help.revealLogs` | — | Mostra a pasta de logs | — | v1 | `testAction_help_revealLogs` |
| Export Diagnostics… | `help.exportDiagnostics` | — | Lista de arquivos e salva o .zip redigido (AR-603) | — | v1 | `testAction_help_exportDiagnostics` |
| Open Diagnostics | `app.openDiagnostics` | — | Settings › Diagnostics, na linha que motivou (deep link) | — | v1 | `testAction_app_openDiagnostics` |
| Save Diagnostics / Cancel Export / Dismiss Crash | `diagnostics.saveExport` / `diagnostics.cancelExport` / `diagnostics.dismissCrash` | — | Depois de `Export Diagnostics…` mostrar a lista de arquivos: grava o .zip redigido em `diagnostics/` e o mostra no Finder / descarta o preparo / esconde a linha `Recent crash` (T4-04) | `Save Diagnostics`: sem lista preparada: `Export Diagnostics first.` | v1 | `testAction_diagnostics_saveExport` · `testAction_diagnostics_cancelExport` · `testAction_diagnostics_dismissCrash` |
| Restart Background Service | `app.restartBackgroundService` | — | Confirma `Running terminals will reconnect.`; reinicia o serviço e reanexa | — | v1 | `testAction_app_restartBackgroundService` |
| Try Again / Copy Details (região com erro) | `app.errorTryAgain` / `app.copyDetails` | — | Remonta a região / copia erro, região e versão | — | v1 | `testAction_app_errorTryAgain` · `testAction_app_copyDetails` |
| Reveal Corrupt File | `app.revealCorruptFile` | — | Mostra o arquivo corrompido no Finder | — | v1 | `testAction_app_revealCorruptFile` |

### 24.2 Sidebar, projetos e sessões

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| New Session… | `session.new` | ⌘N | Composer (§6) com o projeto atual | — | v1 | `testAction_session_new` |
| New Clean Session | `session.newClean` | ⇧⌘N | Cria `~/Racky/sessions/<nome>` e abre o agente padrão (§2.10); também o `+` da seção Sessions | Agente padrão não instalado: `Install <agent> or choose another default agent.` | v1 | `testAction_session_newClean` |
| New Clean Session in Folder… | `session.newCleanInFolder` | ⌥⇧⌘N | `NSOpenPanel` → sessão na pasta escolhida + agente padrão | idem | v1 | `testAction_session_newCleanInFolder` |
| Add Project… | `project.add` | — | Overlay §16.9 | — | v1 | `testAction_project_add` |
| Subagent computers (card, header do pane) | `session.setSubagentComputers` | — | `select(off/ask/full)` na sessão selecionada, ou `select(<sessionId>:<modo>)`: liga ou desliga os computadores dos subagentes (F12). Sessão rodando: aparece `Restart to apply` | Só Claude Code: `Subagent computers works with Claude Code.` | v1 (Fatia 3) | `testAction_session_setSubagentComputers` |
| Subagents run as (card, header do pane) | `session.setSubagentHarness` | — | `select(<sessionId>:<claude|codex|opencode|mixed>)`: quem roda os próximos subagentes da sessão; vale no próximo `agent_spawn`, sem reiniciar | Sessão desconhecida: `No such session.` | v1 (Fatia 3) | `testAction_session_setSubagentHarness` |
| Collapse / Expand Subagents (chevron da linha do agente) | `agent.toggleChildren` | — | `select(<terminalId>)`: recolhe ou expande as linhas dos subagentes do agente (em memória) | — | v1 (Fatia 3) | `testAction_agent_toggleChildren` |
| Restart to apply | `session.restartToApply` | — | Relança o Claude da sessão com Resume e o novo modo de "Subagent computers" | Nada a aplicar: `Already applied.` | v1 (Fatia 3) | `testAction_session_restartToApply` |
| Clone from GitHub… | `project.cloneFromGitHub` | — | Overlay §16.9b; item do combobox Project do composer e do Add Project; ao concluir seleciona o projeto clonado | — | v1 | `testAction_project_cloneFromGitHub` |
| Sort and Filter / Reset | `sidebar.sortFilter` / `sidebar.resetFilters` | — | Popover §2.4 / volta ao padrão | — | v1 | `testAction_sidebar_sortFilter` · `testAction_sidebar_resetFilters` |
| Clear Search / Clear Filters | `sidebar.clearSearch` / `sidebar.clearFilters` | — | Limpa a busca / `Show` | — | v1 (a busca é da Fatia 2; `Show` na Fatia 1) | `testAction_sidebar_clearSearch` · `testAction_sidebar_clearFilters` |
| Show <n> more | `project.showMore` | — | Mostra todas as sessões do projeto | — | v1 | `testAction_project_showMore` |
| New Session in <project>… / from Branch or PR… | `project.newSession` / `project.newSessionFromRef` | — | Composer com o projeto; o segundo com foco em `Create from` | — | v1 | `testAction_project_newSession` · `testAction_project_newSessionFromRef` |
| Open in Editor | `item.openInEditor` | ⇧⌘O | Abre a pasta (sessão ou projeto) no editor de Settings › General | Nenhum editor configurado: `Choose an editor in Settings › General.` | v1 | `testAction_item_openInEditor` |
| Reveal in Finder / Copy Path | `item.revealInFinder` / `item.copyPath` | — | Finder / copia o caminho real | Pasta sumiu: `Folder not found` | v1 | `testAction_item_revealInFinder` · `testAction_item_copyPath` |
| Open on GitHub | `item.openOnGitHub` | — | Abre o repo (projeto) ou a branch (sessão) no navegador | Sem remote GitHub: não aparece | v1 | `testAction_item_openOnGitHub` |
| Copy Branch Name | `session.copyBranch` | — | Copia a branch | Sessão sem Git: não aparece | v1 | `testAction_session_copyBranch` |
| Collapse All Sessions | `project.collapseAll` | — | Recolhe as linhas de agente de todos os cards do projeto | — | v1 | `testAction_project_collapseAll` |
| Hide Project | `project.hide` | — | Some da sidebar; volta por `Show › Hidden Projects` | — | v1 | `testAction_project_hide` |
| Rename Project… | `project.rename` | — | Edita o nome do projeto inline na linha (↵ confirma, Esc cancela; vazio volta ao nome da pasta). Não renomeia a pasta | — | v1 | `testAction_project_rename` |
| Remove Project… | `project.remove` | — | §16.6 | — | v1 | `testAction_project_remove` |
| Refresh Git (⌥) | `item.refreshGit` | ⌥ | Refaz status, branch e PR do item | Sem Git: não aparece | v1 | `testAction_item_refreshGit` |
| Copy Project/Session ID (⌥) | `item.copyId` | ⌥ | Copia o ID | — | v1 | `testAction_item_copyId` |
| Show Launch Details (⌥) | `terminal.showLaunchDetails` | ⌥ | Popover com argv, cwd, env (nomes, sem valores) e perfil do último lançamento | Sem lançamento: `Not started yet` | v1 | `testAction_terminal_showLaunchDetails` |
| Rename… | `session.rename` | ⌥⌘R | Inline (§2.11) | — | v1 | `testAction_session_rename` |
| Rename Branch… (⌥) | `session.renameBranch` | ⌥ | §16.13 | Branch com upstream: `This branch is already pushed.` | v1 | `testAction_session_renameBranch` |
| Edit Note… | `session.editNote` | — | Inline na linha 3 | — | v1 (Fatia 2) | `testAction_session_editNote` |
| Mark as Read / Unread | `session.markRead` / `session.markUnread` | — | Alterna o não lido | — | v1 | `testAction_session_markRead` · `testAction_session_markUnread` |
| Mute / Unmute Notifications | `session.mute` / `session.unmute` | — | Para de gerar notificações do sistema e badge para a sessão (a Inbox continua recebendo); ícone `BellOff` 10 após o nome | — | v1 (Fatia 2) | `testAction_session_mute` · `testAction_session_unmute` |
| Pin / Unpin Session | `session.pin` | — | Fixa no topo do projeto | — | v1.1 | `testAction_session_pin` |
| Resume Agents… | `session.resumeAgents` | — | §16.7 | Sem terminais interrompidos: não aparece | v1 | `testAction_session_resumeAgents` |
| Move to Project… / Convert to Project… | `session.moveToProject` / `session.convertToProject` | — | §16.8 | Só sessão limpa (não aparece nas outras) | v1 | `testAction_session_moveToProject` · `testAction_session_convertToProject` |
| Move Folder into Project… | `session.moveFolderIntoProject` | — | §16.8 | Terminais rodando: `Stop all terminals in this session first` | v1.1 | `testAction_session_moveFolderIntoProject` |
| Archive Session… | `session.archive` | — | §16.2 | — | v1 | `testAction_session_archive` |
| Delete Session… | `session.delete` | ⇧⌘⌫ | §16.5 | — | v1 | `testAction_session_delete` |
| Restore Session | `session.restore` | — | Desarquiva a sessão (aparece em `Show › Archived Sessions`, no lugar de `Archive Session…`); os terminais voltam como `Interrupted`/`Exited`, sem processo rodando | Sessão não arquivada: não aparece | v1 | `testAction_session_restore` |
| Undo (toast `Session archived.`) | `session.undoArchive` | — | Desfaz o arquivamento da sessão do argumento `select(<sessionId>)` (8 s) | Sessão apagada: `Session not found` | v1 | `testAction_session_undoArchive` |
| Undo (toast `Session deleted.`) | `session.undoDelete` | — | Restaura só o registro da sessão apagada (argumento `select(<sessionId>)`, 8 s); não volta pasta nem branch. Não é oferecido ao apagar worktree nem ao mover a pasta para o Lixo | — | v1 | `testAction_session_undoDelete` |
| Open in… | `item.openIn` | — | Menu com `Finder`, os terminais instalados (`Terminal`, `iTerm`, `Ghostty`, `Warp`) e os editores instalados (`Cursor`, `Visual Studio Code`, `Zed`, `Xcode`, `Sublime Text`, detectados por bundle id); o item escolhido abre a pasta da sessão ou do projeto. Argumento `select(<id>)` | Pasta sumiu: `Folder not found` | v1 | `testAction_item_openIn` |
| Open in <app> (item do menu `Open in…`) | `item.openInTarget` | — | Abre a pasta pelo `NSWorkspace` no destino do argumento `select(<id>/<finder, terminal:<bundleId> ou editor:<bundleId>>)`; lembra o último editor | App não instalado: `<app> isn't installed.` | v1 | `testAction_item_openInTarget` |
| Locate Folder… | `session.locateFolder` | — | `NSOpenPanel`; nova pasta passa a ser a da sessão (worktree: valida que é a mesma worktree do repositório) | — | v1 | `testAction_session_locateFolder` |
| Reveal Current Session | `sidebar.revealCurrent` | — | Rola até o card ativo (M-211) | Sem sessão: `No session selected` | v1 | `testAction_sidebar_revealCurrent` |
| Next Needing Attention | `session.nextNeedingAttention` | ⇧⌘A | Vai ao próximo AttentionItem por prioridade e espera | Nada pendente: `Nothing needs attention` | v1 (Fatia 2) | `testAction_session_nextNeedingAttention` |
| Previous / Next Session, Select Session 1–9, Focus Session List | `session.previous` / `.next` / `.select<n>` / `sidebar.focus` | ⇧⌘↑ / ⇧⌘↓ / ⌘1…⌘9 / ⇧⌘0 | Navegação | — | v1 | `testAction_session_previous` · `testAction_session_next` · `testAction_session_selectN` · `testAction_sidebar_focus` |
| Select Session (clique no card) | `session.select` | — | Seleciona a sessão do argumento `select(<sessionId>)` e mostra as tabs dela (mesma regra de `session.select<n>`) | Sessão inexistente: `Session not found` | v1 | `testAction_session_select` |
| Expand / Collapse Agent Rows (pílula-resumo, → / ← no card) | `session.toggleAgents` | → / ← | Expande ou recolhe as linhas de agente do card (M-206); argumento `select(<sessionId>)`; o estado persiste | — | v1 | `testAction_session_toggleAgents` |
| Ask Parent to Relaunch | `child.askParentToRelaunch` | — | Popover §16.12 e cola no prompt do pai sem Enter | Pai não está vivo: `The parent agent isn't running.` | v1 | `testAction_child_askParentToRelaunch` |
| Show Transcript / Show Computer / Copy Agent ID | `child.showTranscript` / `child.showComputer` / `child.copyId` | — | Painel Conversations no transcript / abre o viewer / copia | Sem computador: `Show Computer` não aparece | v1 | `testAction_child_showTranscript` · `testAction_child_showComputer` · `testAction_child_copyId` |
| Message… | `child.message` | — | Popover de mensagem ao filho | — | v1.1 | `testAction_child_message` |
| Stop Subagent | `child.stop` | — | Para o filho pelo adapter | Adapter sem a capacidade: não aparece | v1 | `testAction_child_stop` |
| Search (campo da sidebar) | `sidebar.search` | ⌘F (sidebar focada) | Foca o campo (§2.2); digitar filtra; Esc limpa e sai. A busca **não** está na Fatia 1 (01 §4.1, 09 T1-13) | — | v1 (Fatia 2) | `testAction_sidebar_search` |
| Expand / Collapse Project (clique na linha) | `sidebar.project.toggle` | → / ← | Expande ou recolhe as sessões do projeto (M-806); lembra o estado | — | v1 | `testAction_sidebar_project_toggle` |
| Cancel (linha pendente, PhaseList e ignição) | `session.cancelLaunch` | — | Aborta a criação (fetch, worktree ou início do agente), remove a linha pendente e não deixa pasta nem branch criadas por esta tentativa (§2.9, §4.6, §6.4) | Já concluído: `Session already created` | v1 | `testAction_session_cancelLaunch` |
| Try Again (criação da sessão) | `session.retryLaunch` | — | Repete a criação com os mesmos dados do composer (§6.4) | — | v1 | `testAction_session_retryLaunch` |
| Resume All (agentes parados com o app fechado) | `session.resumeStopped` | — | Relança com `--resume <id>` todos os agentes mortos da sessão, escalonados; some o banner (P25) | Sem agente parado: indisponível | v1 | `testAction_session_resumeStopped` |
| Use Existing Branch | `session.useExistingBranch` | — | Reaproveita a branch que já existe em vez de criar (§6.4) | Sem conflito de branch: não aparece | v1 | `testAction_session_useExistingBranch` |
| Create Without Fetching | `session.createWithoutFetch` | — | Cria a worktree a partir da base local sem `git fetch` (§6.4) | Fetch não falhou: não aparece | v1 | `testAction_session_createWithoutFetch` |
| Discard (sessão que falhou ao criar) | `session.discardPending` | — | Remove a linha pendente com erro e não cria a sessão (§6.4) | — | v1 | `testAction_session_discardPending` |
| Launch Session (automação) | `session.launch` | — | Cria uma sessão limpa com o agente já rodando (P9): linha pendente, chip M-501, tab em ignição. Argumento `set(<json>)` com `provider`, `prompt`, `model`, `name`, `cwd`, `args`, `origin`; devolve os IDs. Mesmo caminho do composer (T1-20); existe para `ctl` e testes | JSON inválido: `expected set(<json>)` | v1 | `testAction_session_launch` |

### 24.3 Tabs, panes e terminal

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| New Tab… (Quick Launch) | `tab.quickLaunch` | ⌥⌘N | §7 | Sem sessão: `Select a session first.` | v1 | `testAction_tab_quickLaunch` |
| New Agent Tab | `tab.newAgent` | ⌥⌘T | Tab com o agente e perfil padrão | idem | v1 | `testAction_tab_newAgent` |
| New Terminal | `tab.newTerminal` | ⌘T | Tab com shell na pasta da sessão | idem | v1 | `testAction_tab_newTerminal` |
| New <Agent> Tab (Quick Launch, New Tab ▸) | `tab.newWithAgent` | — | Tab com o agente escolhido | Não instalado: `Not installed` | v1 | `testAction_tab_newWithAgent` |
| Start <agent> with "<text>" | `tab.newWithPrompt` | — | Tab com o texto como prompt inicial (argumento) | — | v1 | `testAction_tab_newWithPrompt` |
| Close Pane / Close Tab | `pane.close` / `tab.close` | ⌘W / ⌘W (1 pane) | Fecha (§16.1 se rodando) | — | v1 | `testAction_pane_close` · `testAction_tab_close` |
| Close Other Tabs / Tabs to the Right | `tab.closeOthers` / `tab.closeRight` | — | Fecha as outras / à direita (confirmação agrupada) | Sem outras: `No other tabs` | v1 | `testAction_tab_closeOthers` · `testAction_tab_closeRight` |
| Reopen Closed Tab | `tab.reopen` | ⇧⌘T | Relança a última fechada (com `--resume` se houver ID) | Nada fechado: `No closed tabs` | v1 | `testAction_tab_reopen` |
| Close Window | `window.close` | ⇧⌘W | Fecha a janela (o app continua) | — | v1 | `testAction_window_close` |
| Next / Previous / Recent Tab, Select Tab 1–9 | `tab.next` / `.previous` / `.recent` / `.select<n>` | ⇧⌘] / ⇧⌘[ / ⌃⇥ / ⌃1…⌃9 | Troca a tab ativa | — | v1 | `testAction_tab_next` · `testAction_tab_previous` · `testAction_tab_recent` · `testAction_tab_selectN` |
| Rename… / Reset Title | `tab.rename` / `tab.resetTitle` | ⌘R | Inline / volta ao título dinâmico (OSC ou nome do agente) | Reset sem rename: `Title isn't customized` | v1 | `testAction_tab_rename` · `testAction_tab_resetTitle` |
| Split Right / Down | `pane.splitRight` / `pane.splitDown` | ⌘D / ⇧⌘D | Novo pane com o mesmo agente e perfil (⌥: shell) | Sem espaço: toast §4.3 | v1 | `testAction_pane_splitRight` · `testAction_pane_splitDown` |
| Next / Previous Pane | `pane.next` / `pane.previous` | ⌘] / ⌘[ | Move o foco | Um só pane: `Only one pane` | v1 | `testAction_pane_next` · `testAction_pane_previous` |
| Expand / Collapse Pane | `pane.toggleExpand` | ⇧⌘↵ | §4.3; também a pílula `N hidden panes` (`pane.<id>.zoomPill`) | Um só pane: `Only one pane` | v1 | `testAction_pane_toggleExpand` |
| Equalize Pane Sizes | `pane.equalize` | — | Divide o espaço igualmente na árvore da tab; também duplo clique no divisor (§4.3) | Um só pane: `Only one pane` | v1 | `testAction_pane_equalize` |
| Close Other Panes | `pane.closeOthers` | — | Fecha os outros panes da tab (confirmação agrupada) | Um só pane: `Only one pane` | v1 | `testAction_pane_closeOthers` |
| Show Pane | `pane.show` | — | Seleciona a tab e foca o pane (rim flash) | — | v1 | `testAction_pane_show` |
| Restart / Restart with ▸ | `terminal.restart` / `terminal.restartWithProfile` | — | Relança no mesmo cwd (com o perfil escolhido; sem resume) | Processo vivo: `Restart` pede §16.1 antes | v1 | `testAction_terminal_restart` · `testAction_terminal_restartWithProfile` |
| Resume Conversation | `terminal.resume` | — | Relança com `--resume <id>` e flags regeneradas | Sem ID: `No conversation ID for this terminal` | v1 | `testAction_terminal_resume` |
| Start Fresh | `terminal.startFresh` | — | Relança o agente sem resume | — | v1 | `testAction_terminal_startFresh` |
| Copy Resume Command | `terminal.copyResumeCommand` | — | Copia o comando de resume | Sem ID: idem | v1 | `testAction_terminal_copyResumeCommand` |
| Copy Terminal / Conversation / Pane ID (⌥) | `terminal.copyId` / `.copyConversationId` / `pane.copyId` | ⌥ | Copia | Sem conversa: `No conversation ID` | v1 | `testAction_terminal_copyId` · `testAction_terminal_copyConversationId` · `testAction_pane_copyId` |
| Show Hook Log (⌥) | `terminal.showHookLog` | ⌥ | Popover com os últimos 50 eventos de hook do terminal (hora, evento, estado resultante) | Sem hooks: `No hook events yet` | v1 (Fatia 2) | `testAction_terminal_showHookLog` |
| Send Interrupt (⌃C) | `terminal.sendInterrupt` | ⌃C | Envia SIGINT ao grupo em primeiro plano | Processo saiu: `Process isn't running` | v1 | `testAction_terminal_sendInterrupt` |
| Send Text / Screen (automação, sem UI) | `terminal.sendText` / `terminal.screen` | — / — | `ctl ui action terminal.sendText set '{"terminal":"<id>","text":"..."}'` escreve no PTY (origem `ctl`; `\n` é Enter); `terminal.screen select <id>` devolve o texto da tela do emulador do daemon (AR-806 `terminal send/screen`) | Sem terminal: `Terminal not found` | v1 | `testAction_terminal_sendText` · `testAction_terminal_screen` |
| Force Quit Process… / Force Quit | `terminal.forceQuit` | — | Confirma `Force quit "<process>"?` e envia SIGKILL ao grupo | idem | v1 | `testAction_terminal_forceQuit` |
| Find… / Next / Previous / Close | `find.open` / `.next` / `.previous` / `.close` | ⌘F / ⌘G / ↵ / ⇧⌘G / ⇧↵ / Esc | §4.4 (⌘F roteado, §21) | — | v1 | `testAction_find_open` · `testAction_find_next` · `testAction_find_previous` · `testAction_find_close` |
| Clear Terminal | `terminal.clear` | ⌘K | Limpa a tela e o scrollback visível (`ED 3`) | — | v1 | `testAction_terminal_clear` |
| Copy / Paste / Select All | `edit.copy` / `.paste` / `.selectAll` | ⌘C / ⌘V / ⌘A | Clipboard do terminal (paste por bracketed paste) | Copy sem seleção: `Nothing selected` | v1 | `testAction_edit_copy` · `testAction_edit_paste` · `testAction_edit_selectAll` |
| Open Link / Copy Link / Open File | `terminal.openLink` / `.copyLink` / `.openFile` | ⌘-clique | Navegador / copia / editor de Settings | — | v1 | `testAction_terminal_openLink` · `testAction_terminal_copyLink` · `testAction_terminal_openFile` |
| Open Computer | `terminal.openComputer` | — | Abre o viewer do computador do agente | Sem computador: não aparece | v1 (Fatia 3) | `testAction_terminal_openComputer` |
| Open in another terminal | `terminal.openElsewhere` | — | Abre o app de terminal de Settings › General com o comando de resume na pasta | — | v1 | `testAction_terminal_openElsewhere` |
| Insert Skill or Agent… | `prompt.insertSkillOrAgent` | — | Palette em modo `/` (§8) | Sem pane de agente: `Focus an agent terminal first.` | v1 (Fatia 4) | `testAction_prompt_insertSkillOrAgent` |
| Insert in Prompt | `prompt.insertItem` | — | Cola a invocação no prompt do pane focado (sem Enter) | idem | v1 (Fatia 4) | `testAction_prompt_insertItem` |
| Quick Commands | `tab.quickCommands` | — | Split button com comandos salvos | — | v1.1 | `testAction_tab_quickCommands` |
| Pane Actions (menu ⋯ da tab row) | `tabs.paneActions` | — | Menu com `Split Right`, `Split Down`, `Equalize Pane Sizes`, `Expand Pane`, `Close Other Panes` (§3, cada item é a ação do próprio ActionID) | Só aparece com 2+ panes | v1 | `testAction_tabs_paneActions` |
| Reorder Tab (arrastar na tab row) | `tab.reorder` | — | Reordena a tab por arrasto (M-303, §3.4); a ordem persiste | — | v1 | `testAction_tab_reorder` |
| Drop Tab on Pane (arrastar tab para a área de panes) | `tab.dropOnPane` | — | Solta a tab sobre um pane: `set(<tabId>=<terminalId>@<left\|right\|top\|bottom\|center>)` cria o split do lado escolhido ou, no centro, troca de lugar (§3.4, M-306); persiste e não recria terminais | Sem espaço: toast §4.3 | v1 | `testAction_tab_dropOnPane` |
| Move Pane (arrastar o cabeçalho sobre outro pane) | `pane.move` | — | Move o pane com `set(<terminalId>=<targetTerminalId>@<zona>)`: split do lado ou troca de lugar no centro (§4.3) | Sem espaço: toast §4.3 | v1 | `testAction_pane_move` |
| Detach Pane to Tab (arrastar o cabeçalho para a tab row) | `pane.detach` | — | Transforma o pane em tab: `select(<terminalId>)` (ao fim da tab de origem) ou `set(<terminalId>=<índice>)` | Tab com um só pane: `Only one pane` | v1 | `testAction_pane_detach` |
| Resize Divider (arrastar o divisor) | `pane.resizeDivider` | — | Muda as proporções do split; no máximo 1 resize de PTY por quadro e o final ao soltar (§4.3, M-202) | Mínimo 240 × 120 pt por pane | v1 | `testAction_pane_resizeDivider` |
| Case Sensitive (busca no terminal) | `find.caseSensitive` | — | Alterna a busca com distinção de maiúsculas e refaz a contagem (§4.4) | — | v1 | `testAction_find_caseSensitive` |
| Regex (busca no terminal) | `find.regex` | — | Alterna a busca por expressão regular; regex inválida mostra `Invalid pattern` no contador (§4.4) | — | v1 | `testAction_find_regex` |
| Search field e contador (busca no terminal) | `find.query` | — | Digitar busca com destaque no buffer; contador `3/17` ou `No results` (`find.field`, `find.count`, §4.4) | — | v1 | `testAction_find_query` |
| Try Again (agente não iniciou) | `terminal.retryStart` | — | Relança o agente no mesmo pane (estado `Couldn't start`, §4.6) | — | v1 | `testAction_terminal_retryStart` |
| Open Agent Settings | `agent.openSettings` | — | Abre Settings › Agents (do estado `Couldn't start`, do Quick Launch `Agent Settings…` e do rodapé `Manage Agents…` do composer) | — | v1 | `testAction_agent_openSettings` |
| Copy Details (agente não iniciou) | `terminal.copyStartError` | — | Copia o erro, o argv sem segredos e a versão (§4.6) | — | v1 | `testAction_terminal_copyStartError` |
| Cancel (fechando, `The process didn't exit.`) | `terminal.cancelClose` | — | Mantém o terminal aberto e dispensa o banner de fechamento (§4.6) | — | v1 | `testAction_terminal_cancelClose` |
| Resume a Conversation… (Quick Launch) | `tab.quickLaunchResume` | — | Abre o painel direito em Conversations, escopo Session (§7, §10.5) | Fatia 1: não aparece (painel direito oculto) | v1 (Fatia 2) | `testAction_tab_quickLaunchResume` |

### 24.4 Painéis, páginas e notificações

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Source Control / Checks / Computers Panel / Conversations / Context | `panel.sourceControl` / `.checks` / `.computers` / `.conversations` / `.context` | ⇧⌘G / ⇧⌘C / ⇧⌘H | Abre o painel na aba | — | v1 (Checks e Source Control: Fatia 2; Computers: Fatia 3) | `testAction_panel_sourceControl` · `testAction_panel_checks` · `testAction_panel_computers` · `testAction_panel_conversations` · `testAction_panel_context` |
| Refresh (Source Control, Checks) | `panel.refresh` | — | Refaz a consulta Git/`gh` | Rodando: `Refreshing…` | v1 | `testAction_panel_refresh` |
| Create Pull Request… | `git.createPR` | — | Overlay pequeno de §10.2 e `gh pr create` | Sem push: `Push the branch first.` | v1 (Fatia 2) | `testAction_git_createPR` |
| Open on GitHub / Copy URL (PR) | `git.openPR` / `git.copyPRURL` | — | Navegador / copia | — | v1 | `testAction_git_openPR` · `testAction_git_copyPRURL` |
| Abrir arquivo alterado (Source Control, §10.2) | `git.openChange` | — | `select(<caminho>)`: abre o arquivo no editor configurado | Arquivo removido: `This file was deleted.` | v1 (Fatia 2) | `testAction_git_openChange` |
| Abrir check (Checks, §10.3) | `git.openCheck` | — | `select(<nome>)`: abre a página do check no navegador | Sem link: `This check has no page.` | v1 (Fatia 2) | `testAction_git_openCheck` |
| Log In (gh, Claude, Codex) | `account.logIn` | — | Tab com o comando de login do CLI | — | v1 | `testAction_account_logIn` |
| Send Failures to Claude Code | `checks.sendFailures` | — | Popover §16.12 | — | v1.1 | `testAction_checks_sendFailures` |
| Resume in New Tab / in Split, Show Transcript | `conversation.resume` / `.resumeSplit` / `.showTranscript` | — | §10.5 | Ativa noutro terminal: aviso `Open in another terminal` antes | v1 | `testAction_conversation_resume` · `testAction_conversation_resumeSplit` · `testAction_conversation_showTranscript` |
| Menu da conversa / Copy Resume Command / Copy Conversation ID | `conversation.menu` / `conversation.copyResumeCommand` / `conversation.copyId` | — | §10.5 | — | v1 | `testAction_conversation_menu` · `testAction_conversation_copyResumeCommand` · `testAction_conversation_copyId` |
| Escopo / Busca / Voltar do transcript | `conversation.setScope` / `conversation.setQuery` / `conversation.back` | — | §10.5 | — | v1 | `testAction_conversation_setScope` · `testAction_conversation_setQuery` · `testAction_conversation_back` |
| Restart Agents with Resume | `context.restartWithResume` | — | §10.6 | Sem agentes com ID: `No agents can resume` | v1 | `testAction_context_restartWithResume` |
| Toggle item in this session | `context.toggleItem` | — | Ativação aditiva por sessão | Global: não tem switch | v1 (Fatia 4) | `testAction_context_toggleItem` |
| Open Library / Library | `page.library` | ⇧⌘L | Página §13 | — | v1 (Fatia 4) | `testAction_page_library` |
| Computers (página) | `page.computers` | — | Página §12.3 | — | v1 (Fatia 3) | `testAction_page_computers` |
| Datasets (página) | `page.datasets` | — | Página §12.5 | — | v1 (Fatia 3) | `testAction_page_datasets` |
| Open Dataset | `dataset.open` | — | `select(<datasetId>)`: abre a tabela viva do dataset | Desconhecido: `No such dataset.` | v1 (Fatia 3) | `testAction_dataset_open` |
| Dataset: filtro / busca / linha / Load more | `dataset.filter` / `dataset.search` / `dataset.selectRow` / `dataset.loadMore` | — | `select(all\|invalid)` / `set(<texto>)` / `select(<rowKey>)` (sem argumento limpa) / mais 1.000 linhas | Sem dataset aberto: `Open a dataset first.` | v1 (Fatia 3) | `testAction_dataset_filter` · `testAction_dataset_search` · `testAction_dataset_selectRow` · `testAction_dataset_loadMore` |
| Export Dataset | `dataset.export` | — | `select(csv\|jsonl\|json)` abre o painel de salvar; `set(<formato>=<caminho>)` grava direto (só com a automação ligada). Só linhas válidas | Automação desligada: `Automation is off` | v1 (Fatia 3) | `testAction_dataset_export` |
| Open in Notebook | `dataset.notebook` | — | `select(<datasetId>)`: abre um notebook Jupyter numa tab da área Data com esse dataset carregado (pandas) | Sem `uv`: `Install uv to open notebooks.` | v1.1 | `testAction_dataset_notebook` |
| Notebook: dataset | `notebook.toggleDataset` | — | `select(<notebookId>\|<datasetId>)` liga/desliga um dataset na lista à esquerda do notebook | Desconhecido: `No such notebook.` | v1.1 | `testAction_notebook_toggleDataset` |
| Notebook: soltar dataset | `notebook.addDataset` | — | `select(<notebookId>\|<datasetId>)` põe no notebook o dataset arrastado da coluna Data (já marcado; sem efeito se já estava) | Desconhecido: `No such notebook.` / `No such dataset.` | v1.1 | `testAction_notebook_addDataset` |
| Notebook: carregar | `notebook.apply` | — | `select(<notebookId>)`: exporta os datasets marcados e acrescenta uma célula que carrega cada novo | Desconhecido: `No such notebook.` | v1.1 | `testAction_notebook_apply` |
| Notebook: ao lado do agente | `notebook.openBeside` | — | `select(<notebookId>)`: leva o notebook aberto na área Data para a sessão atual, num pane ao lado do agente (a tab de Data fecha). O botão `Notebook` de um dataset aberto numa sessão (`dataset.notebook` com `select(<datasetId>\|session)`) já abre ali | Sem sessão aberta: `Open a session first.` | v1 | `testAction_notebook_openBeside` |
| Open Source URL | `dataset.openSource` | — | `select(<rowKey>)`: abre a URL de origem da linha no navegador | Sem URL: `This row has no source URL.` | v1 (Fatia 3) | `testAction_dataset_openSource` |
| Dataset: período | `dataset.range` | — | `select(15m\|1h\|6h\|24h\|7d\|all)`: só linhas que chegaram nesse período (gráfico, facetas e grade) | Sem dataset aberto: `Open a dataset first.` | v1 (Fatia 3) | `testAction_dataset_range` |
| Dataset: faceta | `dataset.facet` | — | `select(<faceta>:<valor>)` liga/desliga um valor (`status`, `computer`, `source`, `evidence`, `error`); `select(<faceta>:=<valor>)` deixa só esse valor (de novo volta a todos); `select(<faceta>:*)` volta a faceta ao normal | Faceta desconhecida: `expected select(<facet>:<value>)` | v1 (Fatia 3) | `testAction_dataset_facet` |
| Dataset: janela do gráfico | `dataset.timeWindow` | — | `select(<inícioMs>-<fimMs>)` limita linhas, facetas e perfis a essa janela (o gráfico mantém o período); `select(clear)` ou sem argumento volta ao normal; escolher um período em `dataset.range` também limpa | Argumento inválido: `expected select(<startMs>-<endMs>|clear)` | v1 (Fatia 3) | `testAction_dataset_timeWindow` |
| Dataset: adicionar filtro | `dataset.addFilter` | — | `select(<coluna>\|<op>\|<valor>)` acrescenta o token à busca (`op` = `=`, `!=`, `>`, `>=`, `<`, `<=`, `~`) | Argumento inválido: `expected select(<column>\|<op>\|<value>)` | v1 (Fatia 3) | `testAction_dataset_addFilter` |
| Dataset: remover filtro | `dataset.removeFilter` | — | `select(<índice>)` tira da busca o token do pill nessa posição | Índice inválido: `expected select(<index>)` | v1 (Fatia 3) | `testAction_dataset_removeFilter` |
| Dataset: faixa da coluna | `dataset.columnRange` | — | `select(<coluna>\|<min>\|<max>)` troca os filtros `>`/`<` da coluna por `>=min <=max` (lado vazio = aberto) | Argumento inválido: `expected select(<column>\|<min>\|<max>)` | v1 (Fatia 3) | `testAction_dataset_columnRange` |
| Dataset: limpar filtros | `dataset.facetsReset` | — | sem argumento: todas as facetas e tipos de erro voltam ao normal | Sem dataset aberto: `Open a dataset first.` | v1 (Fatia 3) | `testAction_dataset_facetsReset` |
| Data: abrir / fechar objeto | `data.open` / `data.close` | — | `select(<objeto>)` abre (ou foca) a tab: `dataset:<id>`, `table:<conexão>:<schema>:<nome>`, `query:<conexão>:<n>`, `folder:<conexão>:<a/b>`, `webhook:<conexão>`, `sheet:<conexão>:<planilha>:<aba>`; `close` fecha a tab | Objeto desconhecido: `No such object.` | v1 (Data, etapa 2) | `testAction_data_open` · `testAction_data_close` |
| Data: expandir nó / nova consulta | `data.toggleNode` / `data.newQuery` | — | `select(<id do nó>)` abre/fecha no explorer; `select(<conexão>)` abre um editor SQL nela | Conexão sem SQL: `This connection doesn't run SQL.` | v1 (Data, etapa 2) | `testAction_data_toggleNode` · `testAction_data_newQuery` |
| Data: sub-aba da tabela / rodar consulta | `data.tableTab` / `data.queryRun` | ⌘↩ (consulta) | `select(data\|structure\|writers)`; roda o SQL da tab ativa na conexão dela | Sem tabela/consulta ativa | v1 (Data, etapa 2) | `testAction_data_tableTab` · `testAction_data_queryRun` |
| Data: adicionar conexão / enviar para / testar webhook | `data.addConnection` / `data.sendTo` / `data.webhookTest` | — | abre a folha de tipos; abre o destino de um dataset; manda uma entrega de teste | — | v1 (Data, etapa 2) | `testAction_data_addConnection` · `testAction_data_sendTo` · `testAction_data_webhookTest` |
| Data: pausar quem grava | `data.pauseWriter` | — | `select(<id do writer>)` pausa um agente ou sync que grava no objeto ativo; `select(all)` pausa todos | — | v1 (Data, etapa 2) | `testAction_data_pauseWriter` |
| Data: mostrar/recolher o explorer | `data.toggleExplorer` | — | recolhe o explorer da área Data (a largura arrastada fica guardada) | — | v1 (Data, etapa 2) | `testAction_data_toggleExplorer` |
| Data: renomear dataset | `data.renameDataset` | — | `select(<id>\|<nome>)` troca o nome mostrado do dataset (os agentes seguem gravando no nome original); `select(<id>)` começa a edição no lugar; nome vazio volta ao original | — | v1 (Data, etapa 2) | `testAction_data_renameDataset` |
| Data: página da tabela | `data.tablePage` | — | `select(next\|prev)` vai para a página seguinte/anterior da grade da tabela ativa de uma conexão | Sem tabela ativa | v1 (Data, etapa 2) | `testAction_data_tablePage` |
| Data: conectar (começar) | `data.connectStart` | — | `select(<kind>)` abre o formulário do tipo (hoje: Prefect e Amazon S3); `select(close)` fecha | Tipo ainda não conectável | v1 (Data, etapa 3) | `testAction_data_connectStart` |
| Data: conectar (salvar) | `data.connectSave` | — | `set(<json>)` testa a conexão e, se responder, salva (a senha vai para o cofre) | Formulário aberto | v1 (Data, etapa 3) | `testAction_data_connectSave` |
| Data: remover conexão | `data.connectionRemove` | — | `select(<id>)` tira a conexão salva e apaga a senha dela do cofre | — | v1 (Data, etapa 3) | `testAction_data_connectionRemove` |
| Data: página da pasta S3 | `data.s3Page` | — | `select(next\|prev)` vai para a página seguinte (token de continuação do ListObjectsV2) ou anterior da pasta S3 ativa | Sem pasta S3 ativa | v1 (Data, etapa 3) | `testAction_data_s3Page` |
| Data: filtro dos flow runs | `data.runsFilter` | — | `select(running\|scheduled\|failed)` troca o que a tela de flow runs mostra e relê | Sem orquestrador aberto | v1 (Data, etapa 3) | `testAction_data_runsFilter` |
| Dataset: página | `dataset.page` | — | `select(next\|prev\|first)` | Sem dataset aberto: `Open a dataset first.` | v1 (Fatia 3) | `testAction_dataset_page` |
| Dataset: colunas | `dataset.columns` | — | `select(<coluna>)` mostra/esconde a coluna na grade | Coluna desconhecida: `No such column.` | v1 (Fatia 3) | `testAction_dataset_columns` |
| Copy Row JSON | `dataset.copyRow` | — | Copia a linha selecionada como JSON (`select(<rowKey>)` copia outra) | Sem linha: `Select a row first.` | v1 (Fatia 3) | `testAction_dataset_copyRow` |
| Dataset: aba do painel | `dataset.panelTab` | — | `select(attributes\|source\|history)` | Sem dataset aberto: `Open a dataset first.` | v1 (Fatia 3) | `testAction_dataset_panelTab` |
| Sessions | `page.sessions` | ⇧⌘I | Volta para as sessões: fecha a página do centro e mostra a lista (com "Needs You" no topo quando há pedidos) | — | v1 (Fatia 2) | `testAction_page_sessions` |
| Inbox (legado) | `page.inbox` | — | Feed §9.1 (sem item na sidebar; o item virou Sessions) | — | v1 (Fatia 2) | `testAction_page_inbox` |
| Close page | `page.close` | Esc | Volta à sessão | — | v1 | `testAction_page_close` |
| Mark as Read / Mark All as Read | `inbox.markRead` / `inbox.markAllRead` | — | Marca lido | Nada não lido: `Nothing unread` | v1 | `testAction_inbox_markRead` · `testAction_inbox_markAllRead` |
| Inbox: filtro | `inbox.filter` | — | `select(all/needsYou/unread)`: filtra o feed (§9.1) | — | v1 (Fatia 2) | `testAction_inbox_filter` |
| Allow Notifications | `notifications.request` | — | Pede a permissão de notificações ao sistema (só por este clique; Settings › Notifications e onboarding) | Já concedida: `Notifications are on.` | v1 (Fatia 2) | `testAction_notifications_request` |
| Open System Settings | `app.openSystemSettings` | — | `select(notifications)`: abre System Settings › Notifications | — | v1 (Fatia 2) | `testAction_app_openSystemSettings` |
| Open (notificação) | `notification.open` | — | Ativa o app e seleciona sessão/pane/viewer com rim flash | — | v1 | `testAction_notification_open` |
| Send Test Notification | `settings.testNotification` | — | Envia uma notificação de exemplo | Permissão negada: `Notifications are off for Racky.` | v1 | `testAction_settings_testNotification` |
| Pause / Resume Notifications for 1 Hour | `notifications.pause` | — | Silencia notificações do sistema por 1 h | — | v1.1 | `testAction_notifications_pause` |
| Library: New Session with Agent / Profile | `library.newSessionWith` | — | Composer com agente (`--agent`) ou perfil | — | v1 (Fatia 4) | `testAction_library_newSessionWith` |
| Library: Enable / Disable in This Session | `library.toggleInSession` | — | Ativação aditiva, vale no próximo lançamento | Sem sessão: `Select a session first.` | v1 (Fatia 4) | `testAction_library_toggleInSession` |
| Library: Open in Editor / Reveal in Finder | `library.openInEditor` / `library.reveal` | — | Abre o arquivo | — | v1 | `testAction_library_openInEditor` · `testAction_library_reveal` |
| Library: seção / busca / fonte / item | `library.setSection` / `library.setSearch` / `library.setSource` / `library.selectItem` | — | `select(agents/skills/profiles)` (lembrado) / `set(<texto>)` / `select(all/<fonte>)` / `select(<id>)`: o detalhe abre ao lado da lista (§13.1) | — | v1 (Fatia 4) | `testAction_library_setSection` · `testAction_library_setSearch` · `testAction_library_setSource` · `testAction_library_selectItem` |
| Library: Edit Profiles… | `library.editProfiles` | — | Abre Settings › Agents, onde os perfis são editados (o formulário próprio de §13.4 entra depois) | — | v1 (Fatia 4) | `testAction_library_editProfiles` |
| Library: New Profile / Duplicate / Delete… | `profile.new` / `.duplicate` / `.delete` | — | Cria / copia / apaga perfil | Último perfil: `An agent needs at least one profile.` | v1 | `testAction_profile_new` · `testAction_profile_duplicate` · `testAction_profile_delete` |
| Library: New Agent… / Import Skill Folder… / Edit | `library.newAgent` / `.importSkill` / `.edit` | — | Criar e editar com backup | — | v1.1 | `testAction_library_newAgent` · `testAction_library_importSkill` · `testAction_library_edit` |
| Block in Racky / Disable Globally… / Keep / Restore Skill | `conflict.block` / `.disableGlobal` / `.keep` / `.restore` | — | Deny por lançamento / move a skill global para backup com confirmação / nada / desfaz | — | v1 | `testAction_conflict_block` · `testAction_conflict_disableGlobal` · `testAction_conflict_keep` · `testAction_conflict_restore` |

### 24.5 Computadores e lotes

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Open Viewer / Open in New Window | `computer.openViewer` / `.popOut` | — | Tab do viewer / janela própria | — | v1 (Fatia 3) | `testAction_computer_openViewer` · `testAction_computer_popOut` |
| Take Over / Hand Back / Force Take Over | `computer.takeOver` / `.handBack` / `.forceTakeOver` | ⇧⌘R | Controle humano (§11) | Computador parado: `This computer is stopped.` | v1 (Fatia 3) | `testAction_computer_takeOver` · `testAction_computer_handBack` · `testAction_computer_forceTakeOver` |
| Decline… (pedido de ajuda) | `computer.declineHelp` | — | Popover com motivo; o agente recebe `declined` | — | v1 (Fatia 3) | `testAction_computer_declineHelp` |
| Release Keyboard | `computer.releaseKeyboard` | ⌘⎋ / ⌃⌥ | Solta a captura | Sem captura: não age | v1 (Fatia 3) | `testAction_computer_releaseKeyboard` |
| Show Network / Journal / Files / Timeline / Result | `computer.showTab` | — | Detalhe no painel (§11.7); sem argumento volta à lista (`← Back`); `select(<computer>)` ou `select(<computer>:result)` abre a aba `Result` (a única entregue na T3-06; `select(<computer>:<outra>)` só funciona quando a aba existir) | Computador ou run desconhecido: `No run folder for this computer.` | v1 (Fatia 3) | `testAction_computer_showTab` |
| Open Run Folder / Reveal Result in Finder | `computer.openRunFolder` / `computer.revealResult` | — | `select(<computer>)`: abre `runs/<sessão>/<computador>/` no Finder (AC-420) / mostra `work/result.json` (ou `work/`) no Finder | Sem pasta de run: `No run folder for this computer.` | v1 (Fatia 3) | `testAction_computer_openRunFolder` · `testAction_computer_revealResult` |
| Open Evidence | `computer.openEvidence` | — | `select(<computer>\|<ref>)`: arquivo citado de `/work` abre no Finder; `request_id` mostra o corpo salvo (ou o `requests.jsonl`) no Finder | Citação sem alvo: `Cited request not found.` | v1 (Fatia 3) | `testAction_computer_openEvidence` |
| Change type (HTTP/Headless/Desktop) | `computer.setDisplay` | — | Troca o tipo (confirmação para HTTP) | — | v1 (Fatia 3) | `testAction_computer_setDisplay` |
| Proxy ▸ | `computer.setProxy` | — | Define o proxy do computador (07 CS-161). `select(<computer>)`: abre o menu `Direct` + proxies salvos, com o atual marcado (botão `Change` da saída na aba Computers); `select(<computer>\|<proxy>)`: troca na hora (o egress fecha os túneis abertos), anota no journal que foi o usuário e as requests seguintes saem pelo proxy novo | Nenhum proxy: só `Direct`; computador terminado: `This computer has finished.` | v1 (Fatia 3) | `testAction_computer_setProxy` |
| Paste to Computer / Copy Selection from Computer | `computer.paste` / `computer.copySelection` | — | §11.2 | Sem controle humano: `Take over first.` | v1 (Fatia 3) | `testAction_computer_paste` · `testAction_computer_copySelection` |
| Reconnect | `computer.reconnect` | — | Reabre o stream | — | v1 (Fatia 3) | `testAction_computer_reconnect` |
| Show Preview (hover card do subagente) | `computer.showPreview` | — | `select(<computer>)` abre o hover card do computador ao lado da linha do subagente (o mesmo do hover do ponteiro); `press` fecha | Sem computador: `No computers yet.` | v1 (Fatia 3) | `testAction_computer_showPreview` |
| Allow / Allow for this session / Deny (pedido de computador) | `computer.allowRequest` / `computer.allowRequestSession` / `computer.denyRequest` | — | `select(<requestId>)` (sem argumento: o pedido mais antigo): decide o card de aprovação do modo Ask (F12) | Sem pedido aberto: `No computer request is waiting.` | v1 (Fatia 3) | `testAction_computer_allowRequest` · `testAction_computer_allowRequestSession` · `testAction_computer_denyRequest` |
| Escolher o proxy do pedido de computador | `computer.requestProxy` | — | Sem argumento ou `select(<requestId>)`: abre o menu `Direct` + proxies de Settings › Computers › Proxies, com o atual marcado; `select(<requestId>\|<proxy>)`: aplica no pedido (vale no lugar do que o agente pediu) e vira o proxy padrão da sessão (F29) | Sem pedido aberto: `No computer request is waiting.` | v1 (Fatia 3) | `testAction_computer_requestProxy` |
| Escolher o que sai do computador | `computer.requestLeftovers` | — | Sem argumento ou `select(<requestId>)`: abre o menu `Keep files` / `Delete when done` / `Delete in 7 days` / `Delete in 30 days`, com o atual marcado (o padrão vem de Settings › General › Storage); `select(<requestId>\|<policy>)`: aplica no pedido e vira a escolha da sessão para os próximos computadores. Gravado no `box.json` do run | Sem pedido aberto: `No computer request is waiting.` | v1 (Fatia 3) | `testAction_computer_requestLeftovers` |
| Keep / Delete now (Left on disk) | `computer.keepLeftovers` / `computer.deleteLeftovers` | — | `select(<key>)` (caminho do run relativo a `computers/runs`): Keep tira o prazo do run; Delete now esvazia o `work/` (menos `result.json`) e mostra `Freed <tamanho>.` | Run desconhecido: `That run is gone.` | v1 (Fatia 3) | `testAction_computer_keepLeftovers` · `testAction_computer_deleteLeftovers` |
| Start Computer | `computer.start` | — | Sobe o computador parado | Docker parado: `Docker isn't running` | v1 (Fatia 3) | `testAction_computer_start` |
| Stop Computer… / Delete Computer… | `computer.stop` / `computer.delete` | — | §16.3 / §16.4 | — | v1 (Fatia 3) | `testAction_computer_stop` · `testAction_computer_delete` |
| New Computer… | `computer.new` | — | Cria computador ligado ao terminal focado | Sem terminal de agente: `Focus an agent terminal first.` | v1 (Fatia 3) | `testAction_computer_new` |
| Copy Computer ID / Open Shell (⌥) | `computer.copyId` / `computer.openShell` | ⌥ | Copia / tab de shell no container `work` | — | v1 (Fatia 3) | `testAction_computer_copyId` · `testAction_computer_openShell` |
| Cancel (fila, provisionando) | `computer.cancel` | — | Tira da fila ou cancela a criação | — | v1 (Fatia 3) | `testAction_computer_cancel` |
| Start Docker / Docker Settings | `docker.start` / `docker.settings` | — | Abre o runtime do contexto ativo / Settings › Docker | — | v1 (Fatia 3) | `testAction_docker_start` · `testAction_docker_settings` |
| Update / Build Locally / Download (imagem) | `image.update` / `.buildLocal` / `.download` | — | Baixa por digest / constrói / baixa em segundo plano | Rodando: rótulo de progresso | v1 (Fatia 3) | `testAction_image_update` · `testAction_image_buildLocal` · `testAction_image_download` |
| Clean Up… | `computers.cleanUp` | — | Assistente de limpeza | — | v1.1 | `testAction_computers_cleanUp` |
| Where computers run | `computers.runOn` | — | `select(local/cloud)`: onde os computadores novos sobem (BK-12, P27); os que já rodam não mudam | — | v1 (Fatia 4) | `testAction_computers_runOn` |
| Show where computers run | `computers.where.toggle` | — | Abre/fecha a escolha local/nuvem na página Computers quando já há computadores | — | v1 (Fatia 4) | `testAction_computers_where_toggle` |
| Cloud provider | `computers.cloud.provider` | — | `select(<providerId>)`: provedor da nuvem própria | Provedor ainda não suportado: `<Name> is coming soon.` | v1 (Fatia 4) | `testAction_computers_cloud_provider` |
| Cloud region | `computers.cloud.region` | — | `select(<regionId>)`: região dos hosts | — | v1 (Fatia 4) | `testAction_computers_cloud_region` |
| Cloud limits | `computers.cloud.limits` | — | `set(daily=<n>), set(monthly=<n>), set(max=<n>)` ou `select(daily+), select(max-)` etc.: tetos de gasto e de computadores | — | v1 (Fatia 4) | `testAction_computers_cloud_limits` |
| Connect cloud account | `computers.cloud.connect` | — | Liga a conta do provedor (AWS: `aws login` do perfil no navegador, confere a conta com `sts get-caller-identity`) | Sem o `aws` CLI: `The AWS command line tool isn't installed…`; esperando o navegador: desabilitado | v1 (Fatia 4) | `testAction_computers_cloud_connect` |
| Stop cloud host | `computers.cloud.stopHost` | — | `select(<hostId>)`: encerra a VM na nuvem agora (os computadores nela param) e fecha o registro de gasto | Host desconhecido: erro do provedor | v1 (Fatia 4) | `testAction_computers_cloud_stopHost` |
| Save cloud setup | `computers.cloud.save` | — | Confirma conta, região e limites: a partir daqui os computers rodam na nuvem (antes, seguem no Mac) | Sem conta conectada: `Connect your AWS account first.` | v1 (Fatia 4) | `testAction_computers_cloud_save` |
| Edit cloud setup | `computers.cloud.edit` | — | Reabre os passos da nuvem (o que já roda continua) | — | v1 (Fatia 4) | `testAction_computers_cloud_edit` |
| Cancel cloud setup | `computers.cloud.cancel` | — | Fecha os passos; se a nuvem nunca foi salva, volta para This Mac | — | v1 (Fatia 4) | `testAction_computers_cloud_cancel` |
| Delete all left on disk | `computer.cleanAllLeftovers` | — | Apaga já o `work/` de todo run terminado, menos os marcados Keep | — | v1 (Fatia 3) | `testAction_computer_cleanAllLeftovers` |
| Show all left on disk | `computers.leftovers.showAll` | — | Alterna entre os 4 maiores e a lista inteira | — | v1 (Fatia 3) | `testAction_computers_leftovers_showAll` |
| Open provider link | `computers.cloud.openLink` | — | `select(console/pricing/setup)`: abre o link do provedor no navegador | — | v1 (Fatia 4) | `testAction_computers_cloud_openLink` |
| New Batch… | `batch.new` | — | Overlay §16.15 | Sem terminal Claude disponível: `Install Claude Code first.` | v1 (Fatia 3) | `testAction_batch_new` |
| Open Batch / Filter / Export CSV / Export JSON | `batch.open` / `batch.filter` / `batch.exportCSV` / `batch.exportJSON` | — | `select(<batchId>)` abre o painel `Batch` (clique na notificação ou no item do Inbox) / `select(All\|Needs You\|Blocked\|Done)` / grava o consolidado (`set(<caminho>)` grava direto; sem argumento abre o painel de salvar) | Lote desconhecido: `No such batch.` | v1 (Fatia 3) | `testAction_batch_open` · `testAction_batch_filter` · `testAction_batch_exportCSV` · `testAction_batch_exportJSON` |
| Collect All / Archive Batch | `batch.collectAll` / `batch.archive` | — | `batch_collect` de todos / arquiva o lote e para os computadores | Filhos rodando (Archive): confirmação `Stop <n> running subagents?` | v1 (Fatia 3) | `testAction_batch_collectAll` · `testAction_batch_archive` |
| Add Proxy / Test Proxy / Delete… | `proxy.add` / `proxy.test` / `proxy.delete` | — | §14.2 Computers › Proxies | Proxy em uso (Delete): `Used by <n> computers.` | v1 (Fatia 3) | `testAction_proxy_add` · `testAction_proxy_test` · `testAction_proxy_delete` |
| Edit Proxy / Save Proxy / Cancel (proxy) | `proxy.edit` / `proxy.save` / `proxy.cancel` | — | Abre o formulário do proxy (`select(<proxyId>)`) / grava o formulário (valida nome, host e porta; a senha vai para o Vault) / descarta | Save: `Enter a name.` · `Enter a host.` · `Port must be 1–65535.` · nome já usado | v1 (Fatia 3) | `testAction_proxy_edit` · `testAction_proxy_save` · `testAction_proxy_cancel` |
| Preset / Type / Default proxy (proxy) | `proxy.preset` / `proxy.scheme` / `proxy.setDefault` | — | `select(custom\|zyte)` (preenche host e porta do preset) / `select(http\|https\|socks5)` / `select(<proxyId>\|none)` (padrão global, CS-161) | — | v1 (Fatia 3) | `testAction_proxy_preset` · `testAction_proxy_scheme` · `testAction_proxy_setDefault` |
| Import from racky CLI… | `proxy.importFromCLI` | — | Sem argumento arma a confirmação inline; `select(confirm)` lê SÓ `ZYTE_API_KEY` do `.env` do CLI antigo (somente leitura) e cria/atualiza o proxy `zyte` | `No Zyte key found in the racky CLI settings.` | v1 (Fatia 3) | `testAction_proxy_importFromCLI` |

### 24.6 Settings e onboarding

Cada controle de §14 é uma ação `settings.<section>.<key>` que grava o valor (regra de §14.1). Botões próprios: `Change…` (`settings.pickPath`), `Detect Again` / `Check Again` (`agent.detect`), `Edit Profiles…` (`library.profiles`), `Show Details` (`agent.hookDetails`), `Allow in Login Items` (`app.allowLoginItem`, abre System Settings › Login Items), `Open System Settings` (`app.openSystemSettings`), `Reset` "Don't ask again" (`settings.resetConfirmations`), `Reveal Keybindings File` (`settings.revealKeybindings`), `Back Up Now` (`db.backup`), `Export Database…` (`db.export`), `Restore from Backup…` (`db.restore`), `Reload Shell Environment` (`terminal.reloadEnv`), `Read` security model (`help.securityModel`), `Reset Racky…` (`app.reset`, confirmação digitando `reset`), `Add Credential` / `Import .env File…` / `Reveal` / `Edit` / `Delete…` (`credential.*`, Reveal pede Touch ID). Onboarding: `Log In` (`account.logIn`), `Install…` (`agent.installHelp`), `Start Docker`, `Download`, `Allow` (`notifications.request`), `Skip for Now` / `Done` (`onboarding.skip` / `onboarding.done`). Nenhum desses fica sem efeito: quando a pré-condição falta, o botão fica desabilitado com o motivo em uma linha.

Chaves da Fatia 1 (T1-26). Todas gravam pela regra de §14.1 (switch, segmented, combobox e stepper na hora; texto no ↵ ou blur; debounce de 300 ms no Store). `set(on/off)` liga e desliga; `select(<valor>)` escolhe; `set(<texto>)` grava texto. Controles de seções de fatias futuras não existem na UI da Fatia 1 (AC-T28).

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Seção do Settings (nav) | `settings.openSection` | — | `select(general/agents/terminal)`: troca a seção e a lembra | — | v1 | `testAction_settings_openSection` |
| Back to App | `settings.back` | Esc | Fecha o Settings e volta à página anterior | — | v1 | `testAction_settings_back` |
| Keep agents running when you quit | `settings.general.keepAgentsRunning` | — | `set(on/off)` | — | v1 | `testAction_settings_general_keepAgentsRunning` |
| Allow in Login Items | `settings.general.allowLoginItems` | — | Abre Ajustes do Sistema › Itens de Início (só por clique; só visível com `Background agents need approval`) | — | v1 | `testAction_settings_general_allowLoginItems` |
| Ask before quitting with running agents | `settings.general.askBeforeQuit` | — | `set(on/off)` | — | v1 | `testAction_settings_general_askBeforeQuit` |
| Resume agents automatically when Racky opens | `settings.general.resumeAgentsOnOpen` | — | `set(on/off)` (padrão ligado, P25) | — | v1 | `testAction_settings_general_resumeAgentsOnOpen` |
| Confirm before closing a running terminal | `settings.general.confirmCloseTerminal` | — | `set(on/off)` | — | v1 | `testAction_settings_general_confirmCloseTerminal` |
| Confirm before deleting a session | `settings.general.confirmDeleteSession` | — | `set(on/off)` | — | v1 | `testAction_settings_general_confirmDeleteSession` |
| Branch prefix | `settings.general.branchPrefix` / `settings.general.branchPrefixCustom` | — | `select(gitUser/custom/none)` / `set(<texto>)` | Custom: só com `Custom` escolhido | v1 | `testAction_settings_general_branchPrefix` · `testAction_settings_general_branchPrefixCustom` |
| Worktree folder / Clean session folder / Projects folder | `settings.general.worktreeFolder` / `settings.general.cleanSessionFolder` / `settings.general.projectsFolder` | — | `set(<caminho>)`; caminho relativo ou vazio é inválido e não grava | — | v1 | `testAction_settings_general_worktreeFolder` · `testAction_settings_general_cleanSessionFolder` · `testAction_settings_general_projectsFolder` |
| Change… | `settings.pickPath` | — | `select(worktreeFolder/cleanSessionFolder/projectsFolder)`: `NSOpenPanel` de pasta | — | v1 | `testAction_settings_pickPath` |
| Reset | `settings.resetConfirmations` | — | Religa as três confirmações; toast `Confirmations restored.` | — | v1 | `testAction_settings_resetConfirmations` |
| Space used › Clean up now | `settings.general.storageCleanUp` | — | Apaga já o `work/` de todo computador terminado que não está marcado Keep (runs de antes da escolha entram; `result.json` fica) e, com `Worktrees of archived sessions` em Delete, o checkout das sessões arquivadas sem mudanças e com tudo publicado (a branch fica); toast `Freed <tamanho>.` ou `Nothing to clean up.` | Enquanto mede: `Measuring…` | v1 | `testAction_settings_general_storageCleanUp` |
| What computers leave behind | `settings.general.computerLeftovers` | — | `select(keep/whenDone/days7/days30)` (padrão days7): quando o `work/` de um computador terminado (clone, downloads, scripts) sai do disco, contado do fim do run; é o padrão do botão no card de aprovação e o que todo computador recebe no modo Full. Logs, transcript, `result.json` e datasets ficam. Um nome reaproveitado arquiva o run anterior em `_archive/` com a escolha dele | — | v1 | `testAction_settings_general_computerLeftovers` |
| Choose on the approval card | `settings.general.leftoversOnCard` | — | `set(on/off)` (padrão on): o card `wants a computer` mostra o botão da escolha ao lado do proxy; off, o padrão vale sem botão | — | v1 | `testAction_settings_general_leftoversOnCard` |
| Worktrees of archived sessions | `settings.general.archivedWorktrees` | — | `select(keep/delete)` (padrão keep): delete tira o checkout do disco ao arquivar, só sem mudanças, sem commits por publicar e com upstream conhecido; a branch e o registro ficam e `Restore Session` faz o checkout de novo na mesma pasta | — | v1 | `testAction_settings_general_archivedWorktrees` |
| Old computer images | `settings.general.oldComputerImages` | — | `select(keep/delete)` (padrão delete): com a imagem Docker nova do computador pronta, as tags `racky-computer:ctx-*` anteriores saem (sem force: imagem em uso fica). O runtime nativo já apaga os templates antigos | — | v1 | `testAction_settings_general_oldComputerImages` |
| Subagent computers (padrão das novas sessões) | `settings.computers.defaultSubagentMode` | — | `select(off/ask/full)`: padrão de "Subagent computers" das sessões novas; as existentes não mudam | — | v1 (Fatia 3) | `testAction_settings_computers_defaultSubagentMode` |
| Subagents run as (padrão das novas sessões) | `settings.computers.defaultSubagentHarness` | — | `select(claude/codex/opencode/mixed)`: padrão de "Subagents run as" das sessões novas | — | v1 (Fatia 3) | `testAction_settings_computers_defaultSubagentHarness` |
| Use Docker instead (runtime dos computadores) | `settings.computers.forceDocker` | — | `set(on/off)`: no macOS 26+ os computadores rodam em VMs do próprio app (runtime nativo, sem Docker); ligado, usam o Docker. Vale para os próximos computadores; os que já rodam não mudam | Mac sem o runtime nativo (macOS < 26, Intel ou build sem o entitlement): desabilitada, o Docker já é o runtime | v1 | `testAction_settings_computers_forceDocker` |
| Git from computers (GitHub) | `settings.computers.githubAccess` | — | `set(on/off)`: ligado, os computadores de uma sessão clonam o repositório do projeto dela, fazem push só em `feat/*` e abrem PR por dentro, pelo gateway do egress (`github_gateway.py`), com o token do `gh` do dono, que nunca entra no computador. Vale para os próximos computadores | Desligado (padrão) ou projeto sem remote no GitHub: o gateway responde 403 `GitHub access is off for this computer` | v1 | `testAction_settings_computers_githubAccess` |
| Default agent | `settings.agents.defaultAgent` | — | `select(claude/codex/opencode/shell)` | — | v1 | `testAction_settings_agents_defaultAgent` |
| Default profile | `settings.agents.defaultProfile` | — | `select(<provider>:<profileId>)`: perfil global padrão do agente | — | v1 | `testAction_settings_agents_defaultProfile` |
| New Profile | `settings.agents.profileNew` | — | `select(<provider>)`: cria um perfil seu, sem pular permissões, e abre a edição | — | v1 | `testAction_settings_agents_profileNew` |
| Duplicate | `settings.agents.profileDuplicate` | — | `select(<profileId>)`: copia o perfil (nome `<nome> copy`) e abre a edição | — | v1 | `testAction_settings_agents_profileDuplicate` |
| Edit | `settings.agents.profileEdit` | — | `select(<profileId>)`: abre ou fecha a edição do perfil | Perfil pronto: `Built-in profiles can't be edited. Duplicate it to change flags.` | v1 | `testAction_settings_agents_profileEdit` |
| Delete | `settings.agents.profileDelete` | — | `select(<profileId>)`: apaga o perfil seu; o padrão do agente volta ao perfil pronto | Perfil pronto: `Built-in profiles can't be deleted.` | v1 | `testAction_settings_agents_profileDelete` |
| Profile name / Permissions / Model / Extra flags | `settings.agents.profileName` / `settings.agents.profilePermission` / `settings.agents.profileModel` / `settings.agents.profileArgs` | — | Editam o perfil aberto: `set(<texto>)`, `select(<modo>)`, `set(<modelo>)`, `set(<flags>)`; flag fora da lista do agente é inválida e não grava | — | v1 | `testAction_settings_agents_profileName` · `testAction_settings_agents_profilePermission` · `testAction_settings_agents_profileModel` · `testAction_settings_agents_profileArgs` |
| Font | `settings.terminal.font` | — | `select(<família>)` | — | v1 | `testAction_settings_terminal_font` |
| Size | `settings.terminal.size` | — | `select(inc/dec)` ou `set(<8…32>)` | Limite (`Minimum size is 8.` / `Maximum size is 32.`) | v1 | `testAction_settings_terminal_size` |
| Theme | `settings.terminal.theme` | — | `select(<tema>)`; a v1 traz só a paleta do dono (DS §3) | — | v1 | `testAction_settings_terminal_theme` |
| Cursor | `settings.terminal.cursor` / `settings.terminal.cursorBlink` | — | `select(block/bar/underline)` / `set(on/off)` | — | v1 | `testAction_settings_terminal_cursor` · `testAction_settings_terminal_cursorBlink` |
| Agent needs input | `settings.notifications.needsInput` | — | `set(on/off)`: Notificação quando um agente entra em `needsInput` | — | v1 (Fatia 2) | `testAction_settings_notifications_needsInput` |
| Agent finished | `settings.notifications.finished` | — | `set(on/off)`: Notificação quando um turno termina | — | v1 (Fatia 2) | `testAction_settings_notifications_finished` |
| Agent failed | `settings.notifications.failed` | — | `set(on/off)`: Notificação quando um agente falha | — | v1 (Fatia 2) | `testAction_settings_notifications_failed` |
| Terminal bell | `settings.notifications.terminalBell` | — | `set(on/off)`: Notificação para BEL em terminal fora de vista (desligado por padrão) | — | v1 (Fatia 2) | `testAction_settings_notifications_terminalBell` |
| Suppress when the session is visible | `settings.notifications.suppressWhenVisible` | — | `set(on/off)`: Sem notificação com a janela key e o pane visível | — | v1 (Fatia 2) | `testAction_settings_notifications_suppressWhenVisible` |
| Dock badge | `settings.notifications.dockBadge` | — | `set(on/off)`: Número de itens de atenção (prioridade 1–2) no ícone do Dock | — | v1 (Fatia 2) | `testAction_settings_notifications_dockBadge` |
| Notification sound | `settings.notifications.sound` | — | `select(system/none)` | — | v1 (Fatia 2) | `testAction_settings_notifications_sound` |
| Detect Again / Check Again | `agent.detect` | — | Refaz a detecção de instalação, versão e login (somente leitura, nunca roda `login`); `select(<provider>)` ou todos | — | v1 | `testAction_agent_detect` |
| Install… | `agent.installHelp` | — | `select(<provider>)`: abre a página de instalação no navegador | — | v1 | `testAction_agent_installHelp` |
| Try Again | `onboarding.retry` | — | `select(<gh/docker/image/conflicts>)`: refaz só a sonda daquele item, ignorando o cache | — | v1 | `testAction_onboarding_retry` |
| Copy Command | `onboarding.copyCommand` | — | `select(<gh/docker/image/conflicts>)`: copia o comando de correção do item (ex.: `brew install gh`, `gh auth login`) | Item sem comando: `Nothing to copy.` | v1 | `testAction_onboarding_copyCommand` |
| Keep Setting Up / Skip (confirmação do onboarding) | `onboarding.keepSettingUp` / `onboarding.confirmSkip` | — | Fecha a confirmação inline / fecha o onboarding sem perder o já feito | — | v1 | `testAction_onboarding_keepSettingUp` · `testAction_onboarding_confirmSkip` |
| Skip for Now / Done | `onboarding.skip` / `onboarding.done` | — | Abre `Skip setup?` inline / fecha o onboarding e o marca como visto | — | v1 | `testAction_onboarding_skip` · `testAction_onboarding_done` |

### 24.7 Command palette e Quick Launch

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Jump To… (abrir a palette) | `palette.open` | ⌘J | Abre a palette (§8, M-104) | — | v1 | `testAction_palette_open` |
| Open Row | `palette.openRow` | ↵ | Abre a sessão, terminal, computador, projeto ou comando selecionado | Sem linha selecionada | v1 | `testAction_palette_openRow` |
| Open in Split | `palette.openInSplit` | ⇧↵ | Abre o terminal selecionado em split à direita (palette e Quick Launch) | Item que não é terminal nem agente: `Not available for this item` | v1 | `testAction_palette_openInSplit` |
| New Session "<text>" / Start with prompt | `palette.newSessionWithText` | ⌘↵ | Palette: abre o composer com o texto como prompt. Quick Launch: lança o item selecionado com o texto como prompt (T11) | Texto vazio: `Type a prompt first` | v1 | `testAction_palette_newSessionWithText` |
| Cycle filter | `palette.cycleFilter` | ⇥ | Alterna `All · Sessions · Terminals · Computers · Commands` | — | v1 | `testAction_palette_cycleFilter` |
| Insert mode (`/`) | `palette.insertMode` | `/` no início do campo | Põe a palette em modo `Insert Skill or Agent` (§8) | Sem pane de agente: `Focus an agent terminal first.` | v1 (Fatia 4) | `testAction_palette_insertMode` |

### 24.8 Composer de nova sessão (§6)

Uma linha por controle de §6.1, §6.2 e §6.3. IDs de acessibilidade (`overlay.composer.*`) em §6 e §22.

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Project (combobox) | `composer.setProject` | — | Escolhe o projeto, `No Project (Clean Session)` ou `Add a New Project…` (esta abre §16.9 e volta ao composer) | — | v1 | `testAction_composer_setProject` |
| Where (segmented) | `composer.setWhere` | — | `New Worktree`, `Existing Worktree`, `Main Checkout` (com projeto); `New Folder`, `Choose Folder…` (sem projeto) | — | v1 | `testAction_composer_setWhere` |
| Create from (campo, base e chip `Branch exists`) | `composer.setBase` | — | Aceita branch, `#123` ou URL de PR/issue; o seletor `origin/main ⌄` troca a base; o chip avisa que a branch existe | — | v1 | `testAction_composer_setBase` |
| Reuse existing branch (chip e link `Reuse it`) | `composer.reuseBranch` | — | Troca para reaproveitar a branch que já existe | Sem conflito de branch: não aparece | v1 | `testAction_composer_reuseBranch` |
| Worktree (combobox, Existing Worktree) | `composer.setWorktree` | — | Escolhe uma worktree do projeto; em uso mostra aviso `Used by <session>` | — | v1 | `testAction_composer_setWorktree` |
| Folder `[Choose…]` | `composer.chooseFolder` | — | `NSOpenPanel` escuro; guarda o caminho (§6.1 3c) | — | v1 | `testAction_composer_chooseFolder` |
| Agent (combobox) | `composer.setAgent` | — | Escolhe o agente; o perfil é refiltrado | Agente não instalado: `Not installed` | v1 | `testAction_composer_setAgent` |
| Set as Default (agente) | `composer.setDefaultAgent` | — | Torna o agente escolhido o padrão de Settings › Agents | Já é o padrão: `Already the default` | v1 | `testAction_composer_setDefaultAgent` |
| Manage Agents… (rodapé do combobox de agente) | `composer.manageAgents` | — | Abre Settings › Agents (como `agent.openSettings`, §24.3) | — | v1 | `testAction_composer_manageAgents` |
| Profile (combobox) | `composer.setProfile` | — | Escolhe o perfil do agente; flags aparecem em mono | — | v1 | `testAction_composer_setProfile` |
| Edit Profiles… (rodapé do combobox de perfil) | `composer.editProfiles` | — | Abre Library › Profiles (como `library.profiles`, §24.6) | — | v1 | `testAction_composer_editProfiles` |
| Subagent computers (segmented) | `composer.setSubagentComputers` | — | `select(off/ask/full)`: modo da sessão nova (padrão de Settings › Computers); só com Claude Code | Outro agente: `Subagent computers works with Claude Code.` | v1 (Fatia 3) | `testAction_composer_setSubagentComputers` |
| Subagents run as (segmented) | `composer.setSubagentHarness` | — | `select(claude/codex/opencode/mixed)`: quem roda os subagentes da sessão nova (padrão de Settings › Computers) | — | v1 (Fatia 3) | `testAction_composer_setSubagentHarness` |
| Save data to | `composer.setDataDestination` | — | `select(racky)` ou `select(<objeto da área Data>)`: onde os agentes da sessão nova gravam o que coletam (spec data-hub) | — | v1 (Data, etapa 2) | `testAction_composer_setDataDestination` |
| Prompt | `composer.setPrompt` | — | Edita o prompt inicial, que vai como argumento do CLI; acima de 16 KiB vira arquivo referenciado | — | v1 | `testAction_composer_setPrompt` |
| Advanced (disclosure) | `composer.toggleAdvanced` | — | Abre ou fecha as opções avançadas; o estado é lembrado | — | v1 | `testAction_composer_toggleAdvanced` |
| Session name | `composer.setSessionName` | — | Edita o nome (placeholder com o nome automático) | — | v1 | `testAction_composer_setSessionName` |
| Branch name | `composer.setBranchName` | — | Edita a branch da nova worktree | Só com `New Worktree`: campo ausente nos outros modos | v1 | `testAction_composer_setBranchName` |
| Worktree location `[Change…]` | `composer.changeLocation` | — | `NSOpenPanel` para a raiz das worktrees deste projeto | Só com `New Worktree` | v1 | `testAction_composer_changeLocation` |
| Create More (switch) | `composer.createMore` | — | Mantém o overlay aberto e limpa o prompt depois de criar | — | v1 | `testAction_composer_createMore` |
| Create Session | `composer.submit` | ⌘↵ (de qualquer campo) | Valida, fecha o overlay e cria a sessão (§6.4) | Sem projeto ou pasta: `Choose a project or folder first.` | v1 | `testAction_composer_submit` |
| Cancel | `composer.cancel` | Esc | Fecha o composer. Com prompt digitado, Esc pede `Discard this session?` | — | v1 | `testAction_composer_cancel` |
| Keep Editing / Discard (confirmação inline) | `composer.keepEditing` / `composer.discard` | — | `Keep Editing` volta ao composer; `Discard` fecha e descarta o rascunho | — | v1 | `testAction_composer_keepEditing` · `testAction_composer_discard` |

### 24.9 Diálogos de confirmação (§16)

Cada botão e checkbox dos diálogos de §16 é uma ação. `Cancel` (Esc) existe em todos e tem o ActionID `dialog.<nome>.cancel`; `Confirm` é o botão primário. IDs de acessibilidade dos overlays: `overlay.confirm*` em §16.

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Close Terminal (confirma §16.1, inclui `Close <n> terminals?`) | `dialog.closeTerminal.confirm` | — | Fecha o terminal (ou os <n> terminais listados): SIGHUP/SIGTERM no grupo; sem sair em 5 s, `The process didn't exit.` com `Force Quit` | — | v1 | `testAction_dialog_closeTerminal_confirm` |
| Cancel (§16.1) | `dialog.closeTerminal.cancel` | Esc | Fecha o overlay e mantém o terminal | — | v1 | `testAction_dialog_closeTerminal_cancel` |
| Don't ask again (§16.1) | `dialog.closeTerminal.dontAsk` | — | Desliga `Confirm before closing a running terminal` | — | v1 | `testAction_dialog_closeTerminal_dontAsk` |
| Archive (§16.2) | `dialog.archive.confirm` | — | Arquiva a sessão; toast `Session archived.` com `Undo` | — | v1 | `testAction_dialog_archive_confirm` |
| Cancel (§16.2) | `dialog.archive.cancel` | Esc | Fecha o overlay | — | v1 | `testAction_dialog_archive_cancel` |
| Archive Batch / Cancel (confirmação com filhos rodando: `Stop <n> running subagents?`) | `dialog.archiveBatch.confirm` / `dialog.archiveBatch.cancel` | Esc | Remove os computadores do lote (runs, resultados e perfis ficam) / fecha o overlay | — | v1 (Fatia 3) | `testAction_dialog_archiveBatch_confirm` · `testAction_dialog_archiveBatch_cancel` |
| Stop Computer / Cancel (§16.3) | `dialog.stopComputer.confirm` / `dialog.stopComputer.cancel` | — / Esc | Para o computador (`computer.stop`) / fecha o overlay | — | v1 (Fatia 3) | `testAction_dialog_stopComputer_confirm` · `testAction_dialog_stopComputer_cancel` |
| Restart Agents / Cancel (aba Context, §10.6) | `dialog.restartAgents.confirm` / `dialog.restartAgents.cancel` | — / Esc | Encerra e relança com `--resume` os agentes da sessão que têm ID de conversa (`Restart <n> agents?`) / fecha o overlay | — | v1 (Fatia 4) | `testAction_dialog_restartAgents_confirm` · `testAction_dialog_restartAgents_cancel` |
| Delete Computer (§16.4) | `dialog.deleteComputer.confirm` | — | Apaga o container e o perfil (`computer.delete`) | — | v1 (Fatia 3) | `testAction_dialog_deleteComputer_confirm` |
| Delete Session (§16.5) | `dialog.deleteSession.confirm` | — | Apaga a sessão com as opções marcadas; toast `Session deleted.` com `Undo` | — | v1 | `testAction_dialog_deleteSession_confirm` |
| Cancel (§16.5) | `dialog.deleteSession.cancel` | Esc | Fecha o overlay | — | v1 | `testAction_dialog_deleteSession_cancel` |
| Keep the branch / Move folder to Trash / Also delete run folders (§16.5) | `dialog.deleteSession.keepBranch` / `dialog.deleteSession.trashFolder` / `dialog.deleteSession.deleteRuns` | — | Alternam as opções do apagar (padrões em §16.5) | Cada checkbox só aparece no tipo de sessão a que se aplica | v1 | `testAction_dialog_deleteSession_keepBranch` · `testAction_dialog_deleteSession_trashFolder` · `testAction_dialog_deleteSession_deleteRuns` |
| Don't ask again (§16.5) | `dialog.deleteSession.dontAsk` | — | Desliga a confirmação; só aparece quando não há perda de dados | — | v1 | `testAction_dialog_deleteSession_dontAsk` |
| Remove Project (§16.6) | `dialog.removeProject.confirm` | — | Arquiva as sessões e remove o projeto do app; nenhum arquivo é apagado | — | v1 | `testAction_dialog_removeProject_confirm` |
| Cancel (§16.6) | `dialog.removeProject.cancel` | Esc | Fecha o overlay | — | v1 | `testAction_dialog_removeProject_cancel` |
| Resume <n> / Not Now (§16.7) | `dialog.resumeAgents.confirm` / `dialog.resumeAgents.cancel` | — | Retoma os agentes marcados / fecha sem retomar | `Resume <n>` com 0 marcados: `Select at least one agent.` | v1 | `testAction_dialog_resumeAgents_confirm` · `testAction_dialog_resumeAgents_cancel` |
| Select All / Select None / linha com checkbox (§16.7) | `dialog.resumeAgents.selectAll` / `dialog.resumeAgents.selectNone` / `dialog.resumeAgents.toggleRow` | — | Marca ou desmarca os agentes da lista | — | v1 | `testAction_dialog_resumeAgents_selectAll` · `testAction_dialog_resumeAgents_selectNone` · `testAction_dialog_resumeAgents_toggleRow` |
| Move / Convert (§16.8) | `dialog.moveToProject.confirm` | — | Move a sessão limpa para o projeto escolhido ou a converte em projeto; agentes seguem rodando (mesmo PID) | Sem projeto escolhido: `Choose a project.` | v1 | `testAction_dialog_moveToProject_confirm` |
| Project (combobox, §16.8) | `dialog.moveToProject.setProject` | — | Escolhe o projeto ou `Convert to Project` | — | v1 | `testAction_dialog_moveToProject_setProject` |
| Cancel (§16.8) | `dialog.moveToProject.cancel` | Esc | Fecha o overlay sem mover | — | v1 | `testAction_dialog_moveToProject_cancel` |
| Add <n> Projects / Stop Scan (§16.9) | `dialog.addProject.addFound` / `dialog.addProject.stopScan` | — | Adiciona os repositórios marcados / interrompe o scan da pasta | — | v1 | `testAction_dialog_addProject_addFound` · `testAction_dialog_addProject_stopScan` |
| Campo `owner/repo` ou URL (§16.9b) | `dialog.cloneRepo.setSource` | — | `set(<texto>)`: filtra a lista e, se for referência válida, vira a primeira linha | — | v1 | `testAction_dialog_cloneRepo_setSource` |
| Linha de repositório (§16.9b) | `dialog.cloneRepo.select` | — | `select(<owner/repo>)`: marca a linha (↑↓) | — | v1 | `testAction_dialog_cloneRepo_select` |
| Clone (§16.9b) | `dialog.cloneRepo.submit` | ↵ | Clona a linha selecionada ou a referência digitada; mostra o progresso no painel e na sidebar | Sem referência válida: `Choose a repository or paste a URL.` | v1 | `testAction_dialog_cloneRepo_submit` |
| Cancel (§16.9b) | `dialog.cloneRepo.cancel` | Esc | Cancela o clone em andamento (remove a pasta parcial) e fecha o overlay | — | v1 | `testAction_dialog_cloneRepo_cancel` |
| Log in to GitHub (§16.9b) | `dialog.cloneRepo.logIn` | — | Abre uma tab com `gh auth login` | `Select a session first.` | v1 | `testAction_dialog_cloneRepo_logIn` |
| Try Again (§16.9b) | `dialog.cloneRepo.retry` | — | Repete o clone que falhou | — | v1 | `testAction_dialog_cloneRepo_retry` |
| Título (§16.9c) | `dialog.createPR.setTitle` | — | `set(<texto>)` | — | v1 (Fatia 2) | `testAction_dialog_createPR_setTitle` |
| Base (§16.9c) | `dialog.createPR.setBase` | — | `set(<branch>)` | — | v1 (Fatia 2) | `testAction_dialog_createPR_setBase` |
| Descrição (§16.9c) | `dialog.createPR.setBody` | — | `set(<texto>)` | — | v1 (Fatia 2) | `testAction_dialog_createPR_setBody` |
| Draft (§16.9c) | `dialog.createPR.setDraft` | — | `set(on|off)` | — | v1 (Fatia 2) | `testAction_dialog_createPR_setDraft` |
| Create (§16.9c) | `dialog.createPR.submit` | — | Faz push (se preciso) e roda `gh pr create`; o resultado vira o chip | Sem título: `Add a title.` | v1 (Fatia 2) | `testAction_dialog_createPR_submit` |
| Cancel (§16.9c) | `dialog.createPR.cancel` | Esc | Fecha sem enviar nada | — | v1 (Fatia 2) | `testAction_dialog_createPR_cancel` |
| Try Again (§16.9c) | `dialog.createPR.retry` | — | Repete os passos que falharam | — | v1 (Fatia 2) | `testAction_dialog_createPR_retry` |
| Open Compare on GitHub (§16.9c) | `dialog.createPR.openCompare` | — | `gh pr create --web` | — | v1 (Fatia 2) | `testAction_dialog_createPR_openCompare` |
| Keep Running (§16.10) | `dialog.quit.keepRunning` | ↵ | Fecha a janela e deixa o app em modo accessory; agentes seguem vivos | — | v1 | `testAction_dialog_quit_keepRunning` |
| Stop All and Quit… (§16.10) | `dialog.quit.stopAll` | — | Abre a segunda confirmação `Stop <n> agents and <m> computers?` | — | v1 | `testAction_dialog_quit_stopAll` |
| Stop All and Quit (segunda confirmação, §16.10) | `dialog.quit.stopAllConfirm` | — | Encerra os agentes e computadores e o app | — | v1 | `testAction_dialog_quit_stopAllConfirm` |
| Cancel (§16.10) | `dialog.quit.cancel` | Esc | Fecha o overlay e mantém tudo como está | — | v1 | `testAction_dialog_quit_cancel` |
| Don't ask again (§16.10) | `dialog.quit.dontAsk` | — | Desliga `Ask before quitting with running agents` | — | v1 | `testAction_dialog_quit_dontAsk` |
| Use Skip Permissions (§16.11) | `dialog.skipPermissions.confirm` | — | Lança com `Skip Permissions` e lembra a escolha para o perfil | — | v1 | `testAction_dialog_skipPermissions_confirm` |
| Paste (§16.12) | `dialog.pasteToAgent.confirm` | — | Cola o texto no prompt do agente com bracketed paste, sem Enter (T11) | Agente não está esperando entrada: `The agent isn't ready for input.` | v1 | `testAction_dialog_pasteToAgent_confirm` |
| Rename Branch (§16.13) | `dialog.renameBranch.confirm` | — | Renomeia a branch local (`session.renameBranch`) | Nome vazio ou igual: `Enter a new name.` | v1 | `testAction_dialog_renameBranch_confirm` |
| Licenses… / Copy Version Info (§16.14) | `dialog.about.licenses` / `dialog.about.copy` | — | Lista as licenças / copia versão, build, protocolo e schema | — | v1 | `testAction_dialog_about_licenses` · `testAction_dialog_about_copy` |
| Start Batch / Import CSV… (§16.15) | `dialog.newBatch.confirm` / `dialog.newBatch.importCSV` | ⌘↵ | Inicia o lote (abre o terminal Claude pai) / importa os alvos de um CSV | Sem alvos: `Add at least one target.` | v1 (Fatia 3) | `testAction_dialog_newBatch_confirm` · `testAction_dialog_newBatch_importCSV` |
| Campos de New Batch… (§16.15) | `dialog.newBatch.setTargets` / `.setBrief` / `.setDisplay` / `.setProxy` / `.toggleProxy` / `.setSession` / `.cancel` | Esc (cancel) | `set(<texto>)` nos alvos e no brief; `select(headless\|desktop\|http)`; `select(default\|none\|<proxy>)`; `select(<proxy>)` marca ou desmarca um proxy permitido; `select(new\|current)`; fecha o overlay | `current` sem terminal Claude na sessão: `Select a session with Claude Code.` | v1 (Fatia 3) | `testAction_dialog_newBatch_fields` |

### 24.10 Painel direito: contêiner e Files (10-right-panel)

| Ação | ActionID | Atalho | Efeito | Desabilitado (tooltip) | Versão | Teste (XCUITest) |
|---|---|---|---|---|---|---|
| Toggle Files / Toggle Insights | `rightPanel.toggleFiles` / `rightPanel.toggleInsights` | ⌥⌘1 / ⌥⌘2 | Liga ou desliga o módulo (abre o painel se estava fechado); o botão da faixa de topo mostra o estado | — | v1 | `testAction_rightPanel_toggleFiles` · `testAction_rightPanel_toggleInsights` |
| Toggle Data | `rightPanel.toggleData` | ⌥⌘3 | Liga ou desliga o módulo Data: a tabela ao vivo do dataset da sessão (abre sozinho quando dados começam a entrar) | — | v1 | `testAction_rightPanel_toggleData` |
| Toggle Computers | `rightPanel.toggleComputers` | ⌥⌘4 | Liga ou desliga o módulo Computers: por computador da sessão, a tela, os números do tráfego (requests, ritmo, erros, dados), CPU e memória, a tabela de proxies com o custo aproximado e as requests ao vivo | — | v1 | `testAction_rightPanel_toggleComputers` |
| Computers: escolher computador | `rightPanel.computersPick` | — | `select(<computer>)`: qual computador da sessão o módulo mostra; `select(<computer>\|<filter>)` com `all`/`api`/`errors` filtra a lista ao vivo | Desconhecido: `No such computer.` | v1 | `testAction_rightPanel_computersPick` |
| Traffic: abrir | `computer.openTraffic` | — | `select(<computer>[\|<requestId>])`: abre a tela Traffic do computador (todas as requests, hosts, request e response com cabeçalhos e corpo, e a aba Activity com os comandos) numa tab da sessão ao lado do agente, já na request pedida | Sem run: `No run folder for this computer.` | v1 | `testAction_computer_openTraffic` |
| Traffic: estado | `traffic.set` | — | `select(<computer>\|<chave>=<valor>)`: `filter` (`all`/`api`/`docs`/`errors`/`blocked`), `host` (vazio = todos), `query`, `select` (id da request), `requestTab`/`responseTab` (`headers`/`body`/`raw`), `mode` (`traffic`/`activity`), `side` (`request`/`response`: o lado do detalhe no pane estreito), `noise` (`on`/`off`: esconder scripts, estilos e imagens) | Chave desconhecida: erro | v1 | `testAction_traffic_set` |
| Traffic: copiar como cURL | `traffic.copyCurl` | — | `select(<computer>\|<requestId>)`: copia o `curl` da request (cookies e autorização viram `<redacted>`) | Request desconhecida: `No such request.` | v1 | `testAction_traffic_copyCurl` |
| Data: escolher dataset | `rightPanel.dataPick` | — | `select(<datasetId>)`: qual dataset da sessão o módulo Data mostra | Desconhecido: `No such dataset.` | v1 | `testAction_rightPanel_dataPick` |
| Toggle Right Panel | `rightPanel.toggle` | ⌥⌘0 | Fecha o painel inteiro ou o reabre como estava | — | v1 | `testAction_rightPanel_toggle` |
| Minimize Module | `rightPanel.minimize` | — | `select(<módulo>)`: esconde o módulo; o outro ocupa o painel; esconder o último fecha o painel | Nenhum aberto: `No module is open.` | v1 | `testAction_rightPanel_minimize` |
| Move Module | `rightPanel.move` | — | `select(<módulo>:top ou bottom)`: solta o header sobre o slot e troca de posição | — | v1 | `testAction_rightPanel_move` |
| Swap Modules | `rightPanel.swap` | — | Troca o módulo de cima com o de baixo | Menos de dois abertos: `Open both modules to swap them.` | v1 | `testAction_rightPanel_swap` |
| Set Panel Width / Set Panel Split | `rightPanel.setWidth` / `rightPanel.setSplit` | — | `set(<pontos>)` / `set(<fração 0…1>)`: mesma coisa que arrastar, para automação | — | v1 | `testAction_rightPanel_setWidth` · `testAction_rightPanel_setSplit` |
| Open File or Folder | `files.open` | — | `select(<caminho>)`: arquivo abre no visualizador (⌘ pressionado: no editor externo); pasta expande ou recolhe | — | v1 | `testAction_files_open` |
| Open in External Editor | `files.openExternal` | — | `select(<caminho>)`: abre no editor preferido ou no app padrão | — | v1 | `testAction_files_openExternal` |
| Back to Files | `files.closeFile` | — | Fecha o visualizador e volta à árvore | Nenhum arquivo aberto: `No file is open.` | v1 | `testAction_files_closeFile` |
| Pin Folder / Follow Terminal | `files.togglePin` | — | Alterna o chip: `Pinned` na pasta atual ou `Following <agente>` | Sem sessão: `Select a session first.` | v1 | `testAction_files_togglePin` |
| Show Session Folder | `files.showSessionFolder` | — | Fixa a árvore na pasta da sessão | Já nela: `Already showing the session folder.` | v1 | `testAction_files_showSessionFolder` |
| Show / Hide Ignored Files | `files.toggleIgnored` | — | Alterna `.git`, `node_modules` e o que o `.gitignore` ignora (esmaecidos) | — | v1 | `testAction_files_toggleIgnored` |
| Refresh (Files) | `files.refresh` | — | Relê a árvore, o git e o arquivo aberto | Sem sessão: `Select a session first.` | v1 | `testAction_files_refresh` |
| Find in File / Find Next / Find Previous / Close Find | `files.find` / `files.findNext` / `files.findPrevious` / `files.findClose` | — | Barra de busca do visualizador (`set(<texto>)` busca direto); navega entre ocorrências | Sem arquivo: `Open a file first.`; sem ocorrências: `No results` | v1 | `testAction_files_find` · `testAction_files_findNext` · `testAction_files_findPrevious` · `testAction_files_findClose` |
| Copy Path | `files.copyPath` | — | Copia o caminho do arquivo aberto; toast `Path copied.` | Sem arquivo: `No file is open.` | v1 | `testAction_files_copyPath` |
| Open in… / Open in Target | `files.openIn` / `files.openInTarget` | — | Menu com Finder, app padrão e editores; `select(<alvo>)` abre o arquivo aberto | Sem arquivo: `No file is open.` | v1 | `testAction_files_openIn` · `testAction_files_openInTarget` |
| Show Exact Limits | `insights.showExactLimits` | — | Clique explícito no Insights (Claude): o app lê o login do Claude Code no Keychain (uma vez; só a decisão é guardada) e passa a mostrar 5 h e semanal exatos, atualizados a cada 60 s com o módulo visível | Já ligado: `Exact limits are on.` | v1 | `testAction_insights_showExactLimits` |
