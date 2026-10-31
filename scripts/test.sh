#!/usr/bin/env bash
# test.sh - roda a suíte do RackyKit sem travar: unit em paralelo, integração em série.
#
# Contrato
#   Entrada : modo `unit` ou `all`; `--no-build` pula o `swift build --build-tests`.
#   Modos   : unit = tudo que NÃO está marcado `.tags(.integration)`, em paralelo (rápido, sem daemon, zsh, Docker, launchd).
#             all  = unit em paralelo e depois as suítes `integration`, uma de cada vez (`--no-parallel`).
#             integration = só as suítes `integration`, em série.
#   Efeitos : grava o log completo em Packages/RackyKit/.build/test-logs/; no fim mata só os daemons que ESTE run subiu.
#   Saída   : resumo curto (contagem, tempos, falhas); exit 0 se tudo passou, 1 se algo falhou ou estourou o limite, 2 uso inválido.
#   Limites : cada fase tem um teto de relógio (AB_TEST_UNIT_LIMIT, AB_TEST_INTEGRATION_LIMIT, em segundos; 240 e 480), e cada
#             teste de integração tem `.timeLimit` próprio. Nada fica pendurado.
# Uso: scripts/test.sh unit|all|integration [--no-build] [--help]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/RackyKit"
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

MODE=""
BUILD=1
for arg in "$@"; do
  case "$arg" in
    unit|all|integration) MODE="$arg" ;;
    --no-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "test: argumento desconhecido: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
UNIT_LIMIT="${AB_TEST_UNIT_LIMIT:-240}"
INTEGRATION_LIMIT="${AB_TEST_INTEGRATION_LIMIT:-480}"
LOGDIR="$PKG/.build/test-logs"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
cd "$PKG"

# Suítes de integração = as que declaram `.tags(.integration)` (fonte única da verdade: o código dos testes).
INTEGRATION_NAMES="$(python3 -I - "$PKG/Tests" <<'PY'
import os, re, sys
names = set()
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if not f.endswith('.swift'):
            continue
        text = open(os.path.join(root, f), encoding='utf-8').read()
        for m in re.finditer(r'@Suite\b(.*?)\b(?:struct|final class|actor)\s+(\w+)', text, re.S):
            header = m.group(1)
            if '{' in header or ';' in header:
                continue
            if '.integration' in header:
                names.add(m.group(2))
print('|'.join(sorted(names)))
PY
)"
[ -n "$INTEGRATION_NAMES" ] || { echo "test: nenhuma suíte .integration encontrada" >&2; exit 2; }
SUITE_COUNT="$(echo "$INTEGRATION_NAMES" | tr '|' '\n' | wc -l | tr -d ' ')"
FILTER_RE="\\.(${INTEGRATION_NAMES})/"

STARTED_AT=$SECONDS
PIDS_TO_CLEAN=()
cleanup() {
  for pid in "${PIDS_TO_CLEAN[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  return 0
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

# run_phase <nome> <limite-s> <args do swift test...>: roda com teto de relógio; devolve o exit do swift test (124 = estourou).
run_phase() {
  local name="$1" limit="$2"; shift 2
  local log="$LOGDIR/$MODE-$name-$STAMP.log"
  echo "test: fase '$name' (teto ${limit}s) -> ${log#"$ROOT"/}"
  swift test --skip-build "$@" >"$log" 2>&1 &
  local pid=$!
  PIDS_TO_CLEAN+=("$pid")
  ( sleep "$limit"; kill "$pid" 2>/dev/null; sleep 5; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid"
  local status=$?
  pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  # O swift-test pode deixar o runner vivo se foi morto: encerra o que sobrou dele.
  pkill -P "$pid" 2>/dev/null
  if [ "$status" -ge 128 ] && ! grep -q 'Test run with' "$log"; then status=124; fi
  PHASE_LOG="$log"
  return "$status"
}

# Daemons deste checkout (binário em $PKG/.build): nunca olha os de outras worktrees nem os do app instalado.
daemon_pids() { pgrep -f "$PKG/.build/.*/rackyd" 2>/dev/null | sort -n || true; }
DAEMONS_BEFORE="$(daemon_pids)"

# check_daemons: falha (e mata) qualquer rackyd que ESTE run subiu e continua vivo ~8 s depois do fim da fase.
check_daemons() {
  local deadline=$((SECONDS + 8)) leaked=""
  while :; do
    leaked="$(comm -13 <(echo "$DAEMONS_BEFORE") <(daemon_pids) | tr '\n' ' ')"
    [ -z "${leaked// /}" ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 1
  done
  echo "  DAEMON(S) VAZADO(S) por este run (rackyd vivo no fim): $leaked" >&2
  for pid in $leaked; do kill -9 "$pid" 2>/dev/null; done
  return 1
}

# summarize <log> <exit>: uma linha de contagem e as falhas (sem o ruído dos "started"/"passed").
summarize() {
  local log="$1" status="$2"
  local line; line="$(grep -E '^[✔✘] Test run with|Test run with' "$log" | tail -1)"
  [ -n "$line" ] && echo "  $line" || echo "  (sem linha final do Swift Testing; exit $status)"
  grep -E '^✘ Test .* (failed|recorded an issue)' "$log" | sed -E 's/ recorded an issue at/ issue em/' | sort -u | head -30 | sed 's/^/  /'
  if [ "$status" = "124" ]; then
    echo "  TETO DE TEMPO estourado; testes que começaram e não terminaram:"
    python3 -I - "$log" <<'PY' | head -20 | sed 's/^/    /'
import re, sys
started = {}
for l in open(sys.argv[1], encoding='utf-8', errors='replace'):
    m = re.match(r'◇ Test (\S.*?\(.*?\)) started\.', l)
    if m and 'case passing' not in l: started[m.group(1)] = 1
    m = re.match(r'[✔✘] Test (\S.*?\(.*?\)) (passed|failed) ', l)
    if m: started.pop(m.group(1), None)
print('\n'.join(started))
PY
  fi
}

if [ "$BUILD" = "1" ]; then
  echo "test: swift build --build-tests"
  swift build --build-tests >"$LOGDIR/build-$STAMP.log" 2>&1 || { tail -30 "$LOGDIR/build-$STAMP.log"; echo "test: BUILD FALHOU"; exit 1; }
fi

FAIL=0
if [ "$MODE" = "unit" ] || [ "$MODE" = "all" ]; then
  T0=$SECONDS
  run_phase unit "$UNIT_LIMIT" --skip "$FILTER_RE"; status=$?
  echo "test: unit (fora das $SUITE_COUNT suítes de integração) exit=$status em $((SECONDS - T0))s"
  summarize "$PHASE_LOG" "$status"
  [ "$status" -eq 0 ] || FAIL=1
  check_daemons || FAIL=1
fi
if [ "$MODE" = "integration" ] || [ "$MODE" = "all" ]; then
  T0=$SECONDS
  # `--no-parallel`: uma suíte de cada vez no processo de teste (o Swift Testing respeita a flag do SwiftPM).
  run_phase integration "$INTEGRATION_LIMIT" --no-parallel --filter "$FILTER_RE"; status=$?
  echo "test: integração em série ($SUITE_COUNT suítes) exit=$status em $((SECONDS - T0))s"
  summarize "$PHASE_LOG" "$status"
  [ "$status" -eq 0 ] || FAIL=1
  check_daemons || FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test: OK ($MODE) em $((SECONDS - STARTED_AT))s"
  exit 0
fi
echo "test: FALHOU ($MODE) em $((SECONDS - STARTED_AT))s"
exit 1
