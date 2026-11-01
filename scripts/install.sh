#!/usr/bin/env bash
# install.sh - instala o app em /Applications com rollback (08 AR-902).
#
# CAMINHO RECOMENDADO (F30): use sempre este script para trocar de build. O app fica em /Applications/Racky.app (local fixo,
# com backup em previous/ e --rollback). Abrir o app direto de build/ ou de /private/tmp/... funciona (ele se conecta ao daemon
# que já está vivo e não re-registra o LaunchAgent), mas o launchd prende o job ao bundle que o registrou: só o app em
# /Applications dá um registro estável. Trocar de build nunca mata o daemon nem os agentes: o novo app se conecta ao daemon vivo
# e, se ele for mais antigo, pede drainWhenIdle (sessões antigas ficam nele até acabarem; o ponteiro bin/rackyd-current
# faz o launcher subir o rackyd novo na próxima conexão).
#
# Contrato
#   Padrão   : roda build.sh; se o app estiver aberto, pede encerramento (osascript quit) e espera; NUNCA mata
#              o daemon; guarda a versão instalada em ~/Library/Application Support/Racky/previous/;
#              copia o novo bundle para um temporário em /Applications e troca por rename atômico; abre o app
#              (a menos que --no-open).
#   --rollback : restaura a versão guardada em previous/ (a atual vira previous/ para permitir desfazer).
#   Env      : RACKY_INSTALL_DIR (padrão /Applications), RACKY_HOME (padrão ~/Library/Application Support/Racky),
#              RACKY_BUILD_DIR (saída do build.sh).
# Uso: scripts/install.sh [--no-open] [--rollback] [--help]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "ERRO: $*" >&2; exit 1; }

INSTALL_DIR="${RACKY_INSTALL_DIR:-/Applications}"
SUPPORT="$HOME/Library/Application Support"
AB="${RACKY_HOME:-$SUPPORT/Racky}"
PREV_DIR="$AB/previous"
BUILD_APP="${RACKY_BUILD_DIR:-$ROOT/build/Racky}/Racky.app"
TARGET="$INSTALL_DIR/Racky.app"
BUNDLE_ID=app.racky.mac
OPEN=1; ROLLBACK=0
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --no-open) OPEN=0 ;;
    --rollback) ROLLBACK=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done

quit_app() {
  if pgrep -f "$TARGET/Contents/MacOS/Racky" >/dev/null 2>&1; then
    echo "install: encerrando o app (o daemon continua vivo)"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      pgrep -f "$TARGET/Contents/MacOS/Racky" >/dev/null 2>&1 || return 0
      sleep 0.5
    done
    fail "o app não encerrou em 30 s; feche-o e rode de novo (o daemon não é morto)"
  fi
}

swap_in() { # source_bundle ; guarda a instalada em previous/ e troca por rename atômico
  local src="$1" tmp="$INSTALL_DIR/.Racky.app.new.$$" keep="$PREV_DIR/Racky.app.keep.$$"
  mkdir -p "$PREV_DIR"; chmod 700 "$AB" 2>/dev/null || true
  rm -rf "$tmp"; ditto "$src" "$tmp"
  codesign --verify --strict "$tmp" || { rm -rf "$tmp"; fail "bundle novo não passa em codesign --verify --strict"; }
  if [ -d "$TARGET" ]; then
    ditto "$TARGET" "$keep"
    # rename atômico de diretórios: troca os dois de uma vez
    if ! python3 -I - "$tmp" "$TARGET" <<'PY'
import ctypes, sys, os
libc = ctypes.CDLL(None, use_errno=True)
RENAME_SWAP = 2
r = libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), RENAME_SWAP)
sys.exit(0 if r == 0 else 1)
PY
    then
      rm -rf "$tmp" "$keep"; fail "troca atômica falhou; instalação anterior intacta"
    fi
    rm -rf "$tmp"
    rm -rf "$PREV_DIR/Racky.app"; mv "$keep" "$PREV_DIR/Racky.app"
  else
    mv "$tmp" "$TARGET"
  fi
}

if [ "$ROLLBACK" = 1 ]; then
  [ -d "$PREV_DIR/Racky.app" ] || fail "nenhuma versão anterior em $PREV_DIR"
  quit_app
  ROLL_SRC="$PREV_DIR/Racky.app.rollback.$$"
  mv "$PREV_DIR/Racky.app" "$ROLL_SRC"
  swap_in "$ROLL_SRC"
  rm -rf "$ROLL_SRC"
  echo "install: rollback concluído -> $TARGET"
else
  "$ROOT/scripts/build.sh"
  [ -d "$BUILD_APP" ] || fail "build não produziu $BUILD_APP"
  quit_app
  swap_in "$BUILD_APP"
  echo "install: instalado -> $TARGET (anterior em $PREV_DIR)"
fi
codesign --verify --strict "$TARGET"
[ "$OPEN" = 1 ] && open "$TARGET"
exit 0
