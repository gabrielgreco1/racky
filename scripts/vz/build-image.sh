#!/usr/bin/env bash
# build-image.sh - gera LOCALMENTE os arquivos do runtime sem Docker (kernel, vminit, imagem do computador) e um manifesto local.
#
# Contrato
#   Entrada : runtime/computer/Dockerfile.slim (variante enxuta do Dockerfile do modo Docker) e o kernel em <OUT>/vmlinux
#             (scripts/vz/fetch-kernel.sh). Env: RACKY_VZ_VMINIT (referência do vminit; padrão a versão da apple/containerization
#             fixada em Package.swift), RACKY_VZ_OUT (padrão build/vz-assets), DOCKER (padrão docker).
#   Efeitos : docker build (linux/arm64, rótulo racky.vz-dev=1, tag racky-computer:vz-<hash do contexto>) e docker save --platform linux/arm64
#             da imagem; o vminit público é baixado pelo cliente da apple/containerization (racky-vz-selftest export-image). NADA é
#             publicado nem enviado. Grava em <OUT>:
#               computer.oci.tar, vminit.oci.tar, vmlinux (se já baixado) e vz-manifest.json (URLs relativas + sha256 + tamanho).
#   Saída   : caminho do manifesto na última linha. Para testar no app sem publicar: RACKY_VZ_MANIFEST=<OUT>/vz-manifest.json.
#   Requer  : docker (com o runtime ligado), swift, python3, shasum. Não mexe em nenhum outro contêiner/imagem do Docker.
# Uso: scripts/vz/build-image.sh [--out DIR] [--skip-image] [--skip-vminit] [--no-cache]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RACKY_VZ_OUT:-$ROOT/build/vz-assets}"
DOCKER="${DOCKER:-docker}"
VMINIT_REF="${RACKY_VZ_VMINIT:-ghcr.io/apple/containerization/vminit:0.52.1}"
SKIP_IMAGE=0; SKIP_VMINIT=0; NO_CACHE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --skip-image) SKIP_IMAGE=1; shift ;;
    --skip-vminit) SKIP_VMINIT=1; shift ;;
    --no-cache) NO_CACHE=(--no-cache); shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uso inválido: $1" >&2; exit 2 ;;
  esac
done
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.orbstack/bin:/Applications/Docker.app/Contents/Resources/bin"
command -v "$DOCKER" >/dev/null 2>&1 || { echo "docker não encontrado no PATH" >&2; exit 1; }
mkdir -p "$OUT"

HASH="$("$ROOT/scripts/build-runtime-image.sh" --print-hash)"
TAG="racky-computer:vz-${HASH:0:12}"

if [ "$SKIP_IMAGE" = 0 ]; then
  echo "build: $TAG (Dockerfile.slim, linux/arm64)"
  "$DOCKER" build --platform linux/arm64 ${NO_CACHE[@]+"${NO_CACHE[@]}"} -f "$ROOT/runtime/computer/Dockerfile.slim" \
    --label "racky.vz-dev=1" --label "racky.context_hash=$HASH" -t "$TAG" "$ROOT/runtime/computer"
  echo "save: $OUT/computer.oci.tar"
  rm -f "$OUT/computer.oci.tar"
  "$DOCKER" save --platform linux/arm64 -o "$OUT/computer.oci.tar" "$TAG"
fi

if [ "$SKIP_VMINIT" = 0 ]; then
  # O `docker pull` recusa a imagem do vminit (diff id das camadas errado no registro): o cliente da própria containerization a baixa.
  echo "pull+export: $VMINIT_REF (racky-vz-selftest export-image)"
  swift build --package-path "$ROOT/Packages/RackyKit" --product racky-vz-selftest >/dev/null
  "$(swift build --package-path "$ROOT/Packages/RackyKit" --show-bin-path)/racky-vz-selftest" export-image "$VMINIT_REF" "$OUT/vminit.oci.tar"
fi

python3 -I - "$OUT" "$TAG" "$VMINIT_REF" "$HASH" <<'PY'
import hashlib, json, os, sys
out, tag, vminit, ctx = sys.argv[1:5]

def entry(name, **extra):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return {"url": name, "sha256": h.hexdigest(), "size": os.path.getsize(path), **extra}

kernel = entry("vmlinux", license="GPL-2.0-only", sourceURL=None)
if kernel is not None:
    src = os.path.join(out, "KERNEL-SOURCE.txt")
    if os.path.exists(src):
        kernel["sourceURL"] = open(src).read().strip().splitlines()[0]
manifest = {
    "schema": 1,
    "version": "dev-" + ctx[:12],
    "kernel": kernel,
    "vminit": entry("vminit.oci.tar", reference=vminit),
    "computer": entry("computer.oci.tar", reference=tag),
}
missing = [k for k, v in manifest.items() if v is None]
if missing:
    print("aviso: faltam arquivos em %s para: %s (rode scripts/vz/fetch-kernel.sh / sem --skip-*)" % (out, ", ".join(missing)), file=sys.stderr)
    sys.exit(1)
with open(os.path.join(out, "vz-manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
echo "$OUT/vz-manifest.json"
