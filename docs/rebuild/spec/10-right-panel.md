# 10 · Painel direito: Files (código) e Insights (uso de IA + máquina)

Status: requisito do dono em 2026-10-17, entra na v1. Decisões em `00-decisions.md` P22. Referência de layout: Conductor (painel direito dividido em cima/baixo). Referência do painel de monitoramento: repositório que o dono vai enviar (macOS, uso do computador e apps).

## 1. Layout

- A janela ganha um **painel direito** ao lado da área de terminais, dividido verticalmente em dois módulos:
  - **Files** (padrão em cima, ~2/3 da altura).
  - **Insights** (padrão embaixo, ~1/3 da altura).
- Tudo redimensionável por arrasto: largura do painel direito (terminal cresce quando o painel diminui) e divisão entre os dois módulos. Tamanhos persistidos por janela.
- Cada módulo pode ser **minimizado** (some; o outro ocupa o espaço) e o painel inteiro pode ser **fechado** (os terminais ocupam a janela toda).
- Módulos podem trocar de posição por arrasto do header (cima ↔ baixo) e ser reabertos por botões claros na faixa de topo, à direita: um botão para Files e um para Insights, com estado ligado/desligado visível e atalhos (⌥⌘1 Files, ⌥⌘2 Insights, ⌥⌘0 painel inteiro).
- Abrir, fechar, minimizar e trocar têm motion conforme 04 (painel por recorte a partir da borda do terminal; terminal faz um único resize por transição).
- Larguras mínimas: abaixo de um limiar o módulo vira modo compacto (só ícones/números principais); nada sai da caixa em 760×480.

## 2. Files (cima)

- Árvore de arquivos do **diretório atual da sessão**: projeto/worktree para sessões de projeto; pasta da sessão limpa para sessões limpas.
- **Dinâmico com o agente**: acompanha o `cwd` do terminal focado (OSC 7 / hooks `cwd` do Claude) e as pastas que o agente cria ou acessa ("acessa a pasta tal", "crie a pasta tal"): quando o cwd do agente muda, a árvore muda de raiz com transição suave e um chip "Following Claude" que pode ser desligado (pin).
- Clique abre o arquivo num **visualizador de código** dentro do módulo (somente leitura na v1, syntax highlight, busca, número de linha, ⌘-clique abre no editor externo via "Open in…"). Arquivos alterados pelo agente aparecem marcados (git status + eventos de escrita dos hooks), com diff rápido.
- FSEvents para atualizar; ignora `.git`, `node_modules` e o que o `.gitignore` ignora (alternável).

## 3. Insights (baixo)

Abas:
1. **Claude** — uso do dia e da semana em tokens e custo estimado, janelas de limite (5 h e 7 d, como a status line do Claude mostra), plano detectado, sessões e modelos mais usados; visualização própria e bonita (não só duas barras): anel/medidor animado da janela atual, heatmap por hora do dia, sparkline semanal.
2. **Codex** — o mesmo para o Codex (rollouts `token_count`, rate limits, plano).
3. **Machine** — CPU, memória, disco e rede do Mac; processos/apps que mais usam; agentes e subagentes do Racky (por sessão); computadores Docker (memória da VM, por computador); alerta quando subagentes estão pesando demais.
4. **Proxy** — uso do proxy por computador/lote (P13), quando houver.

Fontes de dados (somente leitura, nada é enviado para fora):
- Claude: transcripts `~/.claude/projects/**/*.jsonl` (uso por mensagem), `rate_limits`/status dos hooks e da status line, `claude auth status`.
- Codex: `~/.codex/sessions/**/rollout-*.jsonl` (`token_count`, `rate_limits`), `codex login status`.
- Máquina: `host_statistics64`, `proc_pidinfo`/`libproc`, Docker Engine API.
- Atualização incremental com watchers; agregados persistidos no Store.

## 4. Critérios de aceite (novos)

- AC-RP01: abrir sessão de projeto mostra a árvore do projeto; sessão limpa mostra a pasta da sessão; `cd` do agente para outra pasta muda a raiz em ≤ 1 s com "Following Claude".
- AC-RP02: arrastar o divisor redimensiona Files/Insights e o terminal com um único resize de PTY ao soltar; tamanhos persistem ao reabrir.
- AC-RP03: minimizar Insights faz Files ocupar o painel; fechar o painel deixa o terminal em tela cheia; botões da faixa de topo reabrem cada módulo.
- AC-RP04: arrastar o header de Insights para cima troca a ordem dos módulos.
- AC-RP05: aba Claude mostra uso de hoje e da semana batendo (±2%) com a soma dos transcripts; janelas 5 h/7 d batem com a status line.
- AC-RP06: aba Machine lista CPU/memória e os top processos e mostra os computadores Docker ativos com memória.
- AC-RP07: em 760×480 nada sai da caixa; abaixo do limiar os módulos entram em modo compacto.
