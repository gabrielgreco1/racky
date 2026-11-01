#!/usr/bin/env bash
# make-dev-cert.sh - cria a identidade local "Racky Local Signing" (08 AR-530).
#
# Contrato
#   Efeitos : gera certificado autoassinado de code signing (RSA 2048, 10 anos), importa no keychain
#             de login e o marca como confiável para assinatura de código (a confiança pede a SENHA do
#             usuário numa janela do macOS; por isso o script nunca é executado por agentes/CI interativo).
#   Saída   : imprime o SHA-1 do certificado (usado no designated requirement por build.sh).
#   Idempotente: se a identidade já existe, só imprime o SHA-1.
#   --ephemeral : keychain temporário (CI), sem confiança de usuário nem prompt; imprime o caminho do keychain
#                 em RACKY_EPHEMERAL_KEYCHAIN=... e o SHA-1.
#   Sem esta identidade, build.sh assina ad-hoc ("-") e avisa (fallback documentado).
# Uso: scripts/make-dev-cert.sh [--ephemeral] [--help]
set -euo pipefail
NAME="Racky Local Signing"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
EPHEMERAL=0
for a in "$@"; do
  case "$a" in -h|--help) usage; exit 0 ;; --ephemeral) EPHEMERAL=1 ;; *) usage >&2; exit 2 ;; esac
done

sha_of() { security find-certificate -c "$NAME" -Z "${1:-}" 2>/dev/null | awk '/^SHA-1 hash:/{print $3; exit}'; }

if [ "$EPHEMERAL" = 0 ]; then
  KC="$HOME/Library/Keychains/login.keychain-db"
  if [ -n "$(sha_of "$KC")" ]; then echo "ok: identidade já existe"; sha_of "$KC"; exit 0; fi
else
  KC="${TMPDIR:-/tmp}/racky-ci-$$.keychain-db"
  PW="$(uuidgen)"
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings -lut 3600 "$KC"
  security unlock-keychain -p "$PW" "$KC"
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12PW="$(uuidgen)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$P12PW" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$P12PW"
security import "$WORK/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign
if [ "$EPHEMERAL" = 1 ]; then
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
  echo "RACKY_EPHEMERAL_KEYCHAIN=$KC"
else
  # Pede a senha do usuário (janela do macOS). Marca o certificado como confiável só para code signing.
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$WORK/cert.pem"
fi
sha_of "$KC"
