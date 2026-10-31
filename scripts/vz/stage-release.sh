#!/usr/bin/env bash
# stage-release.sh - prepara os arquivos do runtime sem Docker para um GitHub Release e reescreve runtime/vz-manifest.json. NÃO publica nada.
#
# Contrato
#   Entrada : arquivos locais de scripts/vz/fetch-kernel.sh + scripts/vz/build-image.sh em <OUT> (vmlinux, vmlinux.config, KERNEL-SOURCE.txt,
#             vminit.oci.tar, computer.oci.tar, vz-manifest.json). Argumento opcional <versão> (padrão: "1-<hash do contexto da imagem>").
#             Env: RACKY_VZ_OUT (padrão build/vz-assets), RACKY_VZ_REPO (padrão gabrielgreco1/racky), RACKY_RELEASE_DIR (padrão build/release).
#   Efeitos : copia os arquivos para <RELEASE_DIR>/runtime-<versão>/, calcula sha256 e tamanho de cada um (SHA256SUMS ao lado) e REESCREVE
#             runtime/vz-manifest.json com as URLs
#               https://github.com/<repo>/releases/download/runtime-<versão>/<arquivo>
#             em JSON determinístico (mesma entrada, mesmos bytes). Também grava o manifesto final na pasta, ao lado dos arquivos.
#   Saída   : na tela, o comando exato `gh release create runtime-<versão> ...` (NÃO é executado) e o texto das notas, com o fonte e a
#             configuração do kernel (GPL-2.0). Publicar é decisão do dono.
#   Depois  : commite runtime/vz-manifest.json ANTES de scripts/release.sh (o manifesto vai dentro do app).
# Uso: scripts/vz/stage-release.sh [versão] [--help]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${RACKY_VZ_OUT:-$ROOT/build/vz-assets}"
REPO="${RACKY_VZ_REPO:-gabrielgreco1/racky}"
RELEASE_DIR="${RACKY_RELEASE_DIR:-$ROOT/build/release}"
VERSION=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "uso inválido: $arg" >&2; exit 2 ;;
    *) VERSION="$arg" ;;
  esac
done
for f in vmlinux vmlinux.config KERNEL-SOURCE.txt vminit.oci.tar computer.oci.tar vz-manifest.json; do
  [ -f "$OUT/$f" ] || { echo "falta $OUT/$f: rode scripts/vz/fetch-kernel.sh e scripts/vz/build-image.sh" >&2; exit 1; }
done
if [ -z "$VERSION" ]; then
  VERSION="$(python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))["version"]; print("1-" + (v[4:] if v.startswith("dev-") else v))' "$OUT/vz-manifest.json")"
fi
case "$VERSION" in *[!A-Za-z0-9._-]*|"") echo "versão inválida: $VERSION (use letras, números, ponto, hífen)" >&2; exit 2 ;; esac
TAG="runtime-$VERSION"
DEST="$RELEASE_DIR/$TAG"
BASE="https://github.com/$REPO/releases/download/$TAG"
rm -rf "$DEST"; mkdir -p "$DEST"
for f in vmlinux vmlinux.config KERNEL-SOURCE.txt vminit.oci.tar computer.oci.tar; do
  cp "$OUT/$f" "$DEST/$f"
done

# Manifesto (determinístico: ordem fixa das chaves, indent 2, uma quebra de linha no fim) + SHA256SUMS.
python3 -I - "$OUT/vz-manifest.json" "$DEST" "$BASE" "$VERSION" "$ROOT/runtime/vz-manifest.json" <<'PY'
import hashlib, json, os, sys
local, dest, base, version, baked = sys.argv[1:6]
src = json.load(open(local))

def digest(name):
    h = hashlib.sha256()
    with open(os.path.join(dest, name), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest(), os.path.getsize(os.path.join(dest, name))

def entry(name, key, extra):
    sha, size = digest(name)
    out = {"url": base + "/" + name, "sha256": sha, "size": size}
    out.update(extra)
    return out

kernel_source = open(os.path.join(dest, "KERNEL-SOURCE.txt")).read().strip().splitlines()[0]
manifest = {
    "schema": src["schema"],
    "version": version,
    "kernel": entry("vmlinux", "kernel", {"license": "GPL-2.0-only", "sourceURL": kernel_source}),
    "vminit": entry("vminit.oci.tar", "vminit", {"reference": src["vminit"]["reference"]}),
    "computer": entry("computer.oci.tar", "computer", {"reference": src["computer"]["reference"]}),
}
text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
open(baked, "w").write(text)
open(os.path.join(dest, "vz-manifest.json"), "w").write(text)
names = ["vmlinux", "vmlinux.config", "KERNEL-SOURCE.txt", "vminit.oci.tar", "computer.oci.tar", "vz-manifest.json"]
with open(os.path.join(dest, "SHA256SUMS"), "w") as f:
    for n in names:
        f.write("%s  %s\n" % (digest(n)[0], n))
total = sum(manifest[k]["size"] for k in ("kernel", "vminit", "computer"))
print("download no primeiro uso: %.0f MB (%d bytes)" % (total / 1e6, total), file=sys.stderr)
PY

NOTES="Racky computer runtime $VERSION: the files Racky downloads once, on first use of a computer (no Docker needed).

- vmlinux: Linux kernel (arm64) from Kata Containers 3.32.0, GPL-2.0-only. It is a separate file, never linked into Racky.
- vmlinux.config: the exact kernel build configuration (published next to the binary as the GPL requires).
- KERNEL-SOURCE.txt: where to get the corresponding source.
- vminit.oci.tar: guest init from apple/containerization (ghcr.io/apple/containerization/vminit, Apache-2.0).
- computer.oci.tar: the slim computer image (python:3.12-slim-bookworm, Chromium, Racky supervisor).
- vz-manifest.json: the manifest baked into the app (URL, sha256, size of each file). SHA256SUMS lists the same hashes.

Kernel source and configuration (GPL-2.0-only):
$(sed 's/^/  /' "$DEST/KERNEL-SOURCE.txt")"

printf '%s\n' "$NOTES" > "$DEST/RELEASE-NOTES.md"

echo "staged: $DEST"
ls -l "$DEST"
cat <<EOF

# ---------------------------------------------------------------------------------------------------------
# NADA DISTO FOI EXECUTADO. runtime/vz-manifest.json já foi reescrito: confira o diff e commite antes do DMG.
#   git diff runtime/vz-manifest.json && git add runtime/vz-manifest.json && git commit -m "Point the runtime manifest at $TAG"
# Para publicar (você roda):
# ---------------------------------------------------------------------------------------------------------
gh release create "$TAG" --repo "$REPO" --title "Racky computer runtime $VERSION" --notes-file "$DEST/RELEASE-NOTES.md" \\
  "$DEST/vmlinux" "$DEST/vmlinux.config" "$DEST/KERNEL-SOURCE.txt" "$DEST/vminit.oci.tar" "$DEST/computer.oci.tar" \\
  "$DEST/vz-manifest.json" "$DEST/SHA256SUMS"

# Notas da release (também em $DEST/RELEASE-NOTES.md):
$NOTES
EOF
