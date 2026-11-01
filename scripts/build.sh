#!/usr/bin/env bash
# build.sh - gen + build Release + embute helpers + assina + verifica (08 AR-901).
#
# Contrato
#   Entrada : project.yml, Packages/RackyKit. Env: DEVELOPER_DIR, RACKY_SIGN_IDENTITY (nome do
#             certificado; padrão "Racky Local Signing"; "-" força ad-hoc), RACKY_SIGN_KEYCHAIN (caminho de um
#             keychain efêmero de CI: procura e assina por nome nele, sem confiança de usuário), RACKY_BUILD_DIR (padrão build/Racky),
#             RACKY_MARKETING_VERSION (CFBundleShortVersionString; padrão o MARKETING_VERSION do project.yml), RACKY_BUILD_NUMBER
#             (CFBundleVersion; padrão a contagem de commits), RACKY_SIGN_TIMESTAMP=1 (carimbo de tempo seguro da Apple no codesign;
#             necessário para notarizar com Developer ID; padrão --timestamp=none, funciona offline).
#   Efeitos : embute o plist do LaunchAgent do daemon (Contents/Library/LaunchAgents); compila o app (xcodebuild Release, Swift 6 estrito, warnings como erro) e os executáveis SPM
#             racky/rackyd (swift build -c release), embute-os em Contents/MacOS e Contents/Helpers e assina de dentro
#             para fora (racky, rackyd, app), SEM --deep, com --options runtime. Só o APP leva entitlement
#             (App/Racky.entitlements: com.apple.security.virtualization, as VMs do runtime sem Docker vivem no app); os helpers não.
#   Assinatura: com a identidade local, designated requirement = identifier "<id>" and certificate leaf = H"<sha1>".
#             Sem a identidade (make-dev-cert.sh ainda não rodado) cai para ad-hoc ("-"), com AVISO; o DR é
#             então cdhash e muda a cada build (perde ACL do Keychain/TCC; ver 08 AR-530).
#   Saída   : "<RACKY_BUILD_DIR>/Racky.app" verificado com codesign --verify --strict; exit != 0 em falha.
# Uso: scripts/build.sh [--help]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
fail() { echo "ERRO: $*" >&2; exit 1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="${RACKY_BUILD_DIR:-$ROOT/build/Racky}"
APP="$OUT/Racky.app"
DD="$OUT/DerivedData"
IDENT_NAME="${RACKY_SIGN_IDENTITY:-Racky Local Signing}"
cd "$ROOT"

"$ROOT/scripts/gen.sh"

BUILD_NUMBER="${RACKY_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
VERSION_ARGS=()
if [ -n "${RACKY_MARKETING_VERSION:-}" ]; then VERSION_ARGS=(MARKETING_VERSION="$RACKY_MARKETING_VERSION"); fi
TS_FLAG="--timestamp=none"
if [ "${RACKY_SIGN_TIMESTAMP:-0}" = 1 ]; then TS_FLAG="--timestamp"; fi
mkdir -p "$OUT"

# SWIFT_ENABLE_EXPLICIT_MODULES=NO: o RackyVZ importa a apple/containerization, cuja cadeia puxa o módulo `libzstd` (zstd 1.5.7); com módulos
# explícitos o xcodebuild recusa o import ("definition of configuration macro ZSTD... has no effect"). Com implícitos compila.
echo "build: xcodebuild Release (app)"
xcodebuild -project Racky.xcodeproj -scheme Racky -configuration Release \
  -derivedDataPath "$DD" -skipPackagePluginValidation -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} SWIFT_ENABLE_EXPLICIT_MODULES=NO build \
  | { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi; } \
  > "$OUT/xcodebuild.log" 2>&1 || { tail -40 "$OUT/xcodebuild.log" >&2; fail "xcodebuild falhou (log: $OUT/xcodebuild.log)"; }
tail -3 "$OUT/xcodebuild.log"

