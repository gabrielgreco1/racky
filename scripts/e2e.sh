#!/usr/bin/env bash
# e2e.sh - o Racky de verdade, de ponta a ponta (08 AR-810): app construído, daemon, Docker e Claude Code reais.
#
# Contrato
#   Entrada : Docker rodando, `claude` logado, Xcode (build.sh). Nada é instalado em /Applications: o app é construído por
#             scripts/build.sh (RACKY_BUILD_DIR, padrão build/e2e) e COPIADO para um diretório temporário curto (/tmp/abe2e-XXXXXX,
#             o limite do sun_path é 104 bytes) com dados num RACKY_HOME temporário. Sem RACKY_LAUNCHD: o app sobe um daemon filho
#             e nunca toca no job do launchd do dono. RACKY_E2E_APP=<Racky.app> pula o build e usa esse bundle.
#   Passos  : 1 build, instalação temporária e isolamento (home, socket, owner dos containers) · 2 projeto, shell e Claude
#             3 ⌘Q com Keep Running, reabrir: mesmos PIDs de PTY e buffer restaurado · 4 subagente leve com box_claim: container,
#             rede, iptables, VNC, um quadro · 5 Take Over (imediato) e Hand Back · 6 computador efêmero removido (container e
#             volume) quando o subagente solta · 7 daemon morto com kill -9: banner, estado interrupted, Resume · 8 nenhum token
#             em `docker inspect`, nos logs do container nem nos logs do app · 9 lote de 10 crawlers ("Subagent computers" = full):
#             10 computadores, 10 resultados validados, tudo removido, nada vazado, tempo e custo.
#   Modelo  : o pai usa RACKY_E2E_MODEL (padrão `haiku`) por um perfil duplicado do "Claude · Default"; os subagentes herdam.
#   Segurança: só mexe no que ele mesmo criou. Containers e volumes são achados e removidos pelo label racky.owner do app de
#             teste (derivado do RACKY_HOME, nunca `racky`, que é o do app do dono) e pelos IDs do banco de teste. Antes e depois
#             grava o que é do dono (processos do app instalado, job do launchd, containers) e falha se mudou. No fim (sempre) encerra o
#             app de teste, mata só os PIDs que ele subiu, remove containers/volumes do teste, o home e a instalação temporários.
#   Saída   : exit 0 só se todos os passos pedidos passaram. Evidência (JSON, telas, trechos de log) em
#             build/evidence/e2e/<data>-<sha>/ (EVIDENCE_DIR muda o destino): summary.json, report.txt, step-N/.
# Uso: scripts/e2e.sh [--steps 1,2,9] [--help]
#   Custo de modelo esperado: US$ 1 a 2 com o lote do passo 9 (Haiku); os passos 1-8 ficam em centavos.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

STEPS="1,2,3,4,5,6,7,8,9"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --steps) STEPS="${2:-}"; shift 2 ;;
    --steps=*) STEPS="${1#--steps=}"; shift ;;
    *) usage >&2; exit 64 ;;
  esac
done
case "$STEPS" in *[!0-9,]*|"") echo "ERRO: --steps espera números separados por vírgula (1-9)" >&2; exit 64 ;; esac
want() { case ",$STEPS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
for t in jq python3 sqlite3 docker ditto codesign open; do command -v "$t" >/dev/null 2>&1 || { echo "ERRO: falta '$t' no PATH" >&2; exit 2; }; done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/build/evidence/e2e/$(date +%Y%m%d)-$SHA}"
mkdir -p "$EVIDENCE_DIR"
BUILD_DIR="${RACKY_BUILD_DIR:-$ROOT/build/e2e}"
MODEL="${RACKY_E2E_MODEL:-haiku}"
WORK="$(mktemp -d /tmp/abe2e-XXXXXX)" || exit 2
HOME_T="$WORK/h"; SOCK="$WORK/app.sock"; INSTALL="$WORK/install"; APP="$INSTALL/Racky.app"; MACOS="$APP/Contents/MacOS"
REPO="$WORK/repo"; DB="$HOME_T/db/racky.sqlite"
mkdir -p "$HOME_T" "$INSTALL" "$REPO"; chmod 700 "$HOME_T"
REPORT="$EVIDENCE_DIR/report.txt"; RESULTS="$WORK/results.tsv"
: > "$REPORT"; : > "$RESULTS"
FAILS=0; STEP=0; STEP_T0=0; T_START=$(date +%s)
APP_PID=""; DAEMON_PIDS=""
PROFILE=""; SHELL_TID=""; CLAUDE_TID=""; SHELL_PID=""; CLAUDE_PID=""; MAIN_SESSION=""
LIGHT="e2e-light"; LIGHT_READY=0; OWNER=""
CLAUDE_PROJ_PREFIX="-private-tmp-$(basename "$WORK")"

say() { echo "$*" | tee -a "$REPORT"; }
dir() { local d="$EVIDENCE_DIR/step-$STEP"; mkdir -p "$d"; echo "$d"; }
check() { # descrição comando...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then say "  PASS  $d"; printf '%s\tPASS\t%s\n' "$STEP" "$d" >> "$RESULTS"
  else say "  FAIL  $d"; printf '%s\tFAIL\t%s\n' "$STEP" "$d" >> "$RESULTS"; FAILS=$((FAILS + 1)); fi
}
note() { say "  note  $*"; }
step_begin() { STEP="$1"; STEP_T0=$SECONDS; say; say "== $1. $2"; mkdir -p "$EVIDENCE_DIR/step-$1"; }
step_end() {
  # RACKY_E2E_PAUSE_AFTER=<passo>:<segundos> segura o ambiente vivo depois do passo, para depurar à mão (app em $WORK).
  case "${RACKY_E2E_PAUSE_AFTER:-}" in "$STEP":*) say "  pausa de ${RACKY_E2E_PAUSE_AFTER#*:} s: ctl --sock $SOCK, home $HOME_T"; sleep "${RACKY_E2E_PAUSE_AFTER#*:}" ;; esac
  printf '%s\tTIME\t%s\n' "$STEP" "$((SECONDS - STEP_T0))" >> "$RESULTS"; say "  ($((SECONDS - STEP_T0)) s)"
}

ctl() { "$APP/Contents/Helpers/racky" ctl "$@" --sock "$SOCK"; }
act() { ctl ui action "$@"; }
act_ok() { act "$@" 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; }
db() { sqlite3 -cmd ".timeout 5000" "$DB" "$1" 2>/dev/null; }
wait_for() { # segundos comando...
  local t="$1"; shift; local i=0
  while ! "$@" >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt $((t * 2)) ] || return 1; sleep 0.5; done
}
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
tree() { ctl ui tree 2>/dev/null; }
tree_has() { tree | jq -e --arg id "$1" '[.. | objects | select(.id == $id)] | length > 0' >/dev/null 2>&1; }
tree_value() { tree | jq -r --arg id "$1" '[.. | objects | select(.id == $id) | .value][0] // empty' 2>/dev/null; }
shot() { ctl screenshot --window --out "$(dir)/$1.png" >/dev/null 2>&1 || true; }

