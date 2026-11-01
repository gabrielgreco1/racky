# Data › Prefect: visão geral, execuções e detalhe

Status: spec aprovada pelo dono em 2026-10-25 (seções 1 e 2 da proposta). Substitui a tela atual "Flow runs", que é só uma grade com
uma linha por execução e três abas (Running, Scheduled, Failed). Tudo continua **só leitura**: o Racky nunca dispara, cancela, pausa
nem edita nada na Prefect.

## O problema

Com uma conexão Prefect aberta, o usuário quer o que veria na própria Prefect: se os fluxos estão rodando bem, o que rodou, quanto
demorou, o que falhou e por quê. Hoje ele vê uma linha por execução em andamento, e uma execução que termina bem some da lista ("Nothing
is running right now"). Não há histórico, tarefas, log nem deployments.

## Estrutura

A conexão Prefect no explorer abre uma tab com três abas no topo do conteúdo, abaixo da location bar
(`[◆ Prefect local · Prefect] › <aba>`):

| Aba | Para quê |
|---|---|
| **Overview** (padrão) | Saúde da conexão num relance: números, execuções no tempo, deployments. |
| **Runs** | Todas as execuções, filtráveis por estado, com o detalhe de uma ao lado. |
| **Deployments** | Os deployments com agenda e histórico. |

À direita da location bar, `Open in Prefect UI ↗` abre a mesma tela na interface da própria Prefect (URL da conexão sem `/api`). No
explorer, a conexão ganha os filhos `Overview`, `Runs` e `Deployments` (hoje só `Flow runs`).

### Overview

1. **Quatro números** (cartões iguais aos do dataset, `DatasetOverviewTiles`):
   - *Runs, last hour*: total; legenda `N running · N scheduled`.
   - *Success*: completed / (completed + failed + crashed) da última hora; legenda `N completed · N failed`. Abaixo de 100% o número
     usa `warning`; abaixo de 80%, `destructive`.
   - *Median duration*: mediana de `total_run_time` das execuções terminadas na última hora; legenda `p95 X`.
   - *Tasks*: soma das tarefas da última hora; legenda `N per run · N retries`.
2. **Runs over time**: barras empilhadas por estado (Completed, Failed, Running, Scheduled), um intervalo por barra, no mesmo
   componente e motion do `ActivityChart`. Janela padrão: última hora, com o seletor de período do dataset (1 h, 24 h, 7 d). Hover
   mostra o intervalo e a contagem por estado; clicar numa barra abre **Runs** filtrado por aquele intervalo.
3. **Deployments** (até 8; o resto em `View all` → aba Deployments): colunas `deployment`, `flow`, `schedule` (texto humano: `every
   30 s`, `daily at 06:00`, `cron 0 * * * *`, `paused`), `last 20 runs` (20 tracinhos, um por execução, cor do estado, mais recente à
   direita), `last run` (estado + hora), `next` (próxima agendada ou `paused`). Clicar na linha abre **Runs** filtrado pelo deployment.

### Runs

- Filtro por estado em segmentos com contagem: **All**, Running, Completed, Failed, Scheduled. `Failed` agrupa Failed, Crashed e
  TimedOut. O filtro de deployment (vindo da Overview) aparece como chip removível ao lado.
- Grade: `state` (bolinha da cor do estado + nome), `run` (nome da execução), `deployment`, `started` (hora; data se não for hoje),
  `duration`, `tasks` (`concluídas/total`, em `warning` quando houve falha). Mais recentes primeiro, 50 por página com o paginador do
  Postgres.
- Clicar numa linha abre o **detalhe à direita** (a grade encolhe, como o painel de linha do dataset); ↑/↓ troca de execução com o
  detalhe aberto; Esc fecha.

### Detalhe de uma execução

1. **Cabeçalho**: bolinha + nome da execução, `estado · duração · início`, `Open in Prefect UI ↗` (abre a execução).
2. **Campos**: deployment, flow, parameters (JSON compacto, em mono; `none` se vazio), work pool (ou `served process`), tags, tentativas.
3. **Tasks**: linha do tempo, uma faixa por tarefa com início e duração relativos à execução. Tarefas mapeadas com o mesmo nome base
   (`fetch_item-6af`, `fetch_item-674`…) viram **uma faixa** `fetch_item × 60`, do primeiro início ao último fim; a contagem de falhas
   aparece à direita (`2 failed`). Faixa na cor do estado. Hover mostra a duração exata e o estado.
4. **Log**: as últimas 200 linhas da execução (`hora  mensagem`, mono 11), níveis WARNING e ERROR em `warning` e `destructive`; `Show
   all` carrega mais. Execução em andamento: o log atualiza junto com o refresh.
5. Execução com falha: a mensagem do estado final (o `message` do state) aparece logo abaixo do cabeçalho, numa faixa `destructive`.

### Deployments

A mesma grade da Overview, completa, com `flow`, `work pool`, `tags` e `last 20 runs`. Clicar abre Runs filtrado.

## De onde vêm os dados (API da Prefect, só leitura)

| Tela | Chamada |
|---|---|
| Números e lista | `POST /flow_runs/filter` (estados, `start_time` na janela, `sort: START_TIME_DESC`, `limit`/`offset`) |
| Runs over time | `POST /flow_runs/history` (`history_start`, `history_end`, `history_interval`) |
| Deployments | `POST /deployments/filter` + `POST /flows/filter` (nome do flow) + `POST /flow_runs/filter` por deployment (últimas 20) |
| Tasks | `POST /task_runs/filter` com `flow_runs.id.any_ = [id]`, até 500 |
| Log | `POST /logs/filter` com `flow_run_id`, `sort: TIMESTAMP_DESC`, `limit: 200` |

Autenticação como hoje (`PrefectClient`: basic auth self-hosted, Bearer no Cloud). Refresh: a cada 10 s com a tab visível e a 60 s em
segundo plano; nada roda com a tab fechada. Todas as horas no fuso do Mac (a API devolve UTC).

## Estados

| Estado | Visual |
|---|---|
| carregando | esqueleto dos cartões e da grade (como o dataset) |
| sem execuções na janela | Overview: `No runs in the last hour.` + `Show 24 h`; Runs: `No runs match this filter.` |
| conexão falhou | `DataErrorBanner` com a causa (`Couldn't reach Prefect at <url>`) e `Try Again`; mantém o último dado visto com a hora |
| execução sem tarefas | seção Tasks diz `This run has no tasks.` |

Cores dos estados (tokens, sem cor nova): Completed `dataValid`, Running `accent`, Failed/Crashed `destructive`, Scheduled/Pending
`textTertiary`, Cancelled `textQuaternary`.

## IDs de automação

`data.prefect.tab.<overview|runs|deployments>`, `data.prefect.openInPrefect`, `data.prefect.kpi.<runs|success|duration|tasks>`,
`data.prefect.chart`, `data.prefect.chart.bucket.<index>`, `data.prefect.deployment.<id>`, `data.prefect.runs.filter.<state>`,
`data.prefect.runs.deploymentChip`, `data.prefect.run.<id>`, `data.prefect.detail`, `data.prefect.detail.close`,
`data.prefect.detail.tasks`, `data.prefect.detail.task.<name>`, `data.prefect.detail.log`, `data.prefect.detail.showAllLog`.
Ações: `data.prefectTab` (`select(overview|runs|deployments)`), `data.prefectRunsFilter` (`select(<estado>)`, `select(deployment:<id>)`),
`data.prefectOpenRun` (`select(<id>)`, `select(close)`).

## Como validar

1. Contra um servidor real: `prefect server start` local e um flow servido (o `hn-crawler` de teste: 60 tarefas mapeadas por execução,
   a cada 30 s, gravando num Postgres). Números conferidos contra a própria API; uma execução forçada a falhar aparece em Failed com a
   mensagem e a faixa de tarefas com as falhas.
2. Testes de unidade com servidor falso: agrupamento de tarefas mapeadas, success/mediana/p95, texto da agenda (interval, cron, rrule,
   paused), fuso.
3. Rodada de 10 testers sem contexto com prints de Overview, Runs e detalhe: (a) os fluxos estão saudáveis? (b) qual execução falhou e
   por quê? (c) quanto demora uma execução e qual tarefa pesa mais? (d) como abrir isso na própria Prefect? Critério: 10/10.

## Fora do escopo

Disparar, cancelar, pausar ou reagendar execuções; editar deployments, work pools ou variáveis; artifacts e eventos (podem entrar
depois no detalhe); ligar uma execução à tabela que ela gravou (a Prefect não informa; fica para quando o Racky souber o destino).
