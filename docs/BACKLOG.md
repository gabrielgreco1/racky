# Racky — lista de tarefas

Uma lista só. Todo pedido novo entra aqui na hora; quando sai, vai pra "Feito" com o commit.

## A fazer

Em ordem do mais fácil pro mais difícil (pedido 03/11).

| # | Tarefa | Estado |
|---|--------|--------|
| 2c | **Left on disk melhor**: mostrar 3–4 runs e "Ver mais", clicar num run pra ver a sessão, apagar fácil, UI mais caprichada (pedido 27/10). | depois da AWS funcionando |
| 6 | **Testar o "Change…" de proxy ao vivo**: implementado, mas nunca exercitado com um computer rodando. | a fazer (precisa de um computer vivo) |
| 3 | **Scroll do terminal liso**: o SwiftTerm rola linha a linha ("em quadros"); precisa de deslocamento por pixel por cima dele. | aguardando seu OK |
| 8 | **Developer ID**: assinar e notarizar o app pros testers. | a fazer |
| 17 | **Sobras da auditoria de segurança** (31/10): o instalador confia num `.sha256` da mesma release e o app não é notarizado; o daemon só confere o uid em build ad-hoc. Os dois resolvem com o item 8 (assinar com certificado). | junto com o item 8 |
| 21 | **Computers ainda pesados** (pedido 03/11: 7 GB pra 4 computers é muito). Medido: o balão não devolve memória ao Mac depois de um pico (balão encheu 2 GB, o Mac seguiu em 2,3 GB); Chromium aberto ~0,6 GB + ~0,4 GB de cache de arquivos dele; base ~0,4 GB. Caminhos: fazer a devolução funcionar (free page reporting / drop_caches / testar sob pressão), fechar o Chromium parado, reiniciar a VM entre tarefas, um Chromium só com vários perfis, VM headless de 3 → 2 GB. | análise enviada, aguardando escolha |
| 2 | **AWS: próximos passos**: (a) reconciliar o gasto com o Cost Explorer (precisa ativar a tag `racky:owner` como cost allocation tag); (b) adotar computers que seguiram vivos num host remoto ao reabrir o app; (c) imagem pronta (AMI própria) pra o host subir em 1 min em vez de ~3; (d) papel IAM mínimo por CloudFormation em vez da sessão de admin do `aws login`. | a fazer |
| 1 | **Envios fora do pedido** (ideia do tweet): comparar cada request que manda dados (POST/PUT com corpo, upload) com a tarefa do agente. Sinais baratos primeiro: host fora da tarefa e da navegação, corpo com linhas do dataset, corpo com segredo do cofre, volume anormal. Depois um modelo pequeno revisa só as sinalizadas. Na UI: cor "fora do pedido" nas requests, filtro no Traffic, aviso no Inbox se um segredo sair. Bloquear só segredo vazando. | aguardando seu OK pra ordem (antes ou depois da cloud) |
| 18 | **Modelo certo pra cada tarefa** (pedido 01/11, ideia do Santos nas calls de 23/10 e 30/10): o orquestrador continua no modelo forte; cada subagente recebe o modelo pelo tipo de tarefa (planejar, navegar/clicar, ler e extrair, escrever o crawler, ajuste pequeno, QA). Em Settings e no composer, um modo: Economizar / Equilibrado / Melhor resultado / Adaptativo, cada um com uma tabela tarefa → modelo que o dev pode editar. Sem nomes fixos: o app detecta o que o usuário tem (Claude, Codex/GPT, OpenCode com OpenRouter etc.) e só escolhe entre esses; a ordem inicial vem do preço, não de "qual é melhor", e o placar é quem decide. O Racky mede cada run (modelo, custo, tempo, smoke passou, linhas, % de campos válidos, se precisou de takeover) e monta um placar por tarefa × modelo; no adaptativo, um classificador barato escolhe o modelo e o placar sugere mudanças na tabela. Versão de 01/11: (a) base de referências externas (estudos, benchmarks, artigos por modelo e por habilidade, com fonte e data, atualizada de tempos em tempos); (b) o orquestrador dá um veredito curto de cada subagente (ok / faltou X / falhou) numa única chamada de ferramenta, somado aos sinais objetivos do Racky; (c) sem roteador por chamada: uma tabela tarefa → modelo montada a partir da base externa e dos modelos que o usuário tem; o orquestrador diz o tipo da tarefa no `agent_spawn` e o app só consulta a tabela; a tabela é recalculada por conta (sem LLM) conforme o placar cresce; testa outro modelo só de vez em quando e nunca um mais caro; o usuário vê só uma linha discreta no subagente. | proposta enviada, aguardando seu OK |
| 25 | **Agentes de verdade** (pedido 03/11, junta os itens 4 e 5): (a) Library arrumada: um agente por nome mesmo existindo em ~/.claude e ~/.codex (os dois logos na linha), lista e página legíveis, arrastar o agente para uma sessão ou para o composer; (b) barra da esquerda com Agents primeiro e Agents / Projects / Sessions minimizáveis; (c) cada agente com seu computador pronto (com ou sem tela, memória, proxy/país, pacotes) e suas variáveis (logins, senhas, API keys do cofre, entram como variáveis no computador, nunca no prompt, mascaradas nos logs); (d) sites logados: o usuário loga uma vez pelo Take over, o Racky guarda cookies e storage criptografados no cofre e carrega no computador do agente antes de ele começar; sessão vencida vira pedido no Inbox; (e) memória do agente: depois de cada tarefa uma entrada curta e comprimida (estilo caveman, URLs/código intactos) em SQLite com busca; no início o agente recebe só um índice curto e consulta o resto com memory_search/memory_read; compactação periódica; o usuário vê e edita; (f) criar agente pelo app (do zero, por descrição ou importando um .md). O Racky guarda o agente em ~/Racky/agents e gera a versão de cada CLI na hora de lançar, sem escrever em ~/.claude ou ~/.codex. | estrutura enviada; próximo: mockup |
| 2b | **Racky Cloud gerenciado (lançamento público)**: VMs sempre ligadas na conta do Racky, um pool com vagas livres, cada usuário ganha um computer na hora; isolamento entre clientes por microVM (Firecracker/gVisor) em vez de só Docker; IP de saída por cliente; cobrança por minuto de computer; autoscaling (manter N vagas livres, desligar à noite). | futuro, quando houver usuários pagando |