# --- terminal (ctl ui action terminal.screen / terminal.sendText) -------------------------------------------------------------
term_screen() { act terminal.screen select "$1" 2>/dev/null | jq -r '.action.message // empty'; }
term_send() { act terminal.sendText set "$(jq -cn --arg t "$1" --arg x "$2" '{terminal:$t,text:$x}')" >/dev/null 2>&1; }
# Espera texto na tela do terminal; responde sozinho ao "trust this folder" do Claude (a pasta é nova a cada execução).
term_wait() { # id regex segundos
  local id="$1" re="$2" t="$3" i=0 screen
  while [ "$i" -lt "$t" ]; do
    screen="$(term_screen "$id")"
    if echo "$screen" | grep -q "Yes, I trust this folder"; then term_send "$id" $'\e[B'; sleep 0.4; term_send "$id" $'\r'; fi
    if echo "$screen" | grep -Eq "$re"; then return 0; fi
    i=$((i + 1)); sleep 1
  done
  return 1
}
terminal_state() { db "SELECT state FROM terminal WHERE id='$1';"; }

# --- processos e Docker: só o que é nosso ----------------------------------------------------------------------------------
app_pid() { pgrep -f "$(basename "$WORK")/install/Racky.app/Contents/MacOS/Racky" | head -1; }
daemon_pid() { pgrep -f "rackyd .*--home $HOME_T" | head -1; }
child_pids() { pgrep -P "$1" 2>/dev/null; }
docker_mine() { docker ps -a --filter "label=racky.owner=$OWNER" "$@"; }
mine_ids() { docker ps -a -q --filter "label=racky.owner=$OWNER"; }
mine_names() { docker ps -a --filter "label=racky.owner=$OWNER" --format '{{.Names}}'; }
mine_running_count() { docker ps -q --filter "label=racky.owner=$OWNER" | wc -l | tr -d ' '; }
computer_ids() { db "SELECT lower(id) FROM computer;"; }
container_of() { docker ps -a -q --filter "label=racky.owner=$OWNER" --filter "label=racky.computer_name=$1" | head -1; }
volumes_clean() { [ -z "$(profile_volumes)" ]; }
profile_volumes() { local id; for id in $(computer_ids); do docker volume ls -q --filter "name=ab-prof-$id"; done; }
owner_snapshot() { # o que é do dono, só leitura
  {
    echo "app instalado:"; pgrep -fl "/Applications/Racky.app/Contents/MacOS" | sed -E "s/^[0-9]+ //" | sort -u
    echo "daemons fora do teste:"; pgrep -fl "rackyd" | grep -v -- "--home $HOME_T" | sed -E "s/^[0-9]+ //" | sort -u
    echo "job do launchd:"; launchctl print "gui/$(id -u)/app.racky.ptyd.v1" 2>/dev/null | grep -E "^\s(state|program) = " | sort
    echo "containers:"; docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' | grep -v "$(mine_ids | head -50 | tr '\n' '|' | sed 's/|$//;s/^$/__none__/')" | awk '{print $1, $2}' | sort
    echo "volumes:"; docker volume ls -q | sort
  }
}

cleanup() {
  local rc=$?
  say; say "--- limpeza"
  if [ -S "$SOCK" ]; then ctl ui action app.quitCompletely >/dev/null 2>&1; sleep 2; fi
  local pid; pid="$(app_pid)"; [ -z "$pid" ] || { kill "$pid" 2>/dev/null; sleep 1; }
  for pid in $(pgrep -f "rackyd .*--home $HOME_T"); do kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in $(pgrep -f "$(basename "$WORK")/install/Racky.app"; pgrep -f "rackyd .*--home $HOME_T"); do kill -9 "$pid" 2>/dev/null; done
  # Docker: containers com o owner do teste e os volumes dos computadores do banco do teste (nada além disso).
  if [ -n "$OWNER" ]; then
    local ids vols; ids="$(mine_ids)"
    [ -z "$ids" ] || { say "removendo containers do teste: $(echo $ids)"; docker rm -f $ids >/dev/null 2>&1; }
    vols="$(profile_volumes)"
    [ -z "$vols" ] || { say "removendo volumes do teste: $(echo $vols)"; docker volume rm $vols >/dev/null 2>&1; }
    say "sobrou do teste no Docker: containers=$(mine_ids | wc -l | tr -d ' ') volumes=$(profile_volumes | wc -l | tr -d ' ')"
  fi
  # Transcrições do Claude desta execução (o caminho do repositório temporário é único).
  rm -rf "$HOME/.claude/projects/$CLAUDE_PROJ_PREFIX"-* 2>/dev/null
  if [ -f "$EVIDENCE_DIR/owner-before.txt" ]; then
    owner_snapshot > "$EVIDENCE_DIR/owner-after.txt" 2>&1
    # Nada do que existia antes pode ter sumido (o dono pode criar coisas novas durante a execução; isso não é conosco).
    local gone; gone="$(comm -23 <(sort "$EVIDENCE_DIR/owner-before.txt") <(sort "$EVIDENCE_DIR/owner-after.txt") | grep -vE '^(app instalado|daemons fora do teste|job do launchd|containers|volumes):$')"
    if [ -z "$gone" ]; then say "o que é do dono segue lá (nenhum processo, job, container ou volume de antes sumiu)"
    else say "FAIL  algo do dono sumiu:"; echo "$gone" | tee -a "$REPORT"; FAILS=$((FAILS + 1)); printf '0\tFAIL\tdono intocado\n' >> "$RESULTS"; fi
  fi
  rm -rf "$WORK/install" "$WORK/h" "$WORK/repo" "$WORK/app.sock"
  python3 -I - "$RESULTS" "$EVIDENCE_DIR/summary.json" "$STEPS" "$SHA" <<'PY'
import json, sys, datetime
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
steps = {}
for step, kind, text in rows:
    s = steps.setdefault(step, {"checks": [], "seconds": None})
    if kind == "TIME": s["seconds"] = int(text)
    else: s["checks"].append({"pass": kind == "PASS", "check": text})
for s in steps.values(): s["pass"] = all(c["pass"] for c in s["checks"]) and bool(s["checks"])
total = all(s["pass"] for k, s in steps.items() if k != "0") and not steps.get("0", {"pass": True})["pass"] is False
json.dump({"date": datetime.datetime.now().isoformat(timespec="seconds"), "sha": sys.argv[4], "steps_requested": sys.argv[3], "pass": total, "steps": steps}, open(sys.argv[2], "w"), indent=2)
PY
  rm -rf "$WORK"
  say "RESULTADO: $([ "$FAILS" -eq 0 ] && [ "$rc" -eq 0 ] && echo OK || echo "$FAILS falha(s)") (evidência: $EVIDENCE_DIR)"
  [ "$FAILS" -eq 0 ] && [ "$rc" -eq 0 ]
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ----------------------------------------------------------------------------------------------------------------------------
say "e2e $(date -u +%Y-%m-%dT%H:%M:%SZ) sha=$SHA passos=$STEPS work=$WORK"
say "macOS $(sw_vers -productVersion) ($(uname -m)); docker VM: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes' 2>&1)"
docker info >/dev/null 2>&1 || { say "ERRO: Docker não está rodando"; exit 2; }
command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] || { say "ERRO: 'claude' não encontrado"; exit 2; }
owner_snapshot > "$EVIDENCE_DIR/owner-before.txt" 2>&1
docker network ls --format '{{.Name}}' | sort > "$WORK/networks-before.txt"

