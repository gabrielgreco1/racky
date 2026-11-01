#!/usr/bin/env bash
# e2e-launchd.sh - T1-24: o daemon como LaunchAgent do launchd, ⌘Q que mantém agentes e reabertura, com o app REAL.
#
# Contrato
#   Entrada : app construído por scripts/build.sh (build/Racky/Racky.app ou RACKY_BUILD_DIR). Sem argumentos.
#   Efeitos : copia o app para /tmp, troca o bundle id e o plist do LaunchAgent por versões de TESTE
#             (bundle app.racky.mac.test<N>, label app.racky.ptyd.test-<N>, RACKY_HOME próprio em /tmp),
#             assina ad-hoc a cópia, abre-a com `open -g` e a conduz por `racky ctl`. Nunca toca no app instalado,
#             no label de produção nem em LaunchAgents de outros apps. Nunca abre Ajustes do Sistema nem pede senha.
#             No fim (sempre) fecha a cópia, desregistra o LaunchAgent de teste e apaga /tmp/abe-<N>.
#   Passos  : 1 registra e usa o socket do launchd; 2 ⌘Q com agente vivo (overlay, Keep Running) deixa app e daemon vivos;
#             3 Quit Completely e reabrir: mesmo PID do daemon e do processo do agente; 4 upgrade: binário novo do daemon com
#             sessão viva não derruba nada; ao terminar a última sessão o daemon antigo sai e o novo sobe na próxima conexão,
#             sem novo registro (o job está preso ao launcher estável `rackyd-launch`, S-01).
#   Saída   : exit 0 se tudo passou; relatório e saídas brutas em $EVIDENCE_DIR (padrão build/evidence/slice1/T1-24/e2e-launchd).
#             Se o LaunchAgent exigir aprovação (requiresApproval) o script termina com exit 3 e o relatório diz o que o dono deve fazer.
# Uso: scripts/e2e-launchd.sh [--help]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SRC="${RACKY_BUILD_DIR:-$ROOT/build/Racky}/Racky.app"
[ -d "$SRC" ] || { echo "ERRO: app não encontrado em $SRC (rode scripts/build.sh)" >&2; exit 2; }
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/build/evidence/slice1/T1-24/e2e-launchd}"
mkdir -p "$EVIDENCE_DIR"
N="e$(printf '%04x' $((RANDOM % 65536)))"
MARK="600$((10000 + RANDOM))"   # argumento numérico de `sleep`, único por execução (identifica o processo do agente)
WORK="/tmp/abe-$N"
APP="$WORK/Racky.app"
HOME_T="$WORK/h"
SOCK_APP="$WORK/app.sock"
LABEL="app.racky.ptyd.test-$N"
KEY="RACKY_PTYD_SOCK_TEST_$(echo "$N" | tr '[:lower:]' '[:upper:]')"
BID="app.racky.mac.test$N"
UIDN="$(id -u)"
MACOS="$APP/Contents/MacOS"
REPORT="$EVIDENCE_DIR/report.txt"
FAILS=0
rm -f "$EVIDENCE_DIR"/*.txt "$EVIDENCE_DIR"/*.json "$EVIDENCE_DIR"/*.png
: > "$REPORT"

say() { echo "$*" | tee -a "$REPORT"; }
check() { # descricao comando...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then say "PASS  $d"; else say "FAIL  $d"; FAILS=$((FAILS + 1)); fi
}
ctl() { "$APP/Contents/Helpers/racky" ctl "$@" --sock "$SOCK_APP"; }
job_field() { launchctl print "gui/$UIDN/$LABEL" 2>/dev/null | sed -n "s/^[[:space:]]$1 = //p" | head -1; }
job_state() { launchctl print "gui/$UIDN/$LABEL" 2>/dev/null | grep -E "^	state = " | head -1 | sed 's/.*= //'; }
daemon_pid() { launchctl print "gui/$UIDN/$LABEL" 2>/dev/null | sed -n 's/^	pid = //p' | head -1; }
app_pid() { pgrep -f "$APP/Contents/MacOS/Racky" | head -1; }
wait_for() { # segundos comando...
  local t="$1"; shift; local i=0
  while ! "$@" >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt $((t * 4)) ] || return 1; sleep 0.25; done
}
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
sock_up() { [ -S "$SOCK_APP" ] && ctl state >/dev/null 2>&1; }

cleanup() {
  say "--- limpeza"
  local pid; pid="$(app_pid || true)"
  [ -z "$pid" ] || { kill "$pid" 2>/dev/null; sleep 1; }
  if [ -x "$MACOS/registrar" ]; then "$MACOS/registrar" unregister "$LABEL.plist" 2>&1 | tee -a "$EVIDENCE_DIR/unregister.txt" >/dev/null; fi
  pkill -f "sleep $MARK" 2>/dev/null || true
  launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1 && launchctl bootout "gui/$UIDN/$LABEL" 2>/dev/null
  say "launchctl getenv $KEY => [$(launchctl getenv "$KEY")]"
  say "job $LABEL ainda existe? $(launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1 && echo SIM || echo nao)"
  rm -rf "$WORK"
  say "RESULTADO: $([ "$FAILS" -eq 0 ] && echo OK || echo "$FAILS falha(s)")"
}
trap cleanup EXIT

say "e2e-launchd N=$N label=$LABEL bundle=$BID $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "macOS $(sw_vers -productVersion) ($(uname -m)); app: $SRC"

# --- cópia de teste -----------------------------------------------------------------------------------------------------
mkdir -p "$WORK" "$HOME_T"; chmod 700 "$HOME_T"
ditto "$SRC" "$APP"
rm -f "$APP/Contents/Library/LaunchAgents/"*.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist"
cat > "$APP/Contents/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>BundleProgram</key><string>Contents/MacOS/rackyd-launch</string>
<key>ProgramArguments</key><array><string>Contents/MacOS/rackyd-launch</string><string>--launchd</string><string>Listeners</string><string>--build</string><string>1</string><string>--idle-exit</string><string>8</string></array>
<key>AssociatedBundleIdentifiers</key><array><string>$BID</string></array>
<key>EnvironmentVariables</key><dict><key>RACKY_HOME</key><string>$HOME_T</string></dict>
<key>ProcessType</key><string>Interactive</string>
<key>AbandonProcessGroup</key><true/>
<key>KeepAlive</key><false/>
<key>Sockets</key><dict><key>Listeners</key><dict><key>SecureSocketWithKey</key><string>$KEY</string><key>SockPathMode</key><integer>384</integer></dict></dict>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Library/LaunchAgents/$LABEL.plist" >/dev/null || { say "ERRO: plist de teste inválido"; exit 2; }
swiftc -O -target arm64-apple-macos15.0 "$ROOT/scripts/e2e-launchd/registrar.swift" -o "$MACOS/registrar" 2>>"$EVIDENCE_DIR/registrar-build.txt" \
  || { say "ERRO: não compilou o registrar (ver registrar-build.txt)"; exit 2; }
sign() { codesign --force --options runtime --timestamp=none --sign - --identifier "$2" "$1" >/dev/null 2>&1; }
sign "$MACOS/rackyd" app.racky.ptyd; sign "$MACOS/rackyd-launch" app.racky.ptyd.launch; sign "$APP/Contents/Helpers/racky" app.racky.cli; sign "$MACOS/registrar" app.racky.e2e-registrar
sign "$APP" "$BID"
codesign --verify --strict "$APP" 2>&1 | tee -a "$EVIDENCE_DIR/codesign.txt" >/dev/null
say "assinatura da cópia: $(codesign -dv "$APP" 2>&1 | grep -E 'Signature|flags' | tr '\n' ' ')"

launch_app() {
  open -n -g --env "RACKY_HOME=$HOME_T" --env "RACKY_APP_SOCK=$SOCK_APP" --env RACKY_AUTOMATION=1 --env RACKY_LAUNCHD=1 \
    --env "RACKY_TEST_N=$N" --env RACKY_SKIP_ONBOARDING=1 "$APP"
}

# --- 1. registro, socket do launchd, sessão ---------------------------------------------------------------------------------
say; say "== 1. registro e socket do launchd"
launch_app
wait_for 20 sock_up || { say "FAIL  o app não subiu (app.sock)"; exit 1; }
say "app PID $(app_pid)"
ctl ui action session.launch set "{\"provider\":\"custom\",\"argv\":[\"/bin/sh\",\"-c\",\"echo e2e-alive; exec sleep $MARK\"],\"name\":\"e2e\"}" \
  > "$EVIDENCE_DIR/session-launch.json" 2>&1
wait_for 20 sh -c "launchctl print gui/$UIDN/$LABEL >/dev/null 2>&1"
STATUS_LINE="$("$MACOS/registrar" status "$LABEL.plist" 2>&1 | tr '\n' ' ')"
say "SMAppService: $STATUS_LINE"
if echo "$STATUS_LINE" | grep -q requiresApproval || ! launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1; then
  say "BLOQUEADO: o LaunchAgent exige aprovação em Ajustes do Sistema > Geral > Itens de Início (ação do dono). O app caiu no fallback (daemon filho)."
  say "exit 3 = fallback exercitado, LaunchAgent não verificado"
  launchctl print "gui/$UIDN/$LABEL" > "$EVIDENCE_DIR/launchctl-print-requiresApproval.txt" 2>&1
  exit 3
fi
wait_for 20 pgrep -f "^sleep $MARK$" || say "FAIL  o processo do agente não apareceu"
SLEEP_PID="$(pgrep -f "^sleep $MARK$" | head -1)"
check "job $LABEL carregado e em execução" test "$(job_state)" = running
D1="$(daemon_pid)"
SOCK_PATH="$(launchctl getenv "$KEY")"
say "daemon PID $D1; processo do agente PID $SLEEP_PID; launchctl getenv $KEY => $SOCK_PATH"
check "launchctl getenv devolve o caminho do socket" test -S "$SOCK_PATH"
check "o daemon é do launchd (pai = launchd, não o app)" test "$(ps -o ppid= -p "$D1" | tr -d ' ')" = 1
check "o agente é filho do daemon" test "$(ps -o ppid= -p "$SLEEP_PID" | tr -d ' ')" = "$D1"
launchctl print "gui/$UIDN/$LABEL" > "$EVIDENCE_DIR/launchctl-print-running.txt" 2>&1
ls -la "$(dirname "$SOCK_PATH")" > "$EVIDENCE_DIR/socket-dir.txt" 2>&1
check "socket 0600 num diretório 0700 do launchd" test "$(stat -f %Lp "$SOCK_PATH")" = 600
check "o daemon não fez bind em AB/run (modo launchd)" test ! -e "$HOME_T/run/ptyd-v1.sock"

# --- 2. ⌘Q com agente vivo -------------------------------------------------------------------------------------------------
say; say "== 2. ⌘Q com agente vivo: overlay, Keep Running, accessory"
APP1="$(app_pid)"
# O e2e não executa agentes reais: o terminal custom `sleep` é marcado como agente (claude) no banco, que é de onde o ⌘Q conta.
sqlite3 "$HOME_T/db/racky.sqlite" "UPDATE terminal SET provider='claude' WHERE state='running';" 2>&1 | tee -a "$EVIDENCE_DIR/fixture.txt" >/dev/null
say "fixture: terminais running marcados como claude no banco ($(sqlite3 "$HOME_T/db/racky.sqlite" "SELECT count(*) FROM terminal WHERE provider='claude' AND state='running';"))"
ctl ui action app.quit > "$EVIDENCE_DIR/quit-1.json" 2>&1
wait_for 10 sh -c "'$APP/Contents/Helpers/racky' ctl ui tree --sock '$SOCK_APP' | grep -q overlay.confirmQuit" \
  && say "PASS  overlay overlay.confirmQuit apareceu na janela (sem NSAlert)" || { say "FAIL  overlay de quit não apareceu"; FAILS=$((FAILS + 1)); }
ctl screenshot --size 1440x900 --out "$EVIDENCE_DIR/quit-overlay-1440x900.png" >/dev/null 2>&1 || true
ctl ui tree > "$EVIDENCE_DIR/ui-tree-overlay.json" 2>&1
ctl ui action dialog.quit.keepRunning > "$EVIDENCE_DIR/keep-running.json" 2>&1
sleep 1.5
check "Keep Running: o app continua vivo (mesmo PID)" test "$(app_pid)" = "$APP1"
check "Keep Running: o daemon continua o mesmo" test "$(daemon_pid)" = "$D1"
check "Keep Running: o agente continua vivo" alive "$SLEEP_PID"
ASN="$(lsappinfo find pid="$APP1" 2>/dev/null | head -1)"
say "lsappinfo: $(lsappinfo info -only applicationtype "$ASN" 2>&1 | tr '\n' ' ')"
check "Keep Running: sem ícone no Dock (modo accessory)" sh -c "lsappinfo info -only applicationtype '$ASN' | grep -qi 'UIElement\\|BackgroundOnly'"
check "ctl segue respondendo em segundo plano (hooks e MCP seguem no app)" ctl state

# --- 3. Quit Completely e reabrir ------------------------------------------------------------------------------------------
say; say "== 3. Quit Completely e reabrir (reattach)"
ctl ui action app.quitCompletely > "$EVIDENCE_DIR/quit-completely.json" 2>&1
wait_for 15 sh -c "! kill -0 $APP1 2>/dev/null" && say "PASS  o processo do app saiu" || { say "FAIL  o app não saiu"; FAILS=$((FAILS + 1)); }
check "daemon: mesmo PID depois do quit" test "$(daemon_pid)" = "$D1"
check "agente: mesmo PID depois do quit" alive "$SLEEP_PID"
launch_app
wait_for 20 sock_up || say "FAIL  o app não voltou"
sleep 3
check "reabrir: o daemon é o mesmo (sem segundo daemon)" test "$(daemon_pid)" = "$D1"
check "reabrir: o agente é o mesmo processo" alive "$SLEEP_PID"
ctl ui tree > "$EVIDENCE_DIR/ui-tree-after-reopen.json" 2>&1
check "reabrir: o pane do terminal voltou na árvore" sh -c "grep -q 'pane\\.' '$EVIDENCE_DIR/ui-tree-after-reopen.json'"
ctl screenshot --size 1440x900 --out "$EVIDENCE_DIR/after-reopen-1440x900.png" >/dev/null 2>&1 || true

# --- 4. upgrade do daemon --------------------------------------------------------------------------------------------------
say; say "== 4. daemon novo (S-01: o launchd prende o job ao cdhash do BundleProgram, por isso o job usa o launcher estável)"
ctl ui action app.quitCompletely >/dev/null 2>&1
wait_for 15 sh -c "! pgrep -f '$APP/Contents/MacOS/Racky' >/dev/null"
LAUNCHER_BEFORE="$(codesign -dvvv "$MACOS/rackyd-launch" 2>&1 | sed -n 's/^CDHash=//p')"
say "daemon em execução: $(codesign -dvvv "$D1" 2>&1 | sed -n 's/^Identifier=//p') (PID $D1)"
# Daemon "novo": mesmo código com outro identificador de assinatura (muda o cdhash do rackyd; o do launcher não muda).
sign "$MACOS/rackyd" "app.racky.ptyd.upgrade$N"; sign "$APP" "$BID"
check "bundle válido com o daemon novo" codesign --verify --strict "$APP"
check "o cdhash do launcher não mudou" test "$(codesign -dvvv "$MACOS/rackyd-launch" 2>&1 | sed -n 's/^CDHash=//p')" = "$LAUNCHER_BEFORE"
launch_app
wait_for 20 sock_up || say "FAIL  o app não voltou depois da troca do daemon"
sleep 3
check "binário novo com sessão viva: o daemon antigo continua (nada foi morto)" test "$(daemon_pid)" = "$D1"
check "binário novo com sessão viva: o agente continua" alive "$SLEEP_PID"
kill "$SLEEP_PID" 2>/dev/null   # acaba a última sessão: o daemon antigo (drainWhenIdle / --idle-exit 8) sai sozinho
wait_for 40 sh -c "! kill -0 $D1 2>/dev/null" && say "PASS  o daemon antigo saiu sozinho quando a última sessão terminou" \
  || { say "FAIL  o daemon antigo não saiu"; FAILS=$((FAILS + 1)); }
ctl ui action session.launch set "{\"provider\":\"custom\",\"argv\":[\"/bin/sh\",\"-c\",\"echo e2e-second; exec sleep $MARK\"],\"name\":\"e2e2\"}" > "$EVIDENCE_DIR/session-launch-2.json" 2>&1
wait_for 30 pgrep -f "^sleep $MARK$" && say "PASS  nova sessão sobe depois do upgrade" || { say "FAIL  nova sessão não subiu depois do upgrade"; FAILS=$((FAILS + 1)); }
D3="$(daemon_pid)"
say "daemon novo: PID ${D3:-?} $(codesign -dvvv "${D3:-0}" 2>&1 | sed -n 's/^Identifier=//p')"
check "o daemon novo é outro processo" test -n "$D3" -a "$D3" != "$D1"
check "o daemon novo é o binário novo (identificador de assinatura novo)" sh -c "codesign -dvvv '$D3' 2>&1 | grep -q 'Identifier=app.racky.ptyd.upgrade$N'"
check "o daemon novo é filho do launchd" test "$(ps -o ppid= -p "${D3:-0}" | tr -d ' ')" = 1
launchctl print "gui/$UIDN/$LABEL" > "$EVIDENCE_DIR/launchctl-print-after-upgrade.txt" 2>&1
check "job sem spawn failed nem pendência de LWCR" sh -c "! grep -q 'spawn failed\\|needs LWCR update' '$EVIDENCE_DIR/launchctl-print-after-upgrade.txt'"
check "nenhum novo registro foi necessário (runs do job só contam spawns, sem recriação)" sh -c "grep -q 'program identifier = Contents/MacOS/rackyd-launch' '$EVIDENCE_DIR/launchctl-print-after-upgrade.txt'"

say; say "fim dos passos"
[ "$FAILS" -eq 0 ]