# Identidade de assinatura
IDENT="-"; SHA=""; SIGN_KEYCHAIN="${RACKY_SIGN_KEYCHAIN:-}"
if [ "$IDENT_NAME" != "-" ]; then
  SHA="$(security find-certificate -c "$IDENT_NAME" -Z ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null | awk '/^SHA-1 hash:/{print $3; exit}' || true)"
  if [ -n "$SHA" ]; then IDENT="$SHA"; fi
  # Sem o certificado local e sem identidade explícita: usa a primeira "Apple Development" válida do Keychain do dono.
  if [ -z "$SHA" ] && [ -z "${RACKY_SIGN_IDENTITY:-}" ] && [ -z "$SIGN_KEYCHAIN" ]; then
    DEV_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development:' || true)"
    if [ -n "$DEV_LINE" ]; then
      SHA="$(echo "$DEV_LINE" | awk '{print $2}')"; IDENT="$SHA"
      IDENT_NAME="$(echo "$DEV_LINE" | sed -E 's/.*"(.*)".*/\1/')"
      echo "build: assinando com '$IDENT_NAME'"
    fi
  fi
fi
if [ "$IDENT" = "-" ]; then
  echo "AVISO: identidade '$IDENT_NAME' ausente; assinando AD-HOC (rode scripts/make-dev-cert.sh uma vez para assinatura estável)." >&2
fi


# Peer auth (S-03/T1-07): o daemon ad-hoc só aceita peers do mesmo uid se o build o permitir explicitamente
# (flag de compilação; o daemon ainda confere que ele próprio é ad-hoc). Com certificado, a flag não é passada.
SWIFT_EXTRA=()
if [ "$IDENT" = "-" ]; then SWIFT_EXTRA=(-Xswiftc -DRACKY_ALLOW_ADHOC_PEERS); fi

echo "build: swift build -c release (racky, rackyd, rackyd-launch)"
for prod in racky rackyd rackyd-launch; do
  swift build -c release --package-path Packages/RackyKit --product "$prod" ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"}
done
BIN="$(swift build -c release --package-path Packages/RackyKit --show-bin-path)"

rm -rf "$APP"
ditto "$DD/Build/Products/Release/Racky.app" "$APP"
# APFS é case-insensitive: o executável do app ("Racky") colidiria com o helper "racky" em Contents/MacOS; o helper vive em Contents/Helpers.
mkdir -p "$APP/Contents/Helpers"
[ ! -e "$APP/Contents/Helpers/racky" ] || fail "Contents/Helpers/racky já existe antes de embutir o helper"
install -m 755 "$BIN/racky" "$APP/Contents/Helpers/racky"
install -m 755 "$BIN/rackyd" "$APP/Contents/MacOS/rackyd"
# Launcher estável do LaunchAgent (T1-24/S-01): o launchd prende o job ao cdhash do BundleProgram, então o job é registrado com
# este binário minúsculo (só faz exec do rackyd) e as atualizações do daemon não exigem novo registro. Símbolos removidos
# (strip -S -x) para o cdhash não depender de caminhos de build; o identificador de assinatura é fixo.
install -m 755 "$BIN/rackyd-launch" "$APP/Contents/MacOS/rackyd-launch"
strip -S -x "$APP/Contents/MacOS/rackyd-launch"
# LaunchAgent do daemon (T1-24, 08 §0.1): plist em Contents/Library/LaunchAgents, __BUILD__ = CFBundleVersion. Selado pela
# assinatura do app (assinar o app por último).
mkdir -p "$APP/Contents/Library/LaunchAgents"
sed "s/__BUILD__/$BUILD_NUMBER/g" "$ROOT/App/LaunchAgents/app.racky.ptyd.v1.plist" > "$APP/Contents/Library/LaunchAgents/app.racky.ptyd.v1.plist"
plutil -lint "$APP/Contents/Library/LaunchAgents/app.racky.ptyd.v1.plist" >/dev/null || fail "plist do LaunchAgent inválido"

