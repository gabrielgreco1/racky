#!/usr/bin/env bash
# lint-ui.sh - proibições de UI do rebuild (08 AR-131/AR-805, 09 §2.4, 02 DS). Implementado em T1-02.
#
# Contrato
#   Entrada : código SwiftUI novo em Packages/*/Sources/RackyUI, Packages/*/Sources/RackyDesignSystem e App/ (nunca legacy/).
#             Env: LINT_ROOT (raiz; padrão = repositório).
#   Falha em : .sheet( / NSAlert (T5: modais são overlays); List( ; Form( ; Color(hex: fora de RackyDesignSystem/Tokens;
#              literais numéricos em .padding( / .frame( (use DS.Space); LocalProcessTerminalView; emojis;
#              Button( / .onTapGesture / NSButton( / NSMenuItem( cujo gatilho não chame ...perform( do ActionRegistry
#              NSMenu / .contextMenu / Menu { } fora de MenuBar/ e Shell/MainMenu.swift (menus de contexto usam DSMenuPanel, F17);
#              (use ActionButton); accessibilityIdentifier("literal") (use .a11y(A11yID)); strings de Text( / Label( / TextField(
#              ausentes do String Catalog (RackyUI/Resources/Localizable.xcstrings); A11yID/ActionID defasados da spec
#              (scripts/gen-automation-ids.py --check).
#   Exceção  : comentário `// lint-ui: allow <regra> <motivo>` na mesma linha ou na anterior.
#   Self-test: --self-test roda um caso que DEVE falhar e um que DEVE passar para cada regra.
#   Saída   : exit 0 em sucesso; exit 1 em violação; exit 2 uso inválido.
# Uso: scripts/lint-ui.sh [--self-test] [--help]
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

SELF_TEST=0
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --self-test) SELF_TEST=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v rg >/dev/null 2>&1 || { echo "ERRO: rg (ripgrep) não encontrado" >&2; exit 1; }

CATALOG_REL="Packages/RackyKit/Sources/RackyUI/Resources/Localizable.xcstrings"
VIOLATIONS=0
SCAN=""

