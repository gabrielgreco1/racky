#!/usr/bin/env bash
# clean-install.sh - simula, neste Mac, o primeiro uso de quem baixou o DMG: sem Docker, sem runtime baixado, sem agente de verdade.
#
# Contrato
#   Entrada : build/release/Racky.dmg (scripts/release.sh) e os arquivos do runtime em build/release/runtime-*/ (scripts/vz/stage-release.sh).
#             Env: RACKY_DMG, RACKY_RUNTIME_STAGE (pasta runtime-*), EVIDENCE_DIR (padrão build/evidence/release/<data>-<sha>).
#   Passos  : 1 monta o DMG e copia o app para uma pasta temporária (NUNCA /Applications) · 2 manifesto local file:// derivado do manifesto
#             EMBUTIDO no app (confere que os sha256 embutidos batem com os arquivos) · 3 abre o app com RACKY_HOME/HOME temporários,
#             RACKY_LAUNCHD=0, automação ligada, DOCKER_HOST=unix:///nonexistent e um "claude" de mentira · 4 onboarding (checklist sem Docker,
#             "Computer runtime") · 5 sessão limpa com o agente de mentira, que reserva UM computador pelo caminho MCP real · 6 o computador
#             sobe no runtime nativo (download file://, preparo, VM) · 7 Settings/Diagnostics sem Docker · 8 sair e conferir que não sobrou VM.
#   Segurança: o app do dono (/Applications/Racky.app), o launchd (app.racky.*), ~/Library/Application Support/Racky,
#             ~/.claude, ~/.codex e o Docker dele não são tocados; antes e depois grava o que é do dono e falha se mudou. Só mata PIDs
#             que ele subiu. O app é executado direto (sem `open`, sem LaunchServices); o helper MCP roda com RACKY_MCP_NO_LAUNCH=1.
#   Saída   : exit 0 só se tudo passou. Evidência (report.txt, timings.json, telas, árvores de UI, log do agente de mentira).
# Uso: scripts/clean-install.sh [--help]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
for t in jq python3 sqlite3 ditto codesign hdiutil; do command -v "$t" >/dev/null 2>&1 || { echo "ERRO: falta '$t'" >&2; exit 2; }; done

DMG="${RACKY_DMG:-$ROOT/build/release/Racky.dmg}"
STAGE="${RACKY_RUNTIME_STAGE:-$(ls -d "$ROOT"/build/release/runtime-* 2>/dev/null | tail -1)}"
[ -f "$DMG" ] || { echo "ERRO: sem DMG em $DMG (scripts/release.sh)" >&2; exit 2; }
[ -d "$STAGE" ] || { echo "ERRO: sem pasta runtime-* (scripts/vz/stage-release.sh)" >&2; exit 2; }
SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/build/evidence/release/$(date +%Y%m%d)-$SHA}"
mkdir -p "$EVIDENCE_DIR"
WORK="$(mktemp -d /tmp/rkci-XXXXXX)" || exit 2   # curto: o limite do sun_path é 104 bytes
HOME_T="$WORK/h"; FAKE_HOME="$WORK/home"; INSTALL="$WORK/install"; APP="$INSTALL/Racky.app"; SOCK="$WORK/app.sock"
REPO="$WORK/repo"; DB="$HOME_T/db/racky.sqlite"; MNT="$WORK/mnt"; MANIFEST_DIR="$WORK/manifest"
mkdir -p "$HOME_T" "$FAKE_HOME/.local/bin" "$INSTALL" "$REPO" "$MANIFEST_DIR"; chmod 700 "$HOME_T"
REPORT="$EVIDENCE_DIR/report.txt"; : > "$REPORT"
FAKE_LOG="$EVIDENCE_DIR/fake-claude.log"; : > "$FAKE_LOG"
FAILS=0; APP_PID=""; DOCKER_EVENTS_PID=""; T0=$(python3 -c 'import time; print(time.time())')
TIMINGS="$WORK/timings.tsv"; : > "$TIMINGS"