## Feito (03/11, terceira leva)

| Tarefa | Commit |
|--------|--------|
| **OSC 52 desligado por padrão** (item 17): programas no terminal só trocam a área de transferência se ligar "Let programs copy to the clipboard" em Settings › Terminal. | este commit |
| **PR e diário do subagente** (item 24b): "#N" na linha do subagente abre o PR que ele citou no resumo final; a aba dele mostra o diário inteiro (mais novo em cima, relido a cada 5 s). | este commit |
| **Pasta do projeto ou da sessão sumiu** (item 11): a barra mostra "Folder not found"; o menu do projeto oferece Clone Again (remote salvo) e Locate Folder… (só aceita o mesmo repositório); o da sessão oferece Locate Folder… e, sem Git, Recreate Empty Folder. Remove Project… continua e não apaga nada. | este commit |

## Feito (03/11, segunda leva)

| Tarefa | Commit |
|--------|--------|
| **Barra da esquerda por subagente** (pedido 03/11): uma linha por subagente com o logo da AI, setinha que abre o computador e as tabelas dele, "N finished", "N tables"; aba do subagente com a coluna do que ele entregou. | 37a078e |
| **Subagentes e tabelas voltam ao reabrir o app** (visto 03/11: sessão sem subagentes e "53 tables"). | 8276221 |
| **Full access ignorado depois de reabrir o app** (pedido 03/11): o pedido de computador lê o modo atual da sessão. | ad36f9a |
| **VMs de subagente que já terminou continuavam ligadas** (visto 03/11): o keep 24h desliga a VM e guarda só a pasta; o próximo box_claim religa com a mesma /work. | 37a078e |
| **Fechar a VM mais cedo** (item 2a): resolvido junto: a VM desliga na hora em que o subagente solta o computador. | 37a078e |
| **"Racky is not running" para os agentes**: o app.sock não é mais roubado por testes (RACKY_HOME isolado) e o app religa o socket se ele for trocado. | 676a3c8 |
| **Redesenho da página Computers** (pedido 28/10). | feito antes, só faltava tirar da lista |
| **Merge da branch de trabalho na main** (item 9): cada leva já vai direto para a main. | contínuo |

