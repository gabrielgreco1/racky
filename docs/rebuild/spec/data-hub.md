# Data (área de dados): modelo de UX

Status: etapa 2 do roadmap (docs/rebuild/roadmap.md). Telas reais com dados de exemplo; conexões de verdade vêm na etapa 3.

## O problema

O usuário vai lidar com dados em lugares diferentes: o que os agentes coletaram e está guardado no Racky, e o que está fora (o Postgres do Supabase dele, um bucket S3, um warehouse, uma planilha, um webhook). O agente pode gravar num ou noutro. Se as telas forem parecidas demais, ele não sabe onde está, o que está vendo, nem o que um clique vai mudar. A regra desta área: **em qualquer tela, sem ler nada além do topo, o usuário sabe (1) em que lugar está, (2) que tipo de coisa está vendo, (3) de onde aquele dado veio e para onde vai, (4) se pode mudar algo e com que risco**.

## Conceitos e nomes (o usuário vê exatamente estes)

| Nome na UI | O que é |
|---|---|
| **Data** | A área inteira (item da sidebar, troca "Datasets"). |
| **Racky** | O armazenamento local do app. Onde os agentes guardam o que coletam quando ninguém pediu outro lugar. |
| **Dataset** | Uma tabela dentro do Racky, criada por um agente numa sessão. Sempre ligada a uma sessão. |
| **Connection** | Um lugar fora do Racky que o usuário conectou: banco, warehouse, bucket, planilha ou webhook. Tem nome dado pelo usuário e, se for o caso, ambiente (`prod`, `dev`). |
| **Table** | Uma tabela de um banco ou warehouse conectado. |
| **Query** | Um editor SQL aberto numa conexão (ou no Racky). |
| **Bucket / folder / file** | Armazenamento de objetos (S3, GCS, R2). |
| **Sheet** | Uma aba de planilha (Google Sheets, Airtable). |
| **Webhook** | Um destino que só recebe: não dá para navegar, só ver o que foi entregue. |
| **Writer** | Quem grava num lugar: um agente (e a sessão dele) ou um sync. |
| **Sync** | Uma cópia contínua (ou única) de um dataset do Racky para uma conexão. |

## Estrutura da tela Data

```
┌ Explorer ────────────┬ tabs: [▦ books2] [⛁ public.hotels] [⌘ Query 1] ───────────────────────────┐
│ RACKY                │ ┌ Location bar ─────────────────────────────────────────────────────────┐ │
│  ▾ Teste dos subag…  │ │ [Racky] Teste dos subagentes › books2        Dataset · 80 rows        │ │
│     ▦ books2  ●live  │ │ ← Codex 1, Codex 2 (live)   → Supabase prod › public.books (sync on)  │ │
│  ▸ Hotel prices      │ └───────────────────────────────────────────────────────────────────────┘ │
│ CONNECTIONS          │  conteúdo do objeto (dataset, tabela, query, bucket, webhook)             │
│  ▾ ⛁ Supabase 🔒 prod│                                                                           │
│     ▾ public         │                                                                           │
│        ▦ hotels      │                                                                           │
│        ▦ books ●live │                                                                           │
│     ⌘ New query      │                                                                           │
│  ▸ ⛁ Analytics  dev  │                                                                           │
│  ▸ ☁ scrapes-raw (S3)│                                                                           │
│  ▸ ⤴ Orders webhook  │                                                                           │
│ + Add connection     │                                                                           │
└──────────────────────┴───────────────────────────────────────────────────────────────────────────┘
```

- **Explorer** (esquerda, sempre visível na área Data): duas seções com título fixo, **Racky** e **Connections**. No Racky, os datasets agrupados por sessão. Em Connections, cada conexão com ícone do tipo, nome e selo de ambiente; expande para schemas → tabelas, buckets → pastas, planilhas → abas. Webhook não expande. Um ponto verde "live" em todo lugar onde algo está gravando agora. Rodapé: `+ Add connection`.
- **Topo do explorer (2026-10-25)**: título `Data` e o botão de recolher a lista. Com a sidebar recolhida, a faixa da janela (semáforos, nome, setas) ocupa o começo do topo: o título vem depois dela com a margem normal (12 pt), nunca colado nas setas, e a lista abaixo tem a mesma largura do topo. Lista recolhida (pelo botão ou por falta de largura): no lugar do título fica o botão `Show Data list`, sem a linha divisória (ela só separa a lista aberta do conteúdo). O botão diz o que quer (`show`/`hide`): pedir a lista com a janela estreita mostra a lista mesmo assim. A lista se recolhe sozinha quando sobram menos de 480 pt para o conteúdo.
- **Tabs**: cada objeto aberto é uma tab (como editores no DBeaver). O ícone da tab diz o tipo (dataset, tabela, query, pasta, webhook).
- **Location bar** (topo do conteúdo, em toda tela): o lugar como trilha clicável — chip do lugar (`Racky` ou o tipo + nome da conexão + ambiente) › schema/sessão › objeto — e à direita o tipo do objeto e o tamanho. Embaixo, uma linha de **fluxo**: `←` quem grava ali (agentes, syncs) e `→` para onde aquilo vai. É a linha que responde "de onde vem e para onde vai".
- **Tags e proteção**: não existe "ambiente" fixo. O usuário cria tags livres (prod, dev, cliente-x…), mostradas em chips neutros, que só identificam. Separado delas, cada conexão tem **Protected** (cadeado âmbar): numa conexão protegida, ações que escrevem pedem confirmação, aparece a faixa "Protected · <nome>" e o formulário de sessão avisa "Copies to a protected connection".