# Label do dono dos containers do app de teste: "racky-" + FNV-1a de 32 bits do RACKY_HOME (AppEnvironment.computerOwner).
OWNER="racky-$(python3 -I - "$HOME_T" <<'PY'
import sys
h = 2166136261
for b in sys.argv[1].encode():
    h = ((h ^ b) * 16777619) & 0xFFFFFFFF
print("%08x" % h)
PY
)"
say "owner dos containers do teste: $OWNER (o do dono é racky)"

launch_app() {
  open -g -n --env "RACKY_HOME=$HOME_T" --env "RACKY_APP_SOCK=$SOCK" --env RACKY_AUTOMATION=1 --env RACKY_SKIP_ONBOARDING=1 "$APP"
}

ensure_app() { # constrói, instala em diretório temporário e abre o app de teste, uma vez
  [ -z "$APP_PID" ] || return 0
  local src="${RACKY_E2E_APP:-}"
  if [ -z "$src" ]; then
    say "build: scripts/build.sh (RACKY_BUILD_DIR=$BUILD_DIR)"
    RACKY_BUILD_DIR="$BUILD_DIR" "$ROOT/scripts/build.sh" > "$EVIDENCE_DIR/build.log" 2>&1 || { tail -20 "$EVIDENCE_DIR/build.log" | tee -a "$REPORT"; return 1; }
    src="$BUILD_DIR/Racky.app"
  fi
  [ -d "$src" ] || { say "ERRO: app não encontrado em $src"; return 1; }
  ditto "$src" "$APP" || return 1
  codesign --verify --strict "$APP" > "$EVIDENCE_DIR/codesign.txt" 2>&1
  launch_app
  wait_for 30 sh -c "[ -S '$SOCK' ] && '$APP/Contents/Helpers/racky' ctl state --sock '$SOCK' >/dev/null 2>&1" || { say "ERRO: o app de teste não subiu"; return 1; }
  APP_PID="$(app_pid)"
  sleep 2
  DAEMON_PIDS="$(daemon_pid)"
  return 0
}

ensure_project() { # projeto = repositório git temporário; perfil do Claude com o modelo barato
  [ -z "$PROFILE" ] || return 0
  ensure_app || return 1
  ( cd "$REPO" && git init -q && echo "e2e repo" > README.md && git add . && git -c user.email=e2e@racky.local -c user.name=e2e commit -qm init ) || return 1
  act_ok project.add set "$REPO" || return 1
  wait_for 15 sh -c "[ -n \"\$(sqlite3 '$DB' \"SELECT id FROM session LIMIT 1\")\" ]" || return 1
  MAIN_SESSION="$(db "SELECT id FROM session ORDER BY created_at LIMIT 1;")"
  local created
  created="$(act settings.agents.profileDuplicate select A0000000-0000-4000-8000-000000000001 | jq -r '.action.message // empty')"
  [ -n "$created" ] || return 1
  act_ok settings.agents.profileModel set "$MODEL" || return 1
  act_ok settings.agents.profileName set "Claude e2e $MODEL" || return 1
  PROFILE="$created"
  return 0
}

# Cria uma sessão pelo composer (mesmo caminho do clique) e devolve o ID do terminal do Claude em $NEW_TID.
NEW_TID=""
new_claude_session() { # modo(off|ask|full) prompt
  local before after
  before="$(db "SELECT count(*) FROM terminal WHERE provider='claude';")"
  act_ok session.new || return 1
  wait_for 10 tree_has overlay.composer || return 1
  act_ok composer.setWhere select mainCheckout || return 1
  act_ok composer.setProfile select "$PROFILE" || return 1
  act_ok composer.setSubagentComputers select "$1" || return 1
  act_ok composer.setPrompt set "$2" || return 1
  act_ok composer.submit || return 1
  wait_for 30 sh -c "[ \"\$(sqlite3 '$DB' \"SELECT count(*) FROM terminal WHERE provider='claude'\")\" -gt '${before:-0}' ]" || return 1
  NEW_TID="$(db "SELECT id FROM terminal WHERE provider='claude' ORDER BY created_at DESC LIMIT 1;")"
  [ -n "$NEW_TID" ]
}

# ============================================================================================================================
# 1. build, instalação temporária e isolamento
# ============================================================================================================================
if want 1; then
  step_begin 1 "build, instalação temporária e isolamento"
  ensure_app; rc=$?
  check "scripts/build.sh e instalação temporária ($INSTALL) sem tocar em /Applications" test "$rc" -eq 0 -a -x "$APP/Contents/Helpers/racky"
  check "assinatura do bundle copiado válida" codesign --verify --strict "$APP"
  check "app de teste no ar, respondendo ao ctl (pid ${APP_PID:-?})" sh -c "'$APP/Contents/Helpers/racky' ctl state --sock '$SOCK' | jq -e '.ok == true and .state.automation == true'"
  ctl state > "$(dir)/state.json" 2>&1
  check "dados isolados em RACKY_HOME temporário (banco em $DB)" test -f "$DB"
  check "o app de teste não é o do dono (processo vem do diretório temporário)" sh -c "ps -o command= -p ${APP_PID:-0} | grep -q '$(basename "$WORK")/install'"
  check "daemon filho próprio (--home do teste), não o launchd do dono" test -n "$DAEMON_PIDS" -o -z "$(pgrep -f 'ptyd.v1' | head -1)"
  check "owner dos containers do teste difere do do dono" test "$OWNER" != "racky"
  ensure_project; rc=$?
  check "projeto criado (repositório git temporário) e perfil Claude com modelo '$MODEL'" test "$rc" -eq 0 -a -n "$PROFILE"
  db "SELECT id,name,kind FROM project;" > "$(dir)/project.txt"
  db "SELECT id,name,provider,model FROM launch_profile WHERE id='$PROFILE';" >> "$(dir)/project.txt"
  shot app-first-window
  step_end
fi