## Feito (03/11)

| Tarefa | Commit |
|--------|--------|
| **Computers mais leves** (pedido 02/11): navegador, tela e VNC só sobem quando o agente usa (ou a tela ao vivo abre); Chromium com menos processos; swap de 2 GB em arquivo na VM (pico deixa lento, não trava); balão de memória ajustado o tempo todo (a VM só ocupa no Mac o que usa + 512 MB). Teste com 4 computers: pico 8,9 → 6,2 GB no cenário misto, 9,1 → 6,9 GB todos navegando; parado 1,79 GB → 0,40 GB por computer. Runtime runtime-1-e9994cd837e6. | este commit |
| **Seletores do painel direito e VM travada** (pedido 02/11): seletor de computador e menus da aba Data voltaram a abrir; VM sem memória (pytest + Chromium) não fica mais girando: o desligar tem prazo de 30 s e mata só o processo daquela VM. | 393305c |

## Feito (31/10)

| Tarefa | Commit |
|--------|--------|
| **Crash na demo (pedido 31/10)**: o app caiu às 11:09 de 30/10 ao autorizar o `aws login`. Causa: o ProcessRunner vazava os pipes de cada comando que não chegava a rodar (pasta apagada) e o app acumulou ~5 mil descritores até o sistema não conseguir abrir a biblioteca Metal. | histórico novo |
| **Arrastar dataset pro notebook** (pedido 31/10): arrastar um dataset da coluna Data para a aba do notebook põe ele em "Datasets in this notebook"; "Load into notebook" carrega no notebook. | histórico novo |
| **QA forte + segurança** (pedido 31/10): procurar bugs e vulnerabilidades no código todo. | histórico novo |
| **Audit de peso** (pedido 31/10): o que pesa no código, o que não precisa estar no repo, limpeza geral. | histórico novo |
| Testes estáveis: `scripts/test.sh all` (unit em paralelo, integração em série); testes que cobravam UI removida foram ajustados | histórico novo |
| **Repo limpo de nomes** (pedido 31/10): tirar do repo nomes de empresa, nomes pessoais e de projetos pessoais; histórico reescrito num commit só com force push (OK do dono 31/10). | histórico novo |

## Feito (sessão de 27/10)

| Tarefa | Commit |
|--------|--------|
| Limpeza do que o agente deixa no computer (escolha no card + padrão em Settings + "Left on disk") | 34f5c65 |
| Visual próprio v5 (cores, fonte do Mac, sidebar com miniaturas dos computers) | ae82d5b |
| Notebook reabre, aba de notebook com cara de notebook, notebook ao lado do agente | 0ce8260 |
| Scrollbar piscando no painel direito | 0ce8260 |
| Aba Computers no painel direito + mini Burp (Traffic) por computer | 0ce8260, 8fd5a5b, 4bb40af |
| Logos oficiais dos provedores de proxy, ícones por tipo de request | 4bb40af |
| Lag ao redimensionar o painel | c7a2478 |
| Cores como no Data, tiles no lugar da timeline | 7cb8d75 |
| "Talked to" e "Exit" (proxy em uso, custo por proxy, troca ao vivo) | c4f2040 |
| Página Computers volta a rolar com muitos runs em Left on disk | 1265c5e |
| AWS funcionando: Connect AWS (aws login), VM na sua conta, computer rodando nela, VM apagada ao terminar/sair, registro de custo na tela | este commit |
| Landing nova (racky-site.vercel.app): "racky" gigante e os computers dos subagentes entrando num rack com legenda ao rolar; Agents, Take Over, Traffic, Cloud, Install | este commit |
| Pastas de trabalho só em ~/Racky (projects, sessions, worktrees) | este commit |