## Telas de objeto

1. **Dataset (Racky)**: a página atual (cartões, gráfico, filtro, facetas, grade). Ações: `Send to…` (copiar ou sincronizar para uma conexão), `Export`.
2. **Table (conexão)**: sub-abas `Data` (grade com filtro), `Structure` (colunas, tipos, chave, índices), `Writers` (agentes e syncs que gravam aqui, com o último envio). Selo `Read only` / `Editable`.
3. **Query**: editor SQL, conexão alvo bem visível na barra (`Running on …`), `Run` (⌘↩), resultado em grade, tempo e linhas.
4. **Bucket**: trilha de pastas, lista de arquivos (nome, formato, tamanho, alterado), prévia de Parquet/CSV/JSONL em grade ao lado.
5. **Webhook**: endpoint, formato, log de entregas (hora, status, linhas, duração), `Send test`.
6. **Add connection**: tipos agrupados (Databases, Warehouses, Storage, Spreadsheets, Outgoing); cada tipo diz se é `Browse and write` ou `Write only`.

## Onde o agente grava

No formulário de nova sessão, uma linha **Save data to**: `Racky` (padrão; cria um dataset da sessão) ou uma conexão (escolher conexão › schema › tabela existente ou nova). A sessão na sidebar mostra o destino. Na Data, o lugar escolhido ganha o agente como writer na linha de fluxo.

## Bancos dentro dos computadores

Um Postgres que o agente sobe dentro do computador (o smoke de um crawler, um banco de teste) aparece no Racky sem nenhuma ação dele:

- **Achar:** o `/work` do computador mora no disco do Mac. A cada 10 s o app procura `postmaster.pid` + `PG_VERSION` no `/work` (até 4
  níveis, sem `.git`, `node_modules`, `.venv`, `store`, `evidence`); a 4ª linha do `postmaster.pid` é a porta.
- **Ler:** o app abre uma porta no loopback do Mac que passa pela admin API do computador (`GET /v1/tcp?port=<n>`, com o token do
  computador, `Upgrade: racky-tcp`; só `127.0.0.1` da VM, só portas ≥ 1024 e nunca as de controle) e conecta como `postgres` (ou
  `agent`), sem senha e sem TLS: o tráfego não sai do Mac e da VM. Tudo só leitura (o conector roda em `BEGIN READ ONLY`).
- **Explorer:** cada banco vira uma conexão `<computador> · <pasta>` (`il-chicago · run/pg`), etiqueta `computer`, endereço `In
  computer <nome>`, com schemas, tabelas, grade e SQL como qualquer Postgres. Não é salva e não tem `Remove`: some quando o cluster
  para ou o computador é liberado.
- **Sessão:** cada tabela com linhas é copiada para um dataset da sessão do computador, `<computador>-<schema>-<tabela>` (até
  20.000 linhas por tabela; relê só quando a contagem muda; linhas repetidas não duplicam). Assim o módulo Data da sessão abre
  sozinho com as primeiras linhas, igual a um dataset que o agente grava, e os dados ficam no Racky depois que o cluster descartável
  some.

## Como validar

Prints das telas com dados de exemplo vão para 10 subagentes sem nenhum contexto, com perguntas fixas:
1. Que aplicativo é este e o que esta tela mostra?
2. Em que lugar está o dado que você está vendo (no app ou fora dele)? Qual?
3. De onde esse dado veio? Ele está indo para algum outro lugar?
4. Qual a diferença entre esta tela e a outra (par de prints)?
5. Se você clicar em X, o que muda e onde? Há algum risco?
6. Como você mandaria estes dados para o Postgres de produção?
Critério: 10 de 10 acertam 1–5 e descrevem um caminho válido em 6. Cada erro vira uma mudança na tela, e a rodada se repete.