# ============================================================================================================================
# 2. projeto, shell e Claude
# ============================================================================================================================
SHELL_MARK="E2E_SHELL_$RANDOM"
ensure_terminals() { # shell + Claude (modelo barato, subagentes off) com texto marcado na tela
  [ -z "$CLAUDE_TID" ] || return 0
  ensure_project || return 1
  act_ok session.select select "$MAIN_SESSION" || return 1
  sleep 1
  act_ok tab.newTerminal || return 1
  wait_for 20 sh -c "[ -n \"\$(sqlite3 '$DB' \"SELECT id FROM terminal WHERE provider='shell'\")\" ]" || return 1
  SHELL_TID="$(db "SELECT id FROM terminal WHERE provider='shell' ORDER BY created_at DESC LIMIT 1;")"
  wait_for 20 sh -c "[ \"\$(sqlite3 '$DB' \"SELECT state FROM terminal WHERE id='$SHELL_TID'\")\" = running ]" || return 1
  sleep 2
  term_send "$SHELL_TID" "echo $SHELL_MARK; cd $REPO && pwd"$'\r'
  new_claude_session off "Reply with exactly the two letters PO immediately followed by NG, uppercase, and nothing else." || return 1
  CLAUDE_TID="$NEW_TID"
  return 0
}
ALL_DAEMON_PIDS=""
refresh_pids() {
  DAEMON_PIDS="$(daemon_pid)"
  case " $ALL_DAEMON_PIDS " in *" $DAEMON_PIDS "*) ;; *) [ -z "$DAEMON_PIDS" ] || ALL_DAEMON_PIDS="$ALL_DAEMON_PIDS $DAEMON_PIDS" ;; esac
  SHELL_PID="$(child_pids "$DAEMON_PIDS" | while read -r p; do ps -o command= -p "$p" | grep -q '^/bin/zsh' && echo "$p"; done | head -1)"
  CLAUDE_PID="$(child_pids "$DAEMON_PIDS" | while read -r p; do ps -o command= -p "$p" | grep -q -- '--session-id' && echo "$p"; done | head -1)"
}

if want 2; then
  step_begin 2 "projeto, shell e Claude"
  ensure_terminals; rc=$?
  check "shell e Claude abertos pela UI (sessão no projeto temporário)" test "$rc" -eq 0 -a -n "$SHELL_TID" -a -n "$CLAUDE_TID"
  if [ "$rc" -eq 0 ]; then
    check "shell responde (marca $SHELL_MARK na tela)" term_wait "$SHELL_TID" "^$SHELL_MARK\$" 30
    check "Claude responde (modelo $MODEL)" term_wait "$CLAUDE_TID" "^⏺ PONG" 120
    refresh_pids
    check "terminais 'running' no banco" test "$(db "SELECT count(*) FROM terminal WHERE state='running' AND id IN ('$SHELL_TID','$CLAUDE_TID');")" = 2
    check "PTYs são filhos do daemon do teste (pid ${DAEMON_PIDS:-?}; shell ${SHELL_PID:-?}, Claude ${CLAUDE_PID:-?})" test -n "$DAEMON_PIDS" -a -n "$SHELL_PID" -a -n "$CLAUDE_PID"
    check "o daemon do teste não é o do dono (ptyd.v1 do launchd)" sh -c "! ps -o command= -p ${DAEMON_PIDS:-0} | grep -q -- '--launchd'"
    term_screen "$SHELL_TID" > "$(dir)/shell-screen.txt"; term_screen "$CLAUDE_TID" > "$(dir)/claude-screen.txt"
    db "SELECT id,provider,state,pty_session_id,native_conversation_id FROM terminal;" > "$(dir)/terminals.txt"
    shot session-claude
  fi
  step_end
fi

# ============================================================================================================================
# 3. ⌘Q com Keep Running e reabrir
# ============================================================================================================================
if want 3; then
  step_begin 3 "Keep Running e reabrir: mesmos PTYs e buffer"
  ensure_terminals || note "falha ao preparar os terminais"
  term_wait "$SHELL_TID" "^$SHELL_MARK\$" 30 >/dev/null 2>&1; term_wait "$CLAUDE_TID" "^⏺ PONG" 120 >/dev/null 2>&1
  refresh_pids
  term_screen "$SHELL_TID" > "$(dir)/shell-before.txt"; term_screen "$CLAUDE_TID" > "$(dir)/claude-before.txt"
  APP_BEFORE="$(app_pid)"; D_BEFORE="$DAEMON_PIDS"; SH_BEFORE="$SHELL_PID"; CL_BEFORE="$CLAUDE_PID"
  act app.quit > "$(dir)/quit.json" 2>&1
  check "⌘Q com agente vivo abre o overlay de saída (sem NSAlert)" wait_for 10 tree_has overlay.confirmQuit
  ctl ui tree > "$(dir)/ui-tree-overlay.json" 2>&1; shot quit-overlay
  act dialog.quit.keepRunning > "$(dir)/keep-running.json" 2>&1
  sleep 2
  check "Keep Running: o app segue vivo (mesmo pid $APP_BEFORE)" test "$(app_pid)" = "$APP_BEFORE"
  check "Keep Running: o daemon e os PTYs seguem (mesmos pids)" sh -c "[ '$(daemon_pid)' = '$D_BEFORE' ] && kill -0 $SH_BEFORE && kill -0 $CL_BEFORE"
  ASN="$(lsappinfo find pid="$APP_BEFORE" 2>/dev/null | head -1)"
  check "Keep Running: sem ícone no Dock (accessory)" sh -c "lsappinfo info -only applicationtype '$ASN' | grep -qi 'UIElement\\|BackgroundOnly'"
  check "o ctl segue respondendo em segundo plano" sh -c "'$APP/Contents/Helpers/racky' ctl state --sock '$SOCK' | jq -e .ok"
  act app.openMainWindow > "$(dir)/reopen.json" 2>&1
  sleep 3
  refresh_pids
  check "reabrir: mesmo processo do app, daemon e PTYs (shell $SHELL_PID, Claude $CLAUDE_PID)" test "$(app_pid)" = "$APP_BEFORE" -a "$DAEMON_PIDS" = "$D_BEFORE" -a "$SHELL_PID" = "$SH_BEFORE" -a "$CLAUDE_PID" = "$CL_BEFORE"
  act_ok session.select select "$MAIN_SESSION"; sleep 1
  check "reabrir: o pane do shell voltou na árvore" wait_for 10 tree_has "pane.$SHELL_TID"
  term_screen "$SHELL_TID" > "$(dir)/shell-after.txt"; term_screen "$CLAUDE_TID" > "$(dir)/claude-after.txt"
  check "buffer do shell restaurado (marca $SHELL_MARK ainda na tela)" grep -q "^$SHELL_MARK\$" "$(dir)/shell-after.txt"
  check "buffer do Claude restaurado (PONG ainda na tela)" grep -q "^⏺ PONG" "$(dir)/claude-after.txt"
  check "tela do shell idêntica antes e depois" diff -q "$(dir)/shell-before.txt" "$(dir)/shell-after.txt"
  shot after-reopen
  step_end
fi