say() { echo "$*" | tee -a "$REPORT"; }
now() { python3 -c "import time; print(round(time.time() - $T0, 2))"; }
mark() { local t; t="$(now)"; printf '%s\t%s\n' "$1" "$t" >> "$TIMINGS"; say "  [t+${t}s] $1"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then say "  PASS  $d"; else say "  FAIL  $d"; FAILS=$((FAILS + 1)); fi; }
ctl() { "$APP/Contents/Helpers/racky" ctl "$@" --sock "$SOCK"; }
act() { ctl ui action "$@"; }
act_ok() { act "$@" 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; }
db() { sqlite3 -cmd ".timeout 5000" "$DB" "$1" 2>/dev/null; }
wait_for() { local t="$1"; shift; local i=0; while ! "$@" >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt $((t * 2)) ] || return 1; sleep 0.5; done; }
tree() { ctl ui tree 2>/dev/null; }
tree_has() { tree | jq -e --arg id "$1" '[.. | objects | select(.id == $id)] | length > 0' >/dev/null 2>&1; }
tree_text() { tree | jq -r '[.. | objects | (.label // empty), (.value // empty)] | map(tostring) | .[]' 2>/dev/null; }
shot() { ctl screenshot --window --out "$EVIDENCE_DIR/$1.png" >/dev/null 2>&1 || say "  (sem captura: $1)"; }
app_pid() { pgrep -f "$WORK/install/Racky.app/Contents/MacOS/Racky" | head -1; }
mine_pids() { pgrep -f "$WORK/" 2>/dev/null; }
vm_pids() { pgrep -f "com.apple.Virtualization.VirtualMachine" 2>/dev/null | sort; }
owner_snapshot() { # o que é do dono, só leitura
  echo "app instalado:"; pgrep -fl "/Applications/Racky.app/Contents/MacOS" | sed -E 's/^[0-9]+ //' | sort -u
  echo "launchd:"; launchctl print "gui/$(id -u)/app.racky.ptyd.v1" 2>/dev/null | grep -E '^\s(state|program) = ' | sort
  echo "dados do dono:"; ls -la "$HOME/Library/Application Support/Racky" 2>/dev/null | wc -l
  echo "docker containers:"; docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null | sort
}

