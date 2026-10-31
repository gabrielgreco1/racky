#!/usr/bin/env bash
# release.sh - gera o Racky.dmg para distribuição (app em Release, assinado, verificado, DMG UDZO com atalho para Applications). NÃO publica.
#
# Contrato
#   Entrada : versão semântica (ex.: 0.2.0, 1.0.0-rc1). Env: RACKY_SIGN_IDENTITY (nome do certificado, p.ex. "Developer ID Application: ...";
#             padrão "-" = ad-hoc), RACKY_NOTARY_PROFILE (perfil do `xcrun notarytool store-credentials`; sem ele a notarização é PULADA),
#             RACKY_BUILD_NUMBER (CFBundleVersion; padrão contagem de commits), RACKY_RELEASE_DIR (padrão build/release),
#             RACKY_REPO (padrão gabrielgreco1/racky; só aparece no comando impresso), RACKY_DMG_FINDER_LAYOUT=1 (pede ao Finder, por
#             AppleScript, o fundo e a posição dos ícones; exige permissão de Automação, por isso fica desligado por padrão).
#   Efeitos : scripts/build.sh (Release arm64, o runtime sem Docker só existe em Apple silicon) com CFBundleShortVersionString=<versão>,
#             hardened runtime e o entitlement de virtualização (App/Racky.entitlements); `codesign --verify --deep --strict`; confere
#             versão, entitlement e que o manifesto do runtime embutido já aponta para uma release (scripts/vz/stage-release.sh);
#             cria <RELEASE_DIR>/Racky.dmg (app + atalho /Applications, UDZO) e Racky.dmg.sha256. Com Developer ID usa carimbo de tempo
#             seguro e assina o DMG. Notariza e grampeia (stapler) se RACKY_NOTARY_PROFILE estiver definido.
#   Saída   : imprime o comando `gh release create v<versão> ...` (NÃO é executado). Sem push, sem upload, sem /Applications.
#   Aviso   : ad-hoc só serve para testar: o Gatekeeper pede "Abrir Mesmo Assim" (Ajustes › Privacidade e Segurança) e o daemon aceita
#             peers por uid (-DRACKY_ALLOW_ADHOC_PEERS, veja build.sh). Para distribuir de verdade, use Developer ID + notarização.
# Uso: scripts/release.sh <versão> [--skip-build] [--allow-placeholder-runtime] [--help]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "ERRO: $*" >&2; exit 1; }

VERSION=""; SKIP_BUILD=0; ALLOW_PLACEHOLDER=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --allow-placeholder-runtime) ALLOW_PLACEHOLDER=1 ;;
    -*) usage >&2; exit 2 ;;
    *) VERSION="$arg" ;;
  esac