# ============================================================================================================================
# 4. subagente leve com box_claim
# ============================================================================================================================
LIGHT_PROMPT="Reserve exactly ONE computer named $LIGHT with boxes_reserve (display headless, batch e2e). Spawn its worker in the background with this brief. COMPUTER: $LIGHT. TASK: call box_claim for it, open https://example.com in the browser, call box_status once, then call help_request(kind=other, reason='e2e: waiting for the human') and call help_wait on it up to 8 times. If help_wait ever returns taken_over do NOT stop: repeat up to 4 times {exec the shell command sleep 10, then box_status} (stop early when the lease is back with the agent). MANDATORY ENDING in every case (help still open, timed out, resolved, declined, taken over): call help_cancel if the request is still open, then call box_release, and only then finish. Never finish without calling box_release. WHAT WE ALREADY KNOW: nothing. OUTPUT: no result needed. After the worker finishes, reply with the single word DONE-LIGHT."
LIGHT_TID=""
approve_computers() { # Ask: aprova o pedido de computadores que aparecer (card do pane ou Inbox)
  local id
  id="$(tree | jq -r '[.. | objects | select((.action // "") == "computer.allowRequestSession" or (.action // "") == "computer.allowRequest") | .id][0] // empty')"
  [ -n "$id" ] || return 1
  act "$id" press >/dev/null 2>&1
}
ensure_light() {
  [ "$LIGHT_READY" -eq 0 ] || return 0
  ensure_project || return 1
  new_claude_session ask "$LIGHT_PROMPT" || return 1
  LIGHT_TID="$NEW_TID"
  local i=0
  while [ "$i" -lt 150 ]; do   # trust da pasta, depois o pedido de computadores (Ask)
    term_wait "$LIGHT_TID" "NEVER-MATCHES-ONLY-TRUST" 1 >/dev/null 2>&1
    [ -z "$(container_of $LIGHT)" ] || break
    approve_computers
    i=$((i + 1))
  done
  [ -n "$(container_of $LIGHT)" ] || return 1
  wait_for 180 sh -c "[ \"\$(sqlite3 '$DB' \"SELECT state FROM computer WHERE name='$LIGHT'\")\" = in_use ]" || return 1
  LIGHT_READY=1
  return 0
}
save_secrets() { # guarda os segredos dos computadores vivos (token da API e egress.json, 0400 do usuário egress) para o passo 8
  mkdir -p "$WORK/tokens"; chmod 700 "$WORK/tokens"
  local c f
  for c in $(mine_ids); do
    for f in token egress.json; do docker exec -u egress "$c" cat "/run/racky/$f" > "$WORK/tokens/$c-$f" 2>/dev/null || rm -f "$WORK/tokens/$c-$f"; done
  done
}

capture_containers() { # inspect, logs e segredos dos computadores vivos (o container some depois; o vazamento tem que ser visto antes)
  mkdir -p "$WORK/capture"
  local c
  for c in $(mine_ids); do
    docker inspect "$c" > "$WORK/capture/inspect-$c.json" 2>&1
    docker logs "$c" > "$WORK/capture/logs-$c.txt" 2>&1
    [ -s "$WORK/tokens/$c-token" ] || save_secrets
  done
}
leak_scan() { # grava $(dir)/leaks.txt; os valores dos segredos nunca vão para a evidência
  capture_containers
  : > "$WORK/secrets.txt"
  local f
  for f in "$WORK"/tokens/*; do
    [ -f "$f" ] || continue
    jq -r '.. | strings | select(length >= 16)' "$f" 2>/dev/null >> "$WORK/secrets.txt"
    tr -d '\n' < "$f" | awk 'length($0) >= 16 && length($0) < 200' >> "$WORK/secrets.txt"; echo >> "$WORK/secrets.txt"
  done
  for f in "$HOME_T"/run/launch/*/*.json; do [ -f "$f" ] && jq -r '.. | strings | select(test("^[0-9a-f]{32,}$"))' "$f" 2>/dev/null >> "$WORK/secrets.txt"; done
  sort -u "$WORK/secrets.txt" | grep -v '^$' > "$WORK/secrets.sorted"
  NSEC="$(wc -l < "$WORK/secrets.sorted" | tr -d ' ')"
  note "$NSEC segredos conhecidos (token e egress.json dos computadores, capabilities dos MCP)"
  cat "$WORK"/capture/*.json "$WORK"/capture/*.txt > "$WORK/haystack-docker.txt" 2>/dev/null
  local pred="processID == ${APP_PID:-999999}" p
  for p in $ALL_DAEMON_PIDS $(daemon_pid); do pred="$pred OR processID == $p"; done
  log show --start "$(date -r "$T_START" '+%Y-%m-%d %H:%M:%S')" --info --debug --predicate "$pred" 2>/dev/null > "$WORK/haystack-oslog.txt"
  { for f in "$HOME_T"/sessions/*/output.log; do strings "$f"; done; find "$HOME_T" -name '*.log' -not -path '*/sessions/*' -exec cat {} + ; find "$HOME_T/computers/runs" -path '*/logs/*' -type f -exec cat {} + ; } > "$WORK/haystack-files.txt" 2>/dev/null
  : > "$(dir)/leaks.txt"
  local secret h
  while IFS= read -r secret; do
    for h in docker oslog files; do
      grep -qF -- "$secret" "$WORK/haystack-$h.txt" && echo "VAZOU: segredo de ${#secret} caracteres em $h" >> "$(dir)/leaks.txt"
    done
  done < "$WORK/secrets.sorted"
  say "  escaneado: docker inspect+logs ($(ls "$WORK"/capture | wc -l | tr -d ' ') capturas, $(wc -l < "$WORK/haystack-docker.txt" | tr -d ' ') linhas), os_log do app e do daemon ($(wc -l < "$WORK/haystack-oslog.txt" | tr -d ' ') linhas), logs em arquivo ($(wc -l < "$WORK/haystack-files.txt" | tr -d ' ') linhas)"
  check "há segredos para procurar e containers capturados" test "$NSEC" -gt 0 -a "$(ls "$WORK"/capture 2>/dev/null | wc -l | tr -d ' ')" -gt 0
  check "nenhum segredo em docker inspect nem nos logs do container" sh -c "! grep -q ' docker' '$(dir)/leaks.txt'"
  check "nenhum segredo no os_log do app e do daemon" sh -c "! grep -q ' oslog' '$(dir)/leaks.txt'"
  check "nenhum segredo nos logs em arquivo (terminais, logs do computador)" sh -c "! grep -q ' files' '$(dir)/leaks.txt'"
}