# matches REGEX [globs...] -> "arquivo:linha:texto", sem linhas só de comentário e sem linhas com exceção `lint-ui: allow`
matches() {
  local re="$1"; shift
  local globs=() g d dirs=()
  for g in "$@"; do globs+=(-g "$g"); done
  for d in $SCAN; do dirs+=("$d"); done
  [ ${#dirs[@]} -gt 0 ] || return 0
  (cd "$ROOT" && rg -nP --no-heading -t swift ${globs[@]+"${globs[@]}"} -e "$re" "${dirs[@]}" 2>/dev/null || true) \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v 'lint-ui: allow' || true
}

report() { # regra mensagem linhas
  [ -n "$3" ] || return 0
  echo "lint-ui: [$1] $2" >&2
  echo "$3" | sed 's/^/    /' >&2
  VIOLATIONS=$((VIOLATIONS + $(echo "$3" | grep -c .)))
}

rule() { local n="$1" d="$2" re="$3"; shift 3; report "$n" "$d" "$(matches "$re" "$@")"; }

# Exceção na linha anterior: remove ocorrências cuja linha anterior tem `lint-ui: allow`.
drop_allowed_prev() {
  local line file ln out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"; ln="${line#*:}"; ln="${ln%%:*}"
    if [ "$ln" -gt 1 ] && sed -n "$((ln - 1))p" "$ROOT/$file" | grep -q 'lint-ui: allow'; then continue; fi
    out+="$line"$'\n'
  done
  printf '%s' "${out%$'\n'}"
}

# Todo gatilho de controle precisa chamar ...perform( do registro nas 4 linhas seguintes.
button_rule() {
  local bad="" line file ln
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"; ln="${line#*:}"; ln="${ln%%:*}"
    if ! sed -n "${ln},$((ln + 4))p" "$ROOT/$file" | grep -qE 'perform(FromUI)?\('; then bad+="$line"$'\n'; fi
  done <<< "$(matches '(?<![\w.])Button\s*[({]|\.onTapGesture\b|\bNSButton\s*\(|\bNSMenuItem\s*\(' | drop_allowed_prev)"
  report buttons "controle fora do ActionRegistry: o gatilho deve chamar registry.perform(.<id>) (use ActionButton)" "${bad%$'\n'}"
}

catalog_rule() {
  local lits catalog="$ROOT/$CATALOG_REL"
  lits="$(cd "$ROOT" && for d in $SCAN; do echo "$d"; done | xargs -I{} rg -nP --no-heading -o -t swift \
    '(?<![\w.])(?:Text|Label|TextField|SecureField)\(\s*"([^"\\]*)"' -r '$1' {} 2>/dev/null || true)"
  [ -n "$lits" ] || return 0
  if [ ! -f "$catalog" ]; then
    report strings "String Catalog ausente ($CATALOG_REL) e há strings de UI" "$lits"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { echo "ERRO: python3 não encontrado (necessário para ler o String Catalog)" >&2; VIOLATIONS=$((VIOLATIONS + 1)); return 0; }
  local keys bad="" line text
  keys="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("strings",{}).keys()))' "$catalog")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    text="${line#*:}"; text="${text#*:}"
    [ -n "$text" ] || continue
    printf '%s\n' "$keys" | grep -qxF -- "$text" || bad+="$line"$'\n'
  done <<< "$lits"
  report strings "string de UI fora do String Catalog ($CATALOG_REL)" "${bad%$'\n'}"
}

run_rules() {
  SCAN="$(cd "$ROOT" && ls -d Packages/*/Sources/RackyUI Packages/*/Sources/RackyDesignSystem App 2>/dev/null | tr '\n' ' ' || true)"
  local TOK='!**/RackyDesignSystem/Tokens/**'

  rule sheet ".sheet( / NSAlert em fluxo normal (modais são overlays, 00 T5)" '\.sheet\(|\bNSAlert\b'
  rule list "List( (use LazyVStack/ScrollView desenhado à mão)" '(?<![\w.])List\s*[({]'
  rule form "Form( (use componentes do DesignSystem)" '(?<![\w.])Form\s*[({]'
  rule color-hex "Color(hex: fora de RackyDesignSystem/Tokens (use DS.Color)" '\bColor\(\s*hex:' "$TOK"
  rule literals "literal numérico em .padding( / .frame( (use DS.Space)" '\.(?:padding|frame)\([^)\n]*(?<![\w.])\d+(?:\.\d+)?(?![\w.])' "$TOK"
  rule terminal-view "LocalProcessTerminalView (T6)" '\bLocalProcessTerminalView\b'
  rule emoji "emoji em código de UI (use SF Symbols/ícones do DS)" '[\x{1F000}-\x{1FAFF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}\x{FE0F}]'
  rule native-menus "NSMenu / .contextMenu / Menu { } nativo fora da barra de menus do app (F17: use DSMenuPanel / dsContextMenu)" '\bNSMenu\b|\.contextMenu\b|(?<![\w.])Menu\s*[({]|\.menuStyle\(' '!**/MenuBar/**' '!**/Shell/MainMenu.swift'
  rule a11y-literal "accessibilityIdentifier com string literal (use .a11y(A11yID))" 'accessibilityIdentifier\(\s*"'
  button_rule
  catalog_rule

  # A11yID/ActionID gerados precisam bater com a spec (só no repositório real).
  if [ -z "${LINT_ROOT:-}" ] && [ -f "$ROOT/scripts/gen-automation-ids.py" ]; then
    local out
    if ! out="$(python3 "$ROOT/scripts/gen-automation-ids.py" --check 2>&1)"; then
      echo "lint-ui: [ids] $out" >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi
}

# --- self-test: um caso que falha e um que passa por regra ------------------------------------------
if [ "$SELF_TEST" = 1 ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  fails=0
  expect() { # nome caminho conteúdo resultado(fail|pass) [catálogo-json]
    local name="$1" path="$2" body="$3" want="$4" cat="${5:-}" rc=0
    rm -rf "$T/r"; mkdir -p "$T/r/$(dirname "$path")" "$T/r/$(dirname "$CATALOG_REL")"
    printf '%s\n' "$body" > "$T/r/$path"
    printf '%s\n' "${cat:-{\"strings\":{\"Hello\":{}}}}" > "$T/r/$CATALOG_REL"
    LINT_ROOT="$T/r" "$SELF" >/dev/null 2>&1 || rc=$?
    local got=pass; [ "$rc" -ne 0 ] && got=fail
    if [ "$got" = "$want" ]; then echo "ok: $name ($want)"; else echo "FALHOU: $name esperado=$want obtido=$got" >&2; fails=$((fails+1)); fi
  }
  U=Packages/RackyKit/Sources/RackyUI/V.swift
  TK=Packages/RackyKit/Sources/RackyDesignSystem/Tokens/C.swift
  expect sheet-bad $U 'Text("Hello").sheet(isPresented: b) {}' fail
  expect nsalert-bad $U 'let a = NSAlert()' fail
  expect list-bad $U 'List { Text("Hello") }' fail
  expect list-call-bad $U 'let v = List(items) { _ in EmptyView() }' fail
  expect lazyvstack-ok $U 'LazyVStack { Text("Hello") }' pass
  expect form-bad $U 'Form { }' fail
  expect color-hex-bad $U 'let c = Color(hex: 0xFFFFFF)' fail
  expect color-hex-tokens-ok $TK 'let c = Color(hex: 0xFFFFFF)' pass
  expect padding-literal-bad $U 'Text("Hello").padding(8)' fail
  expect padding-edge-literal-bad $U 'Text("Hello").padding(.horizontal, 12)' fail
  expect frame-literal-bad $U 'Color.clear.frame(width: 100, height: 20)' fail
  expect padding-ds-ok $U 'Text("Hello").padding(DS.Space.s2)' pass
  expect padding-default-ok $U 'Text("Hello").padding()' pass
  expect frame-infinity-ok $U 'Color.clear.frame(maxWidth: .infinity)' pass
  expect terminal-view-bad $U 'let v = LocalProcessTerminalView(frame: .zero)' fail
  expect emoji-bad $U 'let s = "ok 🚀"' fail
  expect shortcut-glyph-ok $U 'let s = "⌘N"' pass
  expect a11y-literal-bad $U 'Text("Hello").accessibilityIdentifier("x.y")' fail
  expect a11y-typed-ok $U 'Text("Hello").accessibilityIdentifier(id.rawValue)' pass
  expect button-loose-bad $U $'Button("Hello") {\n    doSomething()\n}' fail
  expect button-brace-bad $U $'Button {\n    doSomething()\n} label: { Text("Hello") }' fail
  expect button-registry-ok $U $'Button {\n    Task { _ = try? await registry.perform(.sessionNew, .press) }\n} label: { Text("Hello") }' pass
  expect action-button-ok $U 'ActionButton(.sessionNew, id: .tabsNew) { Text("Hello") }' pass
  expect button-allow-ok $U $'// lint-ui: allow buttons motivo\nButton("Hello") { }' pass
  expect tap-gesture-bad $U 'Text("Hello").onTapGesture { x() }' fail
  expect nsbutton-bad $U 'let b = NSButton(title: "x", target: nil, action: nil)' fail
  expect nsmenuitem-bad $U 'let m = NSMenuItem(title: "x", action: nil, keyEquivalent: "")' fail
  expect nsmenu-bad $U 'let m = NSMenu()' fail
  expect context-menu-bad $U 'Text("Hello").contextMenu { Text("Hello") }' fail
  expect swiftui-menu-bad $U 'Menu { Text("Hello") } label: { Text("Hello") }' fail
  expect menubar-nsmenu-ok Packages/RackyKit/Sources/RackyUI/MenuBar/M.swift 'let m = NSMenu()' pass
  expect dscontext-ok $U 'Text("Hello").dsContextMenu(name: "x", groups: { [] })' pass
  expect string-missing-bad $U 'Text("Not in catalog")' fail
  expect string-in-catalog-ok $U 'Text("Hello", bundle: .module)' pass
  expect string-verbatim-ok $U 'Text(verbatim: "Not in catalog")' pass
  expect comment-ignored $U '// Button("x") { } .sheet( List( is forbidden' pass
  [ "$fails" -eq 0 ] || { echo "lint-ui self-test: $fails falha(s)" >&2; exit 1; }
  echo "lint-ui self-test: OK"
  exit 0
fi

run_rules
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "lint-ui: FALHOU ($VIOLATIONS violação(ões))" >&2
  exit 1
fi
echo "lint-ui: OK"
