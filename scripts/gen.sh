#!/usr/bin/env bash
# gen.sh - gera Racky.xcodeproj a partir de project.yml (08 AR-120).
#
# Contrato
#   Entrada : project.yml na raiz.
#   Efeitos : roda o XcodeGen fixado em .tools/bin (nunca o do PATH); instala-o via bootstrap.sh se faltar.
#   Saída   : Racky.xcodeproj (gitignored); exit 0 em sucesso.
# Uso: scripts/gen.sh [--help]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -x "$ROOT/.tools/bin/xcodegen" ] || "$ROOT/scripts/bootstrap.sh"
cd "$ROOT"
"$ROOT/.tools/bin/xcodegen" generate --spec project.yml --project "$ROOT" --quiet
echo "gen: Racky.xcodeproj gerado"