if want 4; then
  step_begin 4 "subagente leve com box_claim: container, rede, iptables, VNC, um quadro"
  ensure_light; rc=$?
  check "Claude pediu o computador $LIGHT (Ask aprovado) e o subagente fez box_claim (estado in_use)" test "$rc" -eq 0
  CID="$(container_of $LIGHT)"
  save_secrets
  if [ -n "$CID" ]; then
    docker inspect "$CID" > "$(dir)/docker-inspect.json" 2>&1
    check "1 container 'racky-computer' em execução, com os labels do teste (owner $OWNER, role computer, efêmero)" sh -c "jq -e --arg o '$OWNER' '.[0] | .State.Running == true and .Config.Labels[\"racky.owner\"] == \$o and .Config.Labels[\"racky.role\"] == \"computer\" and .Config.Labels[\"racky.ephemeral\"] == \"true\"' '$(dir)/docker-inspect.json'"
    check "saudável (healthcheck)" wait_for 60 sh -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $CID)\" = healthy ]"
    check "rede: só a bridge padrão, sem rede extra por computador (P24; não existe rede 'internal' por computador)" sh -c "jq -e '.[0].NetworkSettings.Networks | keys == [\"bridge\"]' '$(dir)/docker-inspect.json'"
    check "portas publicadas só em 127.0.0.1" sh -c "jq -e '[.[0].NetworkSettings.Ports[]?[]?.HostIp] | length > 0 and all(. == \"127.0.0.1\")' '$(dir)/docker-inspect.json'"
    check "container sem privilégios (não privileged)" sh -c "jq -e '.[0].HostConfig.Privileged == false' '$(dir)/docker-inspect.json'"
    docker exec -u root "$CID" sh -c 'iptables -S OUTPUT 2>&1 || iptables-nft -S OUTPUT 2>&1' > "$(dir)/iptables.txt" 2>&1
    check "iptables por uid: o agente só sai pelo proxy local" grep -Eq "uid-owner (10001|agent)" "$(dir)/iptables.txt"
    HPORT="$(docker port "$CID" 8790/tcp | head -1 | sed 's/.*://')"
    curl -s --max-time 10 "http://127.0.0.1:$HPORT/v1/health" > "$(dir)/health.json" 2>&1
    check "API do computador (porta publicada em loopback): /v1/health ok" jq -e '.ok == true' "$(dir)/health.json"
    docker exec -i "$CID" python3 - < "$ROOT/scripts/e2e/vnc_frame.py" > "$(dir)/vnc-frame.png" 2> "$(dir)/vnc-frame.json"
    check "VNC: handshake RFB e um quadro de verdade ($(tr -d '\n' < "$(dir)/vnc-frame.json" | cut -c1-120))" sh -c "[ \$(stat -f %z '$(dir)/vnc-frame.png') -gt 1000 ] && file '$(dir)/vnc-frame.png' | grep -q PNG"
    docker exec -u root "$CID" sh -c 'curl -s -m 15 -o /dev/null -w "%{http_code}" -x http://127.0.0.1:3128 https://example.com' > "$(dir)/proxy-example.txt" 2>&1
    check "egress: example.com abre pelo proxy do computador" grep -q "^200" "$(dir)/proxy-example.txt"
    docker exec -u agent "$CID" sh -c 'curl -s -m 8 --noproxy "*" -o /dev/null -w "%{http_code}" https://example.com; echo " rc=$?"' > "$(dir)/direct-egress.txt" 2>&1
    check "egress: o usuário agent não sai direto, a regra por uid bloqueia" grep -Eq "^000|rc=(6|7|28|35|56)" "$(dir)/direct-egress.txt"
    ls -laR "$HOME_T"/computers/boxes > "$(dir)/secret-dirs-modes.txt" 2>&1
  fi
  db "SELECT name,mode,display,state,created_at FROM computer;" > "$(dir)/computer.txt"
  LOGS="$(ls -d "$HOME_T"/computers/runs/*/"$LIGHT"/logs 2>/dev/null | head -1)"
  [ -z "$LOGS" ] || { cp "$LOGS/timeline.md" "$(dir)/timeline.md" 2>/dev/null; tail -5 "$LOGS/requests.jsonl" > "$(dir)/requests-tail.jsonl" 2>/dev/null; }
  check "o subagente navegou (example.com no log de requisições do computador)" sh -c "grep -q example.com '$LOGS/requests.jsonl'"
  term_screen "$LIGHT_TID" > "$(dir)/parent-screen.txt"
  shot computers
  capture_containers
  [ -z "${RACKY_E2E_PAUSE:-}" ] || { note "pausa de $RACKY_E2E_PAUSE s (RACKY_E2E_PAUSE) com o computador no ar: container $CID, home $HOME_T"; sleep "$RACKY_E2E_PAUSE"; }
  step_end
fi

# ============================================================================================================================
# 5. Take Over e Hand Back
# ============================================================================================================================
control_of() { tree_value "viewer.$LIGHT.controlFrame"; }
control_is() { [ "$(control_of)" = "$1" ]; }
if want 5; then
  step_begin 5 "Take Over (imediato) e Hand Back"
  ensure_light || note "computador de teste não subiu"
  act_ok computer.openViewer select "$LIGHT"; sleep 2
  check "viewer do $LIGHT aberto (viewer.$LIGHT na árvore)" wait_for 15 tree_has "viewer.$LIGHT"
  check "controle começa com o agente (controlFrame=agent)" test "$(control_of)" = agent
  shot viewer-agent
  T0=$(python3 -c 'import time; print(time.time())')
  act computer.takeOver select "$LIGHT" > "$(dir)/take-over.json" 2>&1
  wait_for 10 control_is human
  T1=$(python3 -c 'import time; print(time.time())')
  note "Take Over levou $(python3 -c "print(round($T1 - $T0, 2))") s"
  check "Take Over é imediato (< 3 s) e o controle passa ao humano" test "$(python3 -c "print(1 if $T1 - $T0 < 3 else 0)")" = 1 -a "$(control_of)" = human
  check "o botão vira Hand Back" tree_has "viewer.$LIGHT.handBack"
  shot viewer-human
  sleep 2
  act computer.handBack select "$LIGHT" > "$(dir)/hand-back-1.json" 2>&1   # abre o painel da nota
  sleep 1
  ctl ui tree > "$(dir)/ui-tree-handback.json" 2>&1
  check "Hand Back abre o painel da nota (viewer.$LIGHT.handBack.confirm)" tree_has "viewer.$LIGHT.handBack.confirm"
  shot viewer-handback-note
  act computer.handBack select confirm > "$(dir)/hand-back-2.json" 2>&1    # confirma
  check "Hand Back devolve o controle ao agente (controlFrame=agent)" wait_for 20 control_is agent
  shot viewer-handed-back
  capture_containers
  step_end
fi

