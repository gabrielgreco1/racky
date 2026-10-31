#!/usr/bin/env bash
# selftest.sh - roda o autoteste do runtime sem Docker contra uma VM REAL (assets gerados localmente), sem tocar no app do dono.
#
# Contrato
#   Entrada : <OUT>/vz-manifest.json (scripts/vz/fetch-kernel.sh + scripts/vz/build-image.sh). Env: RACKY_VZ_OUT (padrão build/vz-assets).
#   Efeitos : compila `racky-vz-selftest` (debug), assina AD-HOC com App/Racky.entitlements (com.apple.security.virtualization) e o roda com
#             um RACKY_HOME temporário (nunca ~/Library/Application Support/Racky). Boot de VM real: exec, virtiofs, copyIn/copyOut,
#             segredos por stdin, ponte até a admin API (:8790), computador headless completo e desmontagem. Não deixa VM rodando.
#   Saída   : uma linha por passo com o tempo; `RESULT pass` no fim e exit 0 se tudo passou.
#   Env     : RACKY_VZ_SELFTEST_NO_BUILD=1 não compila (usa .build/debug/racky-vz-selftest; é o modo do `swift test`).
#             RACKY_VZ_SELFTEST_HOME=<pasta temporária> reaproveita os assets já preparados (e não apaga a pasta).
#   Requer  : macOS 26+ em Apple silicon.
# Uso: scripts/vz/selftest.sh [--keep-home]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RACKY_VZ_OUT:-$ROOT/build/vz-assets}"
KEEP=0
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; --keep-home) KEEP=1 ;; esac
[ -f "$OUT/vz-manifest.json" ] || { echo "faltam os assets: rode scripts/vz/fetch-kernel.sh e scripts/vz/build-image.sh" >&2; exit 1; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "${RACKY_VZ_SELFTEST_NO_BUILD:-0}" = 1 ]; then
  # Chamado de dentro do `swift test` (que segura o lock do .build): usa o binário que o próprio teste já compilou.
  BIN="$ROOT/Packages/RackyKit/.build/debug/racky-vz-selftest"
  [ -x "$BIN" ] || { echo "binário ausente: $BIN" >&2; exit 1; }
else
  swift build --package-path "$ROOT/Packages/RackyKit" --product racky-vz-selftest >/dev/null
  BIN="$(swift build --package-path "$ROOT/Packages/RackyKit" --show-bin-path)/racky-vz-selftest"
fi
codesign --force --sign - --entitlements "$ROOT/App/Racky.entitlements" --identifier app.racky.vz-selftest "$BIN"

# RACKY_VZ_SELFTEST_HOME reaproveita uma pasta temporária entre execuções (pula os ~65 s de cópia/desempacotamento dos assets).
if [ -n "${RACKY_VZ_SELFTEST_HOME:-}" ]; then HOME_DIR="$RACKY_VZ_SELFTEST_HOME"; mkdir -p "$HOME_DIR"; KEEP=1
else HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/racky-vz-selftest.XXXXXX")"; fi
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$HOME_DIR"; }
trap cleanup EXIT
echo "home temporário: $HOME_DIR"
RACKY_HOME="$HOME_DIR" "$BIN" --home "$HOME_DIR" --manifest "$OUT/vz-manifest.json"