cleanup() {
  local rc=$?
  say; say "--- limpeza"
  if [ -S "$SOCK" ]; then ctl ui action app.quitCompletely >/dev/null 2>&1; sleep 3; fi
  local pid
  for pid in $(pgrep -f "$WORK/install/Racky.app/Contents/MacOS/Racky"); do kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in $(pgrep -f "$WORK/"); do kill -9 "$pid" 2>/dev/null; done
  [ -z "$DOCKER_EVENTS_PID" ] || kill "$DOCKER_EVENTS_PID" 2>/dev/null
  hdiutil detach "$MNT" -quiet >/dev/null 2>&1
  if [ -f "$EVIDENCE_DIR/owner-before.txt" ]; then
    owner_snapshot > "$EVIDENCE_DIR/owner-after.txt" 2>&1
    if diff -q "$EVIDENCE_DIR/owner-before.txt" "$EVIDENCE_DIR/owner-after.txt" >/dev/null; then say "o que é do dono segue igual (app, launchd, dados, containers)"
    else say "FAIL  o que é do dono mudou:"; diff "$EVIDENCE_DIR/owner-before.txt" "$EVIDENCE_DIR/owner-after.txt" | tee -a "$REPORT"; FAILS=$((FAILS + 1)); fi
  fi
  python3 -I - "$TIMINGS" "$EVIDENCE_DIR/timings.json" <<'PY'
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
json.dump({k: float(v) for k, v in rows}, open(sys.argv[2], "w"), indent=2)
PY
  rm -rf "$WORK"
  say "RESULTADO: $([ "$FAILS" -eq 0 ] && [ "$rc" -eq 0 ] && echo OK || echo "$FAILS falha(s)") (evidência: $EVIDENCE_DIR)"
  [ "$FAILS" -eq 0 ] && [ "$rc" -eq 0 ]
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "clean-install $(date -u +%Y-%m-%dT%H:%M:%SZ) sha=$SHA macOS $(sw_vers -productVersion) $(uname -m) work=$WORK"
say "DMG: $DMG ($(stat -f %z "$DMG") bytes); runtime: $STAGE"
owner_snapshot > "$EVIDENCE_DIR/owner-before.txt" 2>&1
VMS_BEFORE="$(vm_pids)"
# Observador do Docker (só leitura): se o app tocar no Docker de alguma forma que crie algo, aparece aqui.
if command -v docker >/dev/null 2>&1; then
  ( docker events --format '{{.Time}} {{.Type}} {{.Action}} {{.Actor.Attributes.name}}' > "$EVIDENCE_DIR/docker-events.txt" 2>&1 & echo $! > "$WORK/docker-events.pid" )
  sleep 1; DOCKER_EVENTS_PID="$(cat "$WORK/docker-events.pid" 2>/dev/null)"
fi

# 1. DMG -> pasta temporária ----------------------------------------------------------------------------------------------------
say; say "== 1. montar o DMG e copiar o app (fora de /Applications)"
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MNT" > "$EVIDENCE_DIR/hdiutil-attach.txt" 2>&1
check "o DMG tem Racky.app e o atalho Applications -> /Applications" sh -c "[ -d '$MNT/Racky.app' ] && [ \"\$(readlink '$MNT/Applications')\" = /Applications ]"
ls -la "$MNT" > "$EVIDENCE_DIR/dmg-contents.txt" 2>&1
ditto "$MNT/Racky.app" "$APP"; hdiutil detach "$MNT" -quiet
check "app copiado para $INSTALL" test -x "$APP/Contents/MacOS/Racky"
check "codesign --verify --deep --strict na cópia" codesign --verify --deep --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" > "$EVIDENCE_DIR/version.txt" 2>&1
codesign -dv "$APP" > "$EVIDENCE_DIR/codesign.txt" 2>&1; codesign -d --entitlements - "$APP" >> "$EVIDENCE_DIR/codesign.txt" 2>&1
mark "dmg-copiado"

# 2. manifesto local derivado do embutido ----------------------------------------------------------------------------------------
say; say "== 2. manifesto local (file://) a partir do manifesto embutido"
python3 -I - "$APP/Contents/Resources/runtime/vz-manifest.json" "$STAGE" "$MANIFEST_DIR/vz-manifest.json" <<'PY' && say "  PASS  sha256 e tamanhos do manifesto embutido batem com os arquivos de $STAGE" || { say "  FAIL  manifesto embutido não bate com os arquivos"; FAILS=$((FAILS + 1)); }
import hashlib, json, os, sys
baked, stage, out = sys.argv[1:4]
m = json.load(open(baked))
assert "PLACEHOLDER" not in json.dumps(m), "manifesto embutido ainda tem placeholders"
for key in ("kernel", "vminit", "computer"):
    spec = m[key]
    name = spec["url"].rsplit("/", 1)[1]
    path = os.path.join(stage, name)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    assert h.hexdigest() == spec["sha256"], "sha256 de %s difere" % name
    assert os.path.getsize(path) == spec["size"], "tamanho de %s difere" % name
    spec["url"] = "file://" + path
json.dump(m, open(out, "w"), indent=2)
PY
cp "$MANIFEST_DIR/vz-manifest.json" "$EVIDENCE_DIR/local-manifest.json" 2>/dev/null

# 3. agente de mentira + lançamento -----------------------------------------------------------------------------------------------
say; say "== 3. abrir o app (RACKY_HOME e HOME temporários, sem launchd, DOCKER_HOST inexistente)"
cat > "$FAKE_HOME/.local/bin/claude" <<EOF
#!/bin/sh
export FAKE_CLAUDE_LOG='$FAKE_LOG' FAKE_APP_SOCK='$SOCK' FAKE_COMPUTER=ci1
exec /usr/bin/python3 '$ROOT/scripts/clean-install/fake-claude.py' "\$@"
EOF
chmod +x "$FAKE_HOME/.local/bin/claude"
# O shell de login do app lê $HOME/.zshenv (HOME é o temporário): o "claude" de mentira tem que vir ANTES de qualquer outro no PATH.
# (NSHomeDirectory() ignora HOME, então o ~/.local/bin do dono continua nos diretórios conhecidos, mas só depois do PATH.)
printf 'export PATH="%s/.local/bin:$PATH"\n' "$FAKE_HOME" > "$FAKE_HOME/.zshenv"
( cd "$REPO" && git init -q && echo "clean install repo" > README.md && git add . && git -c user.email=ci@racky.local -c user.name=ci commit -qm init )
# RACKY_REAL_DOWNLOAD=1: usa o manifesto embutido (URLs reais das Releases), como um usuário de verdade.
MANIFEST_ENV="RACKY_VZ_MANIFEST=file://$MANIFEST_DIR/vz-manifest.json"
[ "${RACKY_REAL_DOWNLOAD:-0}" = "1" ] && MANIFEST_ENV="RACKY_REAL_DOWNLOAD=1"
env -i HOME="$FAKE_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" USER="$USER" LOGNAME="$USER" TMPDIR="${TMPDIR:-/tmp}" \
  RACKY_HOME="$HOME_T" RACKY_LAUNCHD=0 RACKY_AUTOMATION=1 RACKY_APP_SOCK="$SOCK" RACKY_MCP_NO_LAUNCH=1 \
  "$MANIFEST_ENV" DOCKER_HOST=unix:///nonexistent \
  "$APP/Contents/MacOS/Racky" > "$EVIDENCE_DIR/app-stdout.txt" 2>&1 &
APP_PID=$!
mark "app-lancado"
check "o app de teste respondeu ao ctl (pid $APP_PID)" wait_for 40 sh -c "[ -S '$SOCK' ] && '$APP/Contents/Helpers/racky' ctl state --sock '$SOCK' >/dev/null 2>&1"
mark "app-pronto"
ctl state > "$EVIDENCE_DIR/state.json" 2>&1

# 4. onboarding -------------------------------------------------------------------------------------------------------------------
say; say "== 4. onboarding"
check "o onboarding abre sozinho na primeira execução" wait_for 30 tree_has onboarding
sleep 4   # as sondas (CLIs, gh, runtime) terminam
tree > "$EVIDENCE_DIR/onboarding-tree.json"
tree_text > "$EVIDENCE_DIR/onboarding-text.txt"
shot 01-onboarding
check "linha 'Computer runtime' presente" tree_has onboarding.item.runtime
check "'Computer runtime' diz que baixa sozinho no primeiro uso (~470 MB)" grep -q "Downloads automatically on first use (~470 MB)" "$EVIDENCE_DIR/onboarding-text.txt"
check "nenhuma linha Docker nem imagem no onboarding" sh -c "! tree | jq -e '[.. | objects | select((.id // \"\") | test(\"onboarding.item.(docker|image)\"))] | length > 0' >/dev/null"
check "nenhum texto do onboarding menciona Docker" sh -c "! grep -qi docker '$EVIDENCE_DIR/onboarding-text.txt'"
check "Claude (de mentira) achado e logado no onboarding" grep -qiE "claude|logged in" "$EVIDENCE_DIR/onboarding-text.txt"
mark "onboarding-verificado"
# TRAVA: nunca lançar sessão se o Claude que o app achou não for o de mentira (o log dele registra a sondagem `auth status`). O de verdade gastaria cota do dono.
if ! grep -q "^probe auth status" "$FAKE_LOG"; then say "ABORTADO: o app não achou o claude de mentira (ele não foi sondado); nenhuma sessão foi lançada"; FAILS=$((FAILS + 1)); exit 3; fi
say "  PASS  o app achou o claude de mentira (sondado), nenhuma sessão real será lançada"
act_ok onboarding.done; check "Done fecha o onboarding" wait_for 10 sh -c "! '$APP/Contents/Helpers/racky' ctl ui tree --sock '$SOCK' | jq -e '[.. | objects | select(.id == \"onboarding\")] | length > 0' >/dev/null"

# 5. sessão limpa com o agente de mentira ---------------------------------------------------------------------------------------------
say; say "== 5. projeto, sessão limpa e reserva de um computador (MCP real)"
check "projeto criado" act_ok project.add set "$REPO"
check "sessão no banco" wait_for 20 sh -c "[ -n \"\$(sqlite3 '$DB' 'SELECT id FROM session LIMIT 1')\" ]"
act_ok session.new; check "composer abre" wait_for 15 tree_has overlay.composer
act_ok composer.setWhere select mainCheckout
act_ok composer.setProfile select A0000000-0000-4000-8000-000000000001
act_ok composer.setSubagentComputers select full
act_ok composer.setPrompt set "clean install check"
shot 02-composer
act_ok composer.submit
check "terminal 'claude' (de mentira) criado" wait_for 30 sh -c "[ -n \"\$(sqlite3 '$DB' \"SELECT id FROM terminal WHERE provider='claude'\")\" ]"
mark "sessao-lancada"
check "o agente de mentira subiu" wait_for 30 grep -q "session start" "$FAKE_LOG"
check "ele reservou o computador pelo MCP" wait_for 60 grep -q "boxes_reserve" "$FAKE_LOG"
mark "computador-reservado"
if ! grep -q "boxes_reserve" "$FAKE_LOG"; then say "ABORTADO: a reserva não aconteceu (veja fake-claude.log)"; exit 3; fi

# 6. o computador sobe no runtime nativo ------------------------------------------------------------------------------------------------
say; say "== 6. download file://, preparo e VM"
SEEN_DL=0; SEEN_PREP=0; i=0
while [ "$i" -lt 600 ] && ! grep -q "READY after" "$FAKE_LOG" && ! grep -q "FAILED" "$FAKE_LOG"; do
  txt="$(tree_text)"
  if [ "$SEEN_DL" = 0 ] && echo "$txt" | grep -q "Downloading the computer runtime"; then SEEN_DL=1; mark "download-visivel"; echo "$txt" | grep "Downloading the computer runtime" | head -1 | tee -a "$REPORT"; shot 03-downloading; fi
  if [ "$SEEN_PREP" = 0 ] && echo "$txt" | grep -q "Preparing the computer runtime"; then SEEN_PREP=1; mark "preparando-visivel"; shot 04-preparing; fi
  i=$((i + 1)); sleep 0.5
done
check "o computador ficou pronto (READY no log do agente)" grep -q "READY after" "$FAKE_LOG"
mark "computador-pronto"
grep -E "READY|FAILED" "$FAKE_LOG" | tee -a "$REPORT"
[ "$SEEN_DL" = 1 ] && say "  (a linha de download apareceu na UI)" || say "  note  a linha de download não foi vista pelo polling (arquivos locais baixam rápido)"
sleep 2
shot 05-computer-ready
db "SELECT name,state FROM computer;" > "$EVIDENCE_DIR/computers.txt"
check "linha do computador no banco" test -n "$(db "SELECT name FROM computer WHERE name='ci1';")"
check "o runtime ficou instalado (vz/assets/ready.json)" test -f "$HOME_T/vz/assets/ready.json"
cp "$HOME_T/vz/assets/ready.json" "$EVIDENCE_DIR/ready.json" 2>/dev/null
cp "$HOME_T/vz/registry.json" "$EVIDENCE_DIR/registry-running.json" 2>/dev/null
VMS_NOW="$(vm_pids)"
NEW_VMS="$(comm -13 <(echo "$VMS_BEFORE") <(echo "$VMS_NOW") | tr '\n' ' ')"
say "  VMs novas (Virtualization.framework): ${NEW_VMS:-nenhuma}"
check "uma VM nova do Virtualization.framework está rodando" test -n "$NEW_VMS"
du -sh "$HOME_T/vz" 2>/dev/null | tee -a "$REPORT"
# Docker: nada de socket do Docker aberto pelo app nem pelo daemon filho, nada criado.
{ lsof -U -a -p "$APP_PID" 2>/dev/null; for p in $(pgrep -P "$APP_PID"); do lsof -U -a -p "$p" 2>/dev/null; done; } > "$EVIDENCE_DIR/lsof-unix-sockets.txt"
check "nenhum socket do Docker aberto pelo app nem pelos filhos" sh -c "! grep -qi docker '$EVIDENCE_DIR/lsof-unix-sockets.txt'"
check "nenhum evento do Docker durante o teste" sh -c "[ ! -s '$EVIDENCE_DIR/docker-events.txt' ] || ! grep -q . '$EVIDENCE_DIR/docker-events.txt'"

# 7. Settings e Diagnostics sem Docker --------------------------------------------------------------------------------------------------
say; say "== 7. Settings > Computers e Diagnostics"
act_ok settings.openSection select computers; sleep 1.5
tree_text > "$EVIDENCE_DIR/settings-computers-text.txt"; shot 06-settings-computers
check "Settings > Computers não menciona Docker" sh -c "! grep -qi docker '$EVIDENCE_DIR/settings-computers-text.txt'"
act_ok app.openDiagnostics; sleep 3
tree_text > "$EVIDENCE_DIR/diagnostics-text.txt"; shot 07-diagnostics
check "Diagnostics não menciona Docker" sh -c "! grep -qi docker '$EVIDENCE_DIR/diagnostics-text.txt'"
find "$HOME_T/logs" -type f 2>/dev/null | head -5 | while read -r f; do cp "$f" "$EVIDENCE_DIR/app-log-$(basename "$f")" 2>/dev/null; done
check "o log do app não menciona Docker" sh -c "! cat '$EVIDENCE_DIR'/app-log-* 2>/dev/null | grep -qi docker"

# 8. sair e conferir ---------------------------------------------------------------------------------------------------------------------
say; say "== 8. sair: nenhuma VM pode sobrar"
act app.quitCompletely > "$EVIDENCE_DIR/quit.json" 2>&1
check "o app saiu" wait_for 30 sh -c "! kill -0 $APP_PID 2>/dev/null"
mark "app-encerrado"
sleep 2
VMS_AFTER="$(vm_pids)"
LEFT="$(comm -13 <(echo "$VMS_BEFORE") <(echo "$VMS_AFTER") | tr '\n' ' ')"
check "nenhuma VM nova sobrou" test -z "$LEFT"
check "nenhum processo do teste sobrou" sh -c "[ -z \"\$(pgrep -f '$WORK/')\" ]"
check "registry sem VMs" sh -c "[ \"\$(jq -r '[.[]?] | length' '$HOME_T/vz/registry.json' 2>/dev/null || echo 0)\" = 0 ] || [ \"\$(jq -r '.vms // {} | length' '$HOME_T/vz/registry.json' 2>/dev/null || echo 0)\" = 0 ]"
ls -la "$HOME_T/vz/store/containers" 2>/dev/null | tee "$EVIDENCE_DIR/containers-after-quit.txt" >/dev/null
check "nenhum clone de rootfs sobrou" sh -c "[ \"\$(ls '$HOME_T/vz/store/containers' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ]"
mark "fim"
cat "$TIMINGS" | tee "$EVIDENCE_DIR/timings.tsv" >/dev/null