# ============================================================================================================================
# 6. computador efêmero removido
# ============================================================================================================================
if want 6; then
  step_begin 6 "computador efêmero removido (container e volume)"
  ensure_light || note "computador de teste não subiu"
  CID6="$(container_of $LIGHT)"; CUUID="$(db "SELECT lower(id) FROM computer WHERE name='$LIGHT';")"
  note "container $CID6, computador $CUUID, volume ab-prof-$CUUID"
  check "antes: o volume de perfil existe" test -n "$(docker volume ls -q --filter "name=ab-prof-$CUUID")"
  capture_containers
  # o subagente solta o computador quando recupera o controle (ou, sem passo 5, quando a ajuda expira)
  wait_for 420 sh -c "[ -z \"\$(docker ps -a -q --filter label=racky.owner=$OWNER --filter label=racky.computer_name=$LIGHT)\" ]"; rc=$?
  check "container removido depois do subagente soltar (box_release / SubagentStop)" test "$rc" -eq 0
  check "estado 'removed' no banco" wait_for 30 sh -c "[ \"\$(sqlite3 '$DB' \"SELECT state FROM computer WHERE name='$LIGHT'\")\" = removed ]"
  check "volume de perfil efêmero removido" wait_for 30 sh -c "[ -z \"\$(docker volume ls -q --filter name=ab-prof-$CUUID)\" ]"
  check "nenhum container nem volume do teste sobrou" test -z "$(mine_ids)" -a -z "$(profile_volumes)"
  db "SELECT name,state,removed_at FROM computer;" > "$(dir)/computer.txt"
  docker network ls --format '{{.Name}}' | sort > "$(dir)/networks.txt"
  term_wait "$LIGHT_TID" "DONE-LIGHT" 120 >/dev/null 2>&1; term_screen "$LIGHT_TID" > "$(dir)/parent-screen.txt"
  shot after-release
  LIGHT_READY=0
  step_end
fi

# ============================================================================================================================
# 7. daemon morto: banner, interrupted, Resume
# ============================================================================================================================
if want 7; then
  step_begin 7 "daemon morto (kill -9): banner, interrupted e Resume"
  ensure_terminals || note "falha ao preparar os terminais"
  term_wait "$CLAUDE_TID" "^⏺ PONG" 120 >/dev/null 2>&1
  CLAUDE_SESSION="$(db "SELECT t.session_id FROM tab t JOIN terminal te ON te.tab_id = t.id WHERE te.id='$CLAUDE_TID';")"
  act_ok session.select select "$CLAUDE_SESSION"; sleep 1
  refresh_pids
  D7="$DAEMON_PIDS"
  note "matando o daemon do teste $D7 (kill -9; o daemon do dono é outro processo)"
  ps -o pid,command -p "$D7" > "$(dir)/daemon-killed.txt"
  kill -9 "$D7"
  check "terminais viram 'interrupted' no banco" wait_for 30 sh -c "[ \"\$(sqlite3 '$DB' \"SELECT count(*) FROM terminal WHERE state='running'\")\" = 0 ]"
  check "banner da janela 'Background agents stopped unexpectedly' (window.daemonBanner)" wait_for 20 tree_has window.daemonBanner
  ctl ui tree > "$(dir)/ui-tree-after-kill.json" 2>&1
  shot daemon-killed
  check "o pane do Claude mostra 'interrupted' e [Resume]" sh -c "jq -e '[.. | objects | select(.id == \"pane.$CLAUDE_TID.interrupted\")] | length > 0 and ([.. | objects | select(.id == \"pane.$CLAUDE_TID.interrupted.resume\")] | length > 0)' '$(dir)/ui-tree-after-kill.json'"
  db "SELECT id,provider,state,native_conversation_id FROM terminal;" > "$(dir)/terminals-after-kill.txt"
  act terminal.resume select "$CLAUDE_TID" > "$(dir)/resume.json" 2>&1
  check "Resume relança o Claude (terminal 'running')" wait_for 60 sh -c "[ \"\$(sqlite3 '$DB' \"SELECT state FROM terminal WHERE id='$CLAUDE_TID'\")\" = running ]"
  check "o daemon voltou por ativação (pid novo, diferente de $D7)" wait_for 30 sh -c "[ -n \"\$(pgrep -f 'rackyd .*--home $HOME_T')\" ] && [ \"\$(pgrep -f 'rackyd .*--home $HOME_T' | head -1)\" != '$D7' ]"
  check "a conversa anterior aparece no Claude retomado (PONG)" term_wait "$CLAUDE_TID" "PONG" 90
  term_screen "$CLAUDE_TID" > "$(dir)/claude-resumed.txt"
  shot resumed
  refresh_pids
  step_end
fi

# ============================================================================================================================
# 8. nenhum token em docker inspect nem nos logs
# ============================================================================================================================
if want 8; then
  step_begin 8 "nenhum segredo em docker inspect nem nos logs"
  [ -n "$(ls "$WORK/capture" 2>/dev/null)" ] || { ensure_light || note "computador de teste não subiu"; }
  leak_scan
  step_end
fi

# ============================================================================================================================
# 9. lote de 10 crawlers ("Subagent computers" = full)
# ============================================================================================================================
BATCH_COUNTRIES="Chile Norway Japan Kenya Peru Iceland Vietnam Portugal Morocco New_Zealand"
batch_prompt() {
  local i=0 c n list=""
  for c in $BATCH_COUNTRIES; do i=$((i + 1)); n="$(printf 'wiki-%02d' "$i")"; list="$list $n=$c;"; done
  echo "Run a batch of exactly 10 crawlers, each on its own computer. Call boxes_reserve ONCE with names [wiki-01 ... wiki-10] (display headless, batch e2e-crawlers). Then spawn all 10 workers in ONE message, in the background, one per computer, using the worker returned for each. Brief for each worker: COMPUTER: <its name>. TASK: browser_open https://en.wikipedia.org/wiki/<COUNTRY>, browser_read the page, then call result_submit with result {url, title (the article heading), first_paragraph (the first non-empty paragraph of the article, at least 80 characters)} and evidence {\"/title\": [<id>], \"/first_paragraph\": [<id>]} where <id> is the request id of the page load (shown in the browser_open result, or find it with reqlog_query). If the validation reports cited_missing, fix the citation and resubmit once. Then call box_release. WHAT WE ALREADY KNOW: nothing. OUTPUT: /work/result.json as described. Computer to country mapping:$list (underscores are spaces in the URL). When all 10 workers have finished, reply with E2E-BATCH-DONE and a one-line table."
}
# Custo estimado a partir das transcrições do Claude desta execução (pai + subagentes). Preço por milhão de tokens configurável:
# RACKY_E2E_PRICE="entrada,saída,escrita-de-cache,leitura-de-cache" (padrão: faixa Haiku, 1 / 5 / 1,25 / 0,10).
claude_cost() { # saída JSON em stdout
  python3 -I - "$HOME/.claude/projects" "$CLAUDE_PROJ_PREFIX" "${RACKY_E2E_PRICE:-1,5,1.25,0.10}" <<'PY'
import glob, json, os, sys
root, prefix, price = sys.argv[1], sys.argv[2], [float(x) for x in sys.argv[3].split(",")]
tot = {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0}
msgs, files = {}, 0
for f in glob.glob(os.path.join(root, prefix + "-*", "**", "*.jsonl"), recursive=True) + glob.glob(os.path.join(root, prefix + "*", "*.jsonl")):
    files += 1
    for line in open(f, errors="replace"):
        try: d = json.loads(line)
        except ValueError: continue
        m = d.get("message") or {}
        u = m.get("usage")
        if d.get("type") != "assistant" or not u: continue
        key = m.get("id") or d.get("uuid")
        cur = {"input": u.get("input_tokens", 0), "output": u.get("output_tokens", 0),
               "cache_write": u.get("cache_creation_input_tokens", 0), "cache_read": u.get("cache_read_input_tokens", 0)}
        if key not in msgs or cur["output"] >= msgs[key]["output"]: msgs[key] = cur
for v in msgs.values():
    for k in tot: tot[k] += v[k]
cost = (tot["input"] * price[0] + tot["output"] * price[1] + tot["cache_write"] * price[2] + tot["cache_read"] * price[3]) / 1e6
print(json.dumps({"transcripts": files, "assistant_messages": len(msgs), "tokens": tot, "price_per_mtok": price, "estimated_cost_usd": round(cost, 3)}))
PY
}

