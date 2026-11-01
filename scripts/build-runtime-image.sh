#!/usr/bin/env bash
# build-runtime-image.sh - build local da imagem `racky-computer` com tag por hash de conteúdo (T3-01, 07 CS-120/121).
#
# Contrato
#   Entrada : contexto em runtime/computer (Dockerfile, requirements.txt, racky_*).
#   Tag     : racky-computer:ctx-<sha12 do hash do contexto>. O hash é o mesmo de `BuildContext.contentHash` (Swift):
#             sha256 das linhas "<caminho>\0<755|644>\0<sha256 do arquivo>\n" em ordem bytewise; sem .DS_Store.
#   Saída   : imprime a tag na última linha. Com --print-hash/--print-tag só calcula, sem chamar o Docker.
#   Rótulos : racky.context_hash=<hash completo>; --label k=v adiciona outros (testes: --label racky.test=1).
#   Requer  : docker no PATH (ampliado com os caminhos dos runtimes) só para o build; shasum e find.
# Uso: scripts/build-runtime-image.sh [--context DIR] [--repository NOME] [--label k=v]... [--no-cache] [--print-hash|--print-tag]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="$ROOT/runtime/computer"
REPOSITORY="racky-computer"
LABELS=()
NO_CACHE=()
MODE=build

while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --repository) REPOSITORY="$2"; shift 2 ;;
    --label) LABELS+=(--label "$2"); shift 2 ;;
    --no-cache) NO_CACHE=(--no-cache); shift ;;
    --print-hash) MODE=hash; shift ;;
    --print-tag) MODE=tag; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uso inválido: $1" >&2; exit 2 ;;
  esac
done

[ -d "$CONTEXT" ] || { echo "contexto inexistente: $CONTEXT" >&2; exit 1; }

context_hash() {
  (
    cd "$CONTEXT"
    find . -type f ! -name .DS_Store ! -name '*.pyc' ! -path '*/__pycache__/*' -print | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
      mode=644
      [ -n "$(find "$f" -maxdepth 0 -perm -u+x)" ] && mode=755
      printf '%s\0%s\0%s\n' "$f" "$mode" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
    done | shasum -a 256 | cut -d' ' -f1
  )
}

HASH="$(context_hash)"
TAG="$REPOSITORY:ctx-${HASH:0:12}"

case "$MODE" in
  hash) echo "$HASH"; exit 0 ;;
  tag) echo "$TAG"; exit 0 ;;
esac

export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:/Applications/Docker.app/Contents/Resources/bin"
command -v docker >/dev/null 2>&1 || { echo "docker não encontrado no PATH" >&2; exit 1; }

echo "build: $TAG (contexto $CONTEXT, hash $HASH)"
docker build ${NO_CACHE[@]+"${NO_CACHE[@]}"} --label "racky.context_hash=$HASH" ${LABELS[@]+"${LABELS[@]}"} -t "$TAG" "$CONTEXT"
echo "$TAG"
