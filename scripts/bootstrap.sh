#!/usr/bin/env bash
# bootstrap.sh - confere toolchain e instala ferramentas fixadas.
#
# Contrato
#   Entrada : scripts/tool-versions.txt (fonte única; override: TOOL_VERSIONS_FILE=/caminho).
#   Efeitos : baixa XcodeGen (e, com --fonts, Geist) para .tools/ (gitignored), conferindo SHA-256.
#             Com --fonts, copia Geist[wght].ttf e OFL.txt para RackyDesignSystem/Resources/Fonts/.
#   Saída   : exit 0 se tudo confere; exit 1 em qualquer divergência, com mensagem "ERRO: ...".
#   Confere : Xcode >= XCODE_MIN (major XCODE_MAJOR), rg no PATH, SHA-256 dos downloads,
#             versão do xcodegen instalado, e (se existirem) pins de Package.resolved
#             para SwiftTerm/GRDB/swift-snapshot-testing/swift-argument-parser.
#   Rede    : só para baixar o que faltar em .tools/. Nada é instalado fora do repositório.
# Uso: scripts/bootstrap.sh [--fonts] [--help]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="${TOOL_VERSIONS_FILE:-$ROOT/scripts/tool-versions.txt}"
TOOLS="$ROOT/.tools"
WITH_FONTS=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
fail() { echo "ERRO: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --fonts) WITH_FONTS=1 ;;
    *) usage >&2; fail "argumento desconhecido: $a" ;;
  esac
done

[ -f "$VERSIONS" ] || fail "arquivo de versões não encontrado: $VERSIONS"
get() {
  local v
  v="$(grep -E "^$1=" "$VERSIONS" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' || true)"
  [ -n "$v" ] || fail "chave ausente em $VERSIONS: $1"
  printf '%s' "$v"
}

# 1. Xcode
XCODE_MAJOR="$(get XCODE_MAJOR)"; XCODE_MIN="$(get XCODE_MIN)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$DEVELOPER_DIR" ] || fail "Xcode não encontrado em $DEVELOPER_DIR (defina DEVELOPER_DIR)"
XCV="$(xcodebuild -version 2>/dev/null | awk '/^Xcode/{print $2}' || true)"
[ -n "$XCV" ] || fail "xcodebuild -version falhou com DEVELOPER_DIR=$DEVELOPER_DIR"
[ "${XCV%%.*}" = "$XCODE_MAJOR" ] || fail "Xcode $XCV; exigido major $XCODE_MAJOR.x (>= $XCODE_MIN)"
[ "$(printf '%s\n%s\n' "$XCODE_MIN" "$XCV" | sort -V | head -1)" = "$XCODE_MIN" ] || fail "Xcode $XCV < mínimo $XCODE_MIN"
ok "Xcode $XCV"

# 2. ripgrep
command -v rg >/dev/null 2>&1 || fail "rg (ripgrep) não encontrado no PATH (brew install ripgrep)"
ok "$(rg --version | head -1)"

# 3. XcodeGen fixado
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
download_checked() { # url sha dest
  local url="$1" sha="$2" dest="$3" got
  mkdir -p "$(dirname "$dest")"
  if [ ! -f "$dest" ] || [ "$(sha256_of "$dest")" != "$sha" ]; then
    rm -f "$dest"
    curl -fsSL "$url" -o "$dest" || { rm -f "$dest"; fail "download falhou: $url"; }
  fi
  got="$(sha256_of "$dest")"
  [ "$got" = "$sha" ] || { rm -f "$dest"; fail "SHA-256 diverge para $url (esperado $sha, obtido $got)"; }
}

XG_VER="$(get XCODEGEN_VERSION)"
XG_DIR="$TOOLS/xcodegen-$XG_VER"
download_checked "$(get XCODEGEN_URL)" "$(get XCODEGEN_SHA256)" "$TOOLS/downloads/xcodegen-$XG_VER.zip"
if [ ! -x "$XG_DIR/xcodegen/bin/xcodegen" ]; then
  rm -rf "$XG_DIR"; mkdir -p "$XG_DIR"
  unzip -q "$TOOLS/downloads/xcodegen-$XG_VER.zip" -d "$XG_DIR"
fi
mkdir -p "$TOOLS/bin"; ln -sf "$XG_DIR/xcodegen/bin/xcodegen" "$TOOLS/bin/xcodegen"
XG_GOT="$("$TOOLS/bin/xcodegen" --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ "$XG_GOT" = "$XG_VER" ] || fail "xcodegen instalado é '${XG_GOT:-?}'; fixado $XG_VER"
ok "xcodegen $XG_GOT (.tools/bin/xcodegen)"

# 4. Geist (opcional)
if [ "$WITH_FONTS" = 1 ]; then
  G_VER="$(get GEIST_VERSION)"
  download_checked "$(get GEIST_URL)" "$(get GEIST_SHA256)" "$TOOLS/downloads/geist-font-$G_VER.zip"
  ok "Geist $G_VER (SHA-256 conferido)"
  # Embute no módulo RackyDesignSystem: Geist[wght].ttf (gitignored) e OFL.txt (versionado) em Resources/Fonts.
  FONT_DEST="$ROOT/Packages/RackyKit/Sources/RackyDesignSystem/Resources/Fonts"
  G_EXTRACT="$TOOLS/geist-font-$G_VER"
  if [ ! -f "$G_EXTRACT/geist-font/Geist/variable/Geist[wght].ttf" ]; then
    rm -rf "$G_EXTRACT"; mkdir -p "$G_EXTRACT"
    unzip -q "$TOOLS/downloads/geist-font-$G_VER.zip" -d "$G_EXTRACT"
  fi
  mkdir -p "$FONT_DEST"
  cp "$G_EXTRACT/geist-font/Geist/variable/Geist[wght].ttf" "$FONT_DEST/Geist[wght].ttf"
  cp "$G_EXTRACT/geist-font/OFL.txt" "$FONT_DEST/OFL.txt"
  [ -s "$FONT_DEST/Geist[wght].ttf" ] && [ -s "$FONT_DEST/OFL.txt" ] || fail "Geist: arquivos ausentes após extração"
  ok "Geist embutida em ${FONT_DEST#$ROOT/} (Geist[wght].ttf + OFL.txt)"
fi

# 5. Pins de Package.resolved fora de legacy/
check_pin() { # identity chave
  local want f got
  want="$(get "$2")"
  while IFS= read -r f; do
    got="$(python3 -I - "$f" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for p in d.get("pins",[]):
    if p["identity"]==sys.argv[2]:
        print(p["state"].get("version","")); break
PY
)"
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      fail "$f fixa $1 em $got; tool-versions.txt exige $want"
    fi
  done < <(find "$ROOT" \( -path "$ROOT/legacy" -o -path '*/.build' -o -path "$ROOT/.tools" -o -path "$ROOT/.git" -o -path "$ROOT/build" -o -path '*/DerivedData' -o -path '*/SourcePackages' \) -prune -o -name Package.resolved -print)
}
check_pin swiftterm SWIFTTERM_VERSION
check_pin grdb.swift GRDB_VERSION
check_pin swift-snapshot-testing SWIFT_SNAPSHOT_TESTING_VERSION
check_pin swift-argument-parser SWIFT_ARGUMENT_PARSER_VERSION
ok "pins de Package.resolved (nenhum divergente)"

echo "bootstrap: OK"