if want 9; then
  step_begin 9 "lote de 10 crawlers (Subagent computers = full)"
  ensure_project; rc=$?
  BATCH_T0=$SECONDS
  new_claude_session full "$(batch_prompt)"; rc2=$?
  check "sessão do lote criada pelo composer (Subagent computers = full, modelo $MODEL)" test "$rc" -eq 0 -a "$rc2" -eq 0
  BATCH_TID="$NEW_TID"
  : > "$(dir)/timeline.tsv"
  PEAK=0; DONE=0; i=0; BATCH_MAX=$((${RACKY_E2E_BATCH_TIMEOUT_S:-2400}))
  SEEN=""
  while [ $((SECONDS - BATCH_T0)) -lt "$BATCH_MAX" ]; do
    [ $((i % 3)) -ne 0 ] || term_wait "$BATCH_TID" "NEVER-MATCHES-ONLY-TRUST" 1 >/dev/null 2>&1   # trust da pasta, uma vez
    running="$(mine_running_count)"; [ "$running" -le "$PEAK" ] || PEAK="$running"
    states="$(db "SELECT state||'='||count(*) FROM computer GROUP BY state;" | tr '\n' ' ')"
    created="$(db "SELECT count(*) FROM computer;")"
    printf '%s\t%s\t%s\t%s\n' "$((SECONDS - BATCH_T0))" "$running" "$created" "$states" >> "$(dir)/timeline.tsv"
    [ $((i % 5)) -ne 0 ] || capture_containers
    removed="$(db "SELECT count(*) FROM computer WHERE state='removed';")"
    if [ "${created:-0}" -ge 10 ] && [ "${removed:-0}" -ge 10 ] && [ "$running" -eq 0 ]; then DONE=1; break; fi
    i=$((i + 1)); sleep 3
  done
  BATCH_WALL=$((SECONDS - BATCH_T0))
  capture_containers
  term_wait "$BATCH_TID" "E2E-BATCH-DONE" 60 >/dev/null 2>&1
  term_screen "$BATCH_TID" > "$(dir)/parent-screen.txt"
  shot batch-end
  db "SELECT name,mode,display,state,created_at,last_used_at,removed_at FROM computer ORDER BY created_at;" > "$(dir)/computers.txt"
  check "10 computadores criados (escalonados pela memória da VM do Docker; pico de $PEAK rodando ao mesmo tempo)" test "$(db "SELECT count(DISTINCT name) FROM computer WHERE name LIKE 'wiki-%';")" = 10
  check "o lote terminou dentro do limite de $BATCH_MAX s (levou $BATCH_WALL s)" test "$DONE" -eq 1
  # resultados: result.json + validation.json de cada computador (as pastas da execução sobrevivem à remoção do container)
  OKRES=0
  for n in $(db "SELECT name FROM computer WHERE name LIKE 'wiki-%' ORDER BY name;"); do
    rdir="$(ls -d "$HOME_T"/computers/runs/*/"$n" 2>/dev/null | head -1)"
    mkdir -p "$(dir)/results/$n"
    cp "$rdir/work/result.json" "$(dir)/results/$n/result.json" 2>/dev/null
    cp "$rdir/logs/validation.json" "$(dir)/results/$n/validation.json" 2>/dev/null
    cp "$rdir/logs/timeline.md" "$(dir)/results/$n/timeline.md" 2>/dev/null
    if jq -e '(.title | type == "string" and length > 0) and (.first_paragraph | type == "string" and length >= 80) and (.url | test("wikipedia.org"))' "$(dir)/results/$n/result.json" >/dev/null 2>&1 \
       && jq -e '.summary.verified >= 2 and .summary.cited_missing == 0' "$(dir)/results/$n/validation.json" >/dev/null 2>&1; then OKRES=$((OKRES + 1))
    else note "$n: resultado ausente ou não validado (ver results/$n)"; fi
  done
  check "10 resultados enviados com result_submit e validados (título + 1º parágrafo; verified >= 2, cited_missing = 0): $OKRES de 10" test "$OKRES" -eq 10
  check "todos os computadores liberados (estado removed)" test "$(db "SELECT count(*) FROM computer WHERE name LIKE 'wiki-%' AND state<>'removed';")" = 0
  check "nenhum container do teste sobrou" wait_for 60 sh -c "[ -z \"\$(docker ps -a -q --filter label=racky.owner=$OWNER)\" ]"
  check "nenhum volume de perfil do teste sobrou" wait_for 60 volumes_clean
  docker network ls --format '{{.Name}}' | sort > "$(dir)/networks-after.txt"
  check "nenhuma rede do teste sobrou (label racky.owner=$OWNER)" test -z "$(docker network ls -q --filter label=racky.owner=$OWNER)"
  diff "$WORK/networks-before.txt" "$(dir)/networks-after.txt" > "$(dir)/networks-diff.txt" 2>&1
  claude_cost > "$(dir)/cost.json"
  COST="$(jq -r '.estimated_cost_usd' "$(dir)/cost.json" 2>/dev/null)"
  note "lote: $BATCH_WALL s de relógio, pico de $PEAK computadores simultâneos, custo estimado US\$ $COST ($(jq -c .tokens "$(dir)/cost.json" 2>/dev/null))"
  jq -n --argjson wall "$BATCH_WALL" --argjson peak "$PEAK" --argjson ok "$OKRES" --slurpfile cost "$(dir)/cost.json" --arg model "$MODEL" \
    '{wall_seconds: $wall, peak_concurrent_computers: $peak, results_validated: $ok, model: $model, cost: $cost[0]}' > "$(dir)/batch.json"
  check "custo do lote dentro do orçamento (US\$ ${RACKY_E2E_BUDGET_USD:-2}, estimado)" test "$(python3 -c "print(1 if float('${COST:-99}') <= float('${RACKY_E2E_BUDGET_USD:-2}') else 0)")" = 1
  leak_scan
  step_end
fi
