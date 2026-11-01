# Racky — lista de tarefas

Uma lista só. Todo pedido novo entra aqui na hora; quando sai, vai pra "Feito" com o commit.

## A fazer

| # | Tarefa | Estado |
|---|--------|--------|
| 1 | **Envios fora do pedido** (ideia do tweet): comparar cada request que manda dados (POST/PUT com corpo, upload) com a tarefa do agente. Sinais baratos primeiro: host fora da tarefa e da navegação, corpo com linhas do dataset, corpo com segredo do cofre, volume anormal. Depois um modelo pequeno revisa só as sinalizadas. Na UI: cor "fora do pedido" nas requests, filtro no Traffic, aviso no Inbox se um segredo sair. Bloquear só segredo vazando. | aguardando seu OK pra ordem (antes ou depois da cloud) |
| 2 | **AWS: próximos passos**: (a) reconciliar o gasto com o Cost Explorer (precisa ativar a tag `racky:owner` como cost allocation tag); (b) adotar computers que seguiram vivos num host remoto ao reabrir o app; (c) imagem pronta (AMI própria) pra o host subir em 1 min em vez de ~3; (d) papel IAM mínimo por CloudFormation em vez da sessão de admin do `aws login`. | a fazer |
| 0 | **Redesenho da página Computers** (pedido 28/10): manter os cards This Mac / Your cloud e os tiles de provedor; New sessions lá em cima; configurar a nuvem como passos obrigatórios (conta, região, limite por dia/mês e quantos computers) com Salvar; regiões sem bandeira emoji; Spending e Left on disk com outra cara. Mockup antes do código. | feito (este commit) |
| 2a | **Fechar a VM mais cedo**: fechar na hora quando a sessão não tem outro subagente nem lote; esperar ~2 min só em lote; opção em Settings (na hora / 2 min / 5 min). Hoje espera 5 min fixos. | aguardando seu OK |
| 2b | **Racky Cloud gerenciado (lançamento público)**: VMs sempre ligadas na conta do Racky, um pool com vagas livres, cada usuário ganha um computer na hora; isolamento entre clientes por microVM (Firecracker/gVisor) em vez de só Docker; IP de saída por cliente; cobrança por minuto de computer; autoscaling (manter N vagas livres, desligar à noite). | futuro, quando houver usuários pagando |
| 2c | **Left on disk melhor**: mostrar 3–4 runs e "Ver mais", clicar num run pra ver a sessão, apagar fácil, UI mais caprichada (pedido 27/10). | depois da AWS funcionando |
| 3 | **Scroll do terminal liso**: o SwiftTerm rola linha a linha ("em quadros"); precisa de deslocamento por pixel por cima dele. | aguardando seu OK |
| 4 | **Aba Agents & Skills no painel direito** (estilo Maestro): ver todos, escolher, skills carregadas no launch; ver qual agente trabalha em cada sessão; Library ordenada pelo que está aberto. | a fazer |
| 5 | **Memória de agente**: o mesmo agente cuida de uma família de tarefas (ex.: um agente por site, reusado entre cidades). | a fazer, junto com o 4 |
| 6 | **Testar o "Change…" de proxy ao vivo**: implementado, mas nunca exercitado com um computer rodando. | a fazer (precisa de um computer vivo) |
| 8 | **Developer ID**: assinar e notarizar o app pros testers. | a fazer |
| 9 | **Merge desta branch de trabalho na main**. | aguardando seu OK |
| 17 | **Sobras da auditoria de segurança** (31/10): o instalador confia num `.sha256` da mesma release e o app não é notarizado (resolve com o item 8); OSC 52 (o terminal pode trocar a área de transferência) ligado por padrão; daemon só confere o uid em build ad-hoc. | aguardando sua decisão |
| 11 | **Pasta do projeto ou da sessão sumiu** (pedido 30/10): hoje o app só diz "isn't a Git repository anymore" com Try Again. Detectar a pasta apagada e oferecer Clonar de novo (usa o remote salvo), Localizar a pasta ou Arquivar; sessão sem pasta (quiet-meadow, tiny-yonder) oferece recriar a pasta vazia. Causa desta vez: a limpeza de disco de 28/10 apagou a pasta antiga. | aguardando seu OK |

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