# Contexto de build da imagem única do computador (F12, P24): a primeira reserva de um computador constrói as imagens a partir daqui
# (`RuntimeContextLocator`). Dados dentro de Contents/Resources: selados pela assinatura do app.
mkdir -p "$APP/Contents/Resources/runtime"
for ctx in computer; do
  rm -rf "$APP/Contents/Resources/runtime/$ctx"
  ditto "$ROOT/runtime/$ctx" "$APP/Contents/Resources/runtime/$ctx"
  # Os testes do runtime ficam no repositório; o app não precisa deles.
  rm -rf "$APP/Contents/Resources/runtime/$ctx/tests"
done
# Manifesto dos arquivos do runtime sem Docker (kernel, vminit, imagem): URLs e sha256 (placeholders até a publicação).
cp "$ROOT/runtime/vz-manifest.json" "$APP/Contents/Resources/runtime/vz-manifest.json"
find "$APP/Contents/Resources/runtime" \( -name .DS_Store -o -name '*.pyc' -o -name __pycache__ \) -prune -exec rm -rf {} + 2>/dev/null || true

SIGN_REF="$IDENT"; [ -z "$SIGN_KEYCHAIN" ] || SIGN_REF="$IDENT_NAME"
sign() { # path identifier [entitlements.plist]
  if [ "$IDENT" = "-" ]; then
    codesign --force --options runtime --timestamp=none --sign - --identifier "$2" ${3:+--entitlements "$3"} "$1"
  else
    # Certificado efêmero/autoassinado sem confiança de usuário: o codesign só o acha por NOME + --keychain (S-03).
    codesign --force --options runtime $TS_FLAG --sign "$SIGN_REF" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} --identifier "$2" \
      ${3:+--entitlements "$3"} -r="designated => identifier \"$2\" and certificate leaf = H\"$SHA\"" "$1"
  fi
}
sign "$APP/Contents/Helpers/racky" app.racky.cli
sign "$APP/Contents/MacOS/rackyd" app.racky.ptyd
sign "$APP/Contents/MacOS/rackyd-launch" app.racky.ptyd.launch
sign "$APP" app.racky.mac "$ROOT/App/Racky.entitlements"

echo "build: verificando assinatura"
codesign --verify --strict --verbose=2 "$APP"
for pair in "$APP/Contents/Helpers/racky:app.racky.cli" "$APP/Contents/MacOS/rackyd:app.racky.ptyd" "$APP/Contents/MacOS/rackyd-launch:app.racky.ptyd.launch" "$APP:app.racky.mac"; do
  p="${pair%%:*}"; id="${pair##*:}"
  codesign --verify --strict "$p"
  dr="$(codesign -dr - "$p" 2>&1 | grep 'designated =>' || true)"
  if [ "$IDENT" = "-" ]; then
    case "$dr" in *"cdhash H"*) ;; *) fail "DR inesperado para $p: $dr" ;; esac
  else
    want="designated => identifier \"$id\" and certificate leaf = H\"$SHA\""
    [ "$(printf '%s' "$dr" | tr 'A-F' 'a-f')" = "$(printf '%s' "$want" | tr 'A-F' 'a-f')" ] || fail "DR inesperado para $p: $dr (esperado: $want)"
  fi
done
codesign -dv "$APP" 2>&1 | grep -E 'flags=|Identifier=' || true
# O Dock guarda o ícone por caminho: sem re-registrar, um bundle reconstruído no mesmo lugar aparece com o ícone genérico.
touch "$APP"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
# A cópia intermediária do xcodebuild tem o mesmo bundle id: sem tirá-la do LaunchServices, o Dock pode abrir ela (fora do lugar,
# sem achar o daemon: "The background service isn't running").
"$LSREG" -u "$DD/Build/Products/Release/Racky.app" >/dev/null 2>&1 || true
echo "build: OK -> $APP"