done
[ -n "$VERSION" ] || { usage >&2; exit 2; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' || fail "versão inválida: $VERSION (esperado 1.2.3 ou 1.2.3-rc1)"
[ "$(uname -m)" = arm64 ] || fail "este script constrói para Apple silicon (arm64); rode num Mac M-series"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
REL="${RACKY_RELEASE_DIR:-$ROOT/build/release}"
REPO="${RACKY_REPO:-gabrielgreco1/racky}"
IDENTITY="${RACKY_SIGN_IDENTITY:--}"
BUILD_OUT="$REL/build"
APP="$BUILD_OUT/Racky.app"
DMG="$REL/Racky.dmg"
VOLNAME="Racky"
mkdir -p "$REL"

# O manifesto do runtime vai DENTRO do app: com placeholders, o primeiro computador de quem baixou o DMG não teria de onde baixar.
MANIFEST="$ROOT/runtime/vz-manifest.json"
if grep -Eq 'PLACEHOLDER|"version": *"unpublished"' "$MANIFEST"; then
  if [ "$ALLOW_PLACEHOLDER" = 1 ]; then echo "AVISO: runtime/vz-manifest.json ainda tem placeholders (--allow-placeholder-runtime)." >&2
  else fail "runtime/vz-manifest.json tem placeholders. Rode scripts/vz/fetch-kernel.sh, scripts/vz/build-image.sh e scripts/vz/stage-release.sh, publique a release runtime-* e commite o manifesto."; fi
fi

if [ "$SKIP_BUILD" = 0 ]; then
  echo "release: build $VERSION (assinatura: $([ "$IDENTITY" = - ] && echo ad-hoc || echo "$IDENTITY"))"
  export RACKY_SIGN_IDENTITY="$IDENTITY"
  export RACKY_MARKETING_VERSION="$VERSION"
  export RACKY_BUILD_DIR="$BUILD_OUT"
  if [ "$IDENTITY" != "-" ]; then export RACKY_SIGN_TIMESTAMP=1; fi
  "$ROOT/scripts/build.sh"
fi
[ -d "$APP" ] || fail "app não encontrado em $APP"
PLIST="$APP/Contents/Info.plist"

# --- verificações do bundle ---------------------------------------------------------------------------------------------------
GOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
GOT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[ "$GOT_VERSION" = "$VERSION" ] || fail "CFBundleShortVersionString é '$GOT_VERSION', esperado '$VERSION'"
echo "release: CFBundleShortVersionString=$GOT_VERSION CFBundleVersion=$GOT_BUILD"
lipo -archs "$APP/Contents/MacOS/Racky" | grep -qw arm64 || fail "o executável do app não tem arm64 (o runtime nativo só roda em Apple silicon)"
echo "release: arquiteturas: $(lipo -archs "$APP/Contents/MacOS/Racky")"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign --verify --deep --strict falhou"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.security.virtualization' || fail "o app não tem o entitlement com.apple.security.virtualization"
FLAGS="$(codesign -dv "$APP" 2>&1 | grep -E '^CodeDirectory' || true)"
echo "$FLAGS" | grep -q 'runtime' || fail "hardened runtime ausente na assinatura do app ($FLAGS)"
echo "release: assinatura verificada (--deep --strict), hardened runtime e entitlement de virtualização presentes"
cmp -s "$MANIFEST" "$APP/Contents/Resources/runtime/vz-manifest.json" || fail "o manifesto dentro do app difere de runtime/vz-manifest.json (rebuild sem --skip-build)"

# --- DMG ----------------------------------------------------------------------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/racky-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"; hdiutil detach "/Volumes/$VOLNAME" -quiet >/dev/null 2>&1 || true' EXIT
ditto "$APP" "$STAGE/Racky.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG" "$DMG.sha256" "$REL/rw.dmg"
if [ "${RACKY_DMG_FINDER_LAYOUT:-0}" = 1 ]; then
  echo "release: layout do Finder (pode pedir permissão de Automação)"
  mkdir "$STAGE/.background"
  swift "$ROOT/scripts/dmg-background.swift" "$STAGE/.background/background.png" "$ROOT/App/Racky.icns"
  hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -ov "$REL/rw.dmg" >/dev/null
  hdiutil attach "$REL/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOLNAME" >/dev/null
  perl -e 'alarm 40; exec @ARGV' osascript <<OSA || echo "AVISO: o Finder não arrumou a janela; o DMG segue sem fundo." >&2
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:background.png"
    set position of item "Racky.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    close
  end tell
end tell
OSA
  sync
  hdiutil detach "/Volumes/$VOLNAME" -quiet
  hdiutil convert "$REL/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -f "$REL/rw.dmg"
else
  hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
fi
if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null || fail "hdiutil verify falhou"

# --- notarização (só com RACKY_NOTARY_PROFILE) --------------------------------------------------------------------------------
if [ -n "${RACKY_NOTARY_PROFILE:-}" ]; then
  [ "$IDENTITY" != "-" ] || fail "RACKY_NOTARY_PROFILE exige uma identidade Developer ID em RACKY_SIGN_IDENTITY"
  echo "release: notarizando (perfil $RACKY_NOTARY_PROFILE; leva alguns minutos)"
  xcrun notarytool submit "$DMG" --keychain-profile "$RACKY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "release: notarização PULADA (defina RACKY_NOTARY_PROFILE para notarizar; sem ela o Gatekeeper pede 'Abrir Mesmo Assim')"
fi

( cd "$REL" && shasum -a 256 Racky.dmg > Racky.dmg.sha256 )
SIZE="$(stat -f %z "$DMG")"
echo "release: OK -> $DMG ($SIZE bytes)"
cat "$DMG.sha256"

PRERELEASE=""
case "$VERSION" in *-*) PRERELEASE=" --prerelease" ;; esac

cat <<EOF

# ---------------------------------------------------------------------------------------------------------
# NADA DISTO FOI EXECUTADO. Antes: a release do runtime (runtime-*) precisa existir no GitHub (scripts/vz/stage-release.sh).
# Para publicar o app (você roda):
# ---------------------------------------------------------------------------------------------------------
gh release create "v$VERSION" "$DMG" "$DMG.sha256" "$ROOT/site/install.sh" --repo "$REPO" --title "Racky $VERSION" --generate-notes$PRERELEASE
EOF
