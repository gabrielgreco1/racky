#!/usr/bin/env bash
# bench.sh - orçamentos de terminal AR-702/703/704 (08 AR-720). Implementado em T1-09.
#
# Contrato
#   Entrada : Packages/RackyKit (alvos racky-bench e rackyd, build Release). Env: DEVELOPER_DIR.
#   Efeitos : sobe um rackyd real em /tmp (RACKY_HOME isolado), abre TerminalHostView reais (Metal) anexados
#             por TerminalSessionBinding e mede:
#               AR-702 latência de eco, tecla -> emulador alimentado e tecla -> quadro apresentado (p95 <= 16 ms em
#                      repouso; <= 33 ms com 4 panes, 3 deles com `yes`);
#               AR-703 `cat` de 50 MB num pane: maior parada do main (<= 100 ms) e eco em outro pane (<= 33 ms);
#               AR-704 memória: pegada por view de terminal (<= 30 MiB) e por sessão no daemon (<= 25 MiB) com 5 mil
#                      linhas de scrollback.
#             As janelas de teste ficam com alfa 0,01 (praticamente invisíveis) e sem foco. Grava o JSON e sai com
#             código != 0 se algum orçamento estourar. Não cobre xctrace nem os cenários AR-701/705/706 completos.
#   Saída   : build/evidence/bench/<data>-<sha>.json (ou --out <arquivo>); exit 0 = dentro dos orçamentos; 1 = estourou;
#             2 = erro de execução.
#   --ten   : em vez dos cenários acima, os de 10 sessões em paralelo (T2-11, AC-608/609): 10 com saída alta (todas anexadas;
#             4 visíveis + 6 ocultas) e 20 ociosas; mede CPU/RAM do app e do daemon, eco, tempo de quadro e parada do main.
#             `--seconds <n>` muda a janela de CPU (padrão 30 s; ocioso 60 s).
# Uso: scripts/bench.sh [--quick] [--ten] [--seconds <n>] [--out <arquivo.json>] [--no-present] [--help]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

OUT=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT="${2:?--out exige um caminho}"; shift 2 ;;
    --quick|--no-present|--ten) EXTRA+=("$1"); shift ;;
    --seconds) EXTRA+=("$1" "${2:?--seconds exige um número}"); shift 2 ;;
    *) usage >&2; exit 64 ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
DATE="$(date +%Y-%m-%d)"
[ -n "$OUT" ] || OUT="$ROOT/build/evidence/bench/${DATE}-${SHA}.json"
mkdir -p "$(dirname "$OUT")"

PKG=Packages/RackyKit
# O bench é ad-hoc: o rackyd de Release só aceita o cliente com o modo ad-hoc de desenvolvimento (S-03, só vale se o próprio daemon for ad-hoc).
swift build -c release --package-path "$PKG" --product rackyd -Xswiftc -DRACKY_ALLOW_ADHOC_PEERS 2>&1 | tail -1
swift build -c release --package-path "$PKG" --product racky-bench 2>&1 | tail -1
BIN="$(swift build -c release --package-path "$PKG" --show-bin-path)"

echo "bench: executando (alguns minutos)" >&2
rc=0
"$BIN/racky-bench" --out "$OUT" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null || rc=$?
case "$rc" in
  0) echo "bench: OK -> $OUT" ;;
  1) echo "bench: orçamento estourado (veja failures em $OUT)" >&2 ;;
  *) echo "bench: erro de execução (exit $rc)" >&2 ;;
esac
exit "$rc"
