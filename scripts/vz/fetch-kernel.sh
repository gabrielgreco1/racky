#!/usr/bin/env bash
# fetch-kernel.sh - baixa o kernel Linux do Kata Containers e extrai o `vmlinux` do runtime sem Docker.
#
# Contrato
#   Entrada : env RACKY_KATA_VERSION (padrão 3.32.0: o kernel 6.18.x com virtio-vsock/virtiofs/cgroup v2 que passou o fluxo completo do
#             spike), RACKY_VZ_OUT (padrão build/vz-assets), RACKY_KATA_URL (sobrescreve a URL do tarball).
#   Efeitos : baixa kata-static-<versão>-arm64.tar.zst (~650 MB, retomável com curl -C -) para <OUT>/.cache, extrai SÓ o vmlinux e o
#             .config do kernel e grava em <OUT>:
#               vmlinux               o kernel (arm64, descomprimido: o que `Kernel(path:)` da apple/containerization carrega)
#               vmlinux.config        a configuração do kernel (obrigação da GPL: fonte + config)
#               KERNEL-SOURCE.txt     URL do fonte (kata-containers e kernel.org) e a versão
#   Licença : o kernel é GPL-2.0-only. O app o distribui como arquivo separado (baixado), nunca embutido no binário; o manifesto aponta
#             o fonte. Quem republicar o `vmlinux` deve publicar também `vmlinux.config` e o link do fonte (KERNEL-SOURCE.txt).
#   Requer  : curl, zstd (brew install zstd), tar, shasum.
# Uso: scripts/vz/fetch-kernel.sh [--out DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RACKY_VZ_OUT:-$ROOT/build/vz-assets}"
VERSION="${RACKY_KATA_VERSION:-3.32.0}"
URL="${RACKY_KATA_URL:-https://github.com/kata-containers/kata-containers/releases/download/$VERSION/kata-static-$VERSION-arm64.tar.zst}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uso inválido: $1" >&2; exit 2 ;;
  esac
done
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v zstd >/dev/null 2>&1 || { echo "zstd não encontrado (brew install zstd)" >&2; exit 1; }
CACHE="$OUT/.cache"
mkdir -p "$CACHE"
TARBALL="$CACHE/kata-static-$VERSION-arm64.tar.zst"

echo "download: $URL"
curl -fL --retry 3 -C - -o "$TARBALL" "$URL"

WORK="$(mktemp -d "$CACHE/extract.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
echo "extraindo vmlinux e config de $TARBALL"
# O tarball tem ./opt/kata/share/kata-containers/vmlinux-<ver>-<n> (+ links vmlinux.container) e config-<ver>-<n>.
zstd -dc "$TARBALL" | tar -x -C "$WORK" --include '*/kata-containers/vmlinux.container' --include '*/kata-containers/vmlinux-[0-9.]*-[0-9]*' \
  --include '*/kata-containers/config-[0-9.]*-[0-9]*' 2>/dev/null || true
KERNEL="$(find "$WORK" \( -type f -o -type l \) -name 'vmlinux.container' | head -n 1)"
[ -n "$KERNEL" ] || { echo "vmlinux.container não encontrado no tarball" >&2; exit 1; }
# `vmlinux.container` é um link para `vmlinux-<kernel>-<n>`; o .config é o `config-<kernel>-<n>` do MESMO sabor.
TARGET="$(basename "$(readlink "$KERNEL" 2>/dev/null || basename "$KERNEL")")"
cp -L "$KERNEL" "$OUT/vmlinux"
CONFIG="$(find "$WORK" -type f -name "config-${TARGET#vmlinux-}" | head -n 1)"
if [ -n "$CONFIG" ]; then cp -L "$CONFIG" "$OUT/vmlinux.config"; else echo "aviso: config-${TARGET#vmlinux-} não encontrado no tarball" >&2; fi
KVER="$(echo "${TARGET#vmlinux-}" | sed -E 's/^([0-9]+(\.[0-9]+)+).*/\1/')"
{
  echo "https://github.com/kata-containers/kata-containers/tree/$VERSION/tools/packaging/kernel"
  echo "kata-containers $VERSION (arm64 static tarball): $URL"
  [ -z "$KVER" ] || echo "Linux $KVER: https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
  echo "License: GPL-2.0-only. Build configuration: vmlinux.config (published next to vmlinux)."
} > "$OUT/KERNEL-SOURCE.txt"
echo "vmlinux: $OUT/vmlinux ($(shasum -a 256 "$OUT/vmlinux" | cut -d' ' -f1))"
