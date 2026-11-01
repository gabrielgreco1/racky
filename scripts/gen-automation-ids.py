#!/usr/bin/env python3
"""gen-automation-ids.py - gera A11yID e ActionID a partir da spec (T1-02).

Contrato
  Entrada : docs/rebuild/spec/03-screens.md  (§22 índice de accessibilityIdentifier; §24 tabela de ações).
  Saída   : Packages/RackyKit/Sources/RackyProtocol/Automation/A11yID.generated.swift
            Packages/RackyKit/Sources/RackyProtocol/Automation/ActionID.generated.swift
            docs/automation-ids.md   (AR-805)
            Determinístico. --check falha (exit 1) se os arquivos gerados estão defasados da spec.
  Exit    : 0 sucesso; 1 --check defasado; 2 erro de parsing/uso.
Uso: scripts/gen-automation-ids.py [--check] [--help]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "docs/rebuild/spec/03-screens.md"
OUT_DIR = ROOT / "Packages/RackyKit/Sources/RackyProtocol/Automation"
OUT_A11Y = OUT_DIR / "A11yID.generated.swift"
OUT_ACTION = OUT_DIR / "ActionID.generated.swift"
OUT_DOC = ROOT / "docs/automation-ids.md"

SWIFT_KEYWORDS = {
    "default", "init", "self", "repeat", "return", "switch", "case", "in", "is", "as", "do", "for", "if",
    "else", "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "true", "false",
    "nil", "super", "where", "while", "break", "continue", "operator", "static", "subscript", "typealias",
    "Type", "Protocol", "internal", "public", "private", "open", "fileprivate",
}


def fail(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    sys.exit(2)


def section(text, start_prefix, end_prefix):
    lines = text.split("\n")
    s = next((i for i, l in enumerate(lines) if l.startswith(start_prefix)), None)
    if s is None:
        fail(f"seção '{start_prefix}' não encontrada em {SPEC}")
    e = next((i for i in range(s + 1, len(lines)) if lines[i].startswith(end_prefix)), len(lines))
    return lines[s:e]


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


# ---------------------------------------------------------------------------------------------
# A11yID (03 §22)
# ---------------------------------------------------------------------------------------------

def expand(token):
    """Expande [.a/.b] (opcionais, inclui a base) e {a,b} (obrigatório) de um token."""
    m = re.search(r"\[([^\]]*)\]", token)
    if m:
        base = token[: m.start()]
        rest = token[m.end():]
        out = [base + rest]
        for opt in m.group(1).split("/"):
            out.extend(expand(base + opt + rest))
        return out
    m = re.search(r"\{([^}]*)\}", token)
    if m:
        base = token[: m.start()]
        rest = token[m.end():]
        out = []
        for opt in m.group(1).split(","):
            out.extend(expand(base + opt + rest))
        return out
    return [token]


def parse_a11y(text):
    rows = []
    sec = section(text, "## 22.", "## 23.")
    for line in sec:
        if not line.startswith("|") or line.startswith("|---") or line.startswith("| Superf"):
            continue
        c = cells(line)
        if len(c) < 2:
            continue
        surface, ids = c[0], c[1]
        host = None
        for tok in re.findall(r"`([^`]+)`", ids):
            if tok.startswith("."):
                if host is None:
                    fail(f"token relativo sem host: {tok} ({surface})")
                full = host + tok
            else:
                full = tok
                if host is None:
                    host = re.sub(r"[\[{].*$", "", tok)
            for e in expand(full):
                rows.append((surface, e))
    seen, out = set(), []
    for surface, pat in rows:
        if pat not in seen:
            seen.add(pat)
            out.append((surface, pat))
    return out


def camel(parts):
    out = ""
    for p in parts:
        p = re.sub(r"[^A-Za-z0-9]", "", p)
        if not p:
            continue
        out += p if not out else p[0].upper() + p[1:]
    return out


LOOSE_PLACEHOLDERS = {"host", "region", "panel", "path", "rest"}


def pattern_info(pat):
    segs = pat.split(".")
    fixed, params, regex = [], [], []
    for s in segs:
        m = re.fullmatch(r"<([A-Za-z]+)>", s)
        if s == "*":
            m, name = True, "rest"
        elif m:
            name = m.group(1)
        if m:
            base = name
            n = base
            i = 2
            while n in params:
                n = f"{base}{i}"
                i += 1
            params.append(n)
            regex.append(r".+" if name in LOOSE_PLACEHOLDERS else r"[^.]+")
        else:
            fixed.append(s)
            regex.append(re.escape(s))
    return fixed, params, "^" + r"\.".join(regex) + "$"


def swift_ident(name):
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def gen_a11y(entries):
    consts, funcs, specs = [], [], []
    # Nome Swift: segmentos fixos em camelCase. Em colisão, quem tem mais parâmetros ganha o sufixo With<Params>.
    infos = [(surface, pat) + pattern_info(pat) for surface, pat in entries]
    groups = {}
    for surface, pat, fixed, params, rx in infos:
        groups.setdefault(camel(fixed) or "root", []).append(pat)
    chosen = {}
    for surface, pat, fixed, params, rx in infos:
        base = camel(fixed) or "root"
        if len(groups[base]) > 1 and len(params) > min(len(pattern_info(q)[1]) for q in groups[base]):
            base += "With" + camel(["x"] + params)[1:]
        chosen[pat] = base
    names = {}
    for surface, pat, fixed, params, rx in infos:
        name = chosen[pat]
        if name[0].isdigit():
            name = "_" + name
        if name in names:
            fail(f"colisão de nome Swift '{name}': {names[name]} e {pat}")
        names[name] = pat
        # Segmentos de placeholders: um segmento comum não pode conter ponto.
        parts, pi = [], 0
        for s in pat.split("."):
            if s == "*" or re.fullmatch(r"<[A-Za-z]+>", s):
                pname = params[pi]
                pi += 1
                loose = re.sub(r"[<>]", "", s) in LOOSE_PLACEHOLDERS or s == "*"
                parts.append(("", pname, loose))
            else:
                parts.append((s, None, False))
        if not params:
            consts.append(f'    /// `{pat}`\n    public static let {swift_ident(name)} = A11yID(unchecked: "{pat}")')
        else:
            sig = ", ".join(f"_ {swift_ident(p)}: String" for p in params)
            body = []
            for lit, pname, loose in parts:
                if pname is None:
                    body.append(lit)
                else:
                    body.append(f"\\({'A11yID.rawSegment(' + swift_ident(pname) + ', loose: true)' if loose else 'A11yID.segment(' + swift_ident(pname) + ')'})")
            funcs.append(
                f"    /// `{pat}`\n    public static func {swift_ident(name)}({sig}) -> A11yID {{\n"
                f"        A11yID(unchecked: \"{'.'.join(body)}\")\n    }}"
            )
        specs.append(f'        A11yIDSpec(pattern: "{pat}", surface: "{surface}"),')
    header = (
        "// GERADO por scripts/gen-automation-ids.py a partir de docs/rebuild/spec/03-screens.md §22. NÃO EDITAR.\n"
        "// Cada identificador (ou padrão com <placeholder>) da lista canônica vira uma constante ou função.\n\n"
    )
    return (
        header
        + "extension A11yID {\n"
        + "\n".join(consts)
        + "\n\n"
        + "\n\n".join(funcs)
        + "\n}\n\n"
        + "extension A11yID {\n    /// Lista canônica completa (03 §22), na ordem da spec.\n"
        + "    public static let catalog: [A11yIDSpec] = [\n"
        + "\n".join(specs)
        + "\n    ]\n}\n"
    ), names


# ---------------------------------------------------------------------------------------------
# ActionID (03 §24)
# ---------------------------------------------------------------------------------------------

SLICE_BY_PREFIX = [
    ("computer.", 3), ("docker.", 3), ("image.", 3), ("batch.", 3), ("proxy.", 3), ("child.", 3),
    ("git.", 2), ("conversation.", 2), ("context.", 4), ("inbox.", 2), ("notification.", 2),
    ("account.logIn", 1), ("account.", 2), ("checks.", 2), ("conflict.", 2), ("library.", 4), ("profile.", 4),
    ("settings.testNotification", 2), ("session.markRead", 2), ("session.markUnread", 2),
    ("panel.refresh", 2), ("panel.conversations", 2), ("panel.context", 4),
    ("view.toggleRightPanel", 2), ("sidebar.clearSearch", 2), ("sidebar.search", 2),
]


def slice_for(aid, version):
    if "1.1" in version.split()[0] or version.startswith("v1.1"):
        return "v11"
    if version.startswith("later"):
        return "later"
    for pre, s in SLICE_BY_PREFIX:
        if aid.startswith(pre) or aid == pre:
            return f"slice{s}"
    m = re.findall(r"Fatia (\d)", version)
    if len(m) == 1 and "Toggle" not in version:
        return f"slice{m[0]}"
    return "slice1"


def parse_actions(text):
    sec = section(text, "## 24.", "## 25.")
    out, seen = [], set()
    for line in sec:
        if not line.startswith("|") or line.startswith("|---") or line.startswith("| Ação"):
            continue
        c = cells(line)
        if len(c) < 7:
            continue
        label, idcell, shortcut, version = c[0], c[1], c[2], c[-2]
        toks = re.findall(r"`([^`]+)`", idcell)
        if not toks or not re.match(r"^\.?[a-z]", toks[0]):
            continue
        ids, prev = [], None
        for t in toks:
            if t.startswith("."):
                if prev is None:
                    fail(f"ActionID relativo sem base: {t}")
                full = prev.rsplit(".", 1)[0] + t
            else:
                full = t
            if "<n>" in full:
                for n in range(1, 10):
                    ids.append(full.replace("<n>", str(n)))
            else:
                ids.append(full)
            prev = full if "<n>" not in full else full.replace("<n>", "1")
        labels = [x.strip() for x in label.split(" / ")]
        shorts = [x.strip() for x in shortcut.split(" / ")]
        base_ids = [i for i in ids if not re.search(r"\.select\d$", i)]
        for idx, aid in enumerate(ids):
            m = re.search(r"\.select(\d)$", aid)
            if m:
                lab = label
                sc = ("⌘" if aid.startswith("session.") else "⌃") + m.group(1)
            else:
                k = base_ids.index(aid)
                lab = labels[k] if len(labels) == len(base_ids) else label
                sc = shorts[k] if len(shorts) == len(base_ids) else shortcut
            if not re.fullmatch(r"[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*)+", aid):
                fail(f"ActionID inválido: {aid}")
            if aid in seen:
                continue
            seen.add(aid)
            out.append((aid, lab.replace('"', "'"), "" if sc == "—" else sc.replace('"', "'"), slice_for(aid, version)))
    return out


def action_case(aid):
    return swift_ident(camel(aid.split(".")))


def gen_actions(actions):
    lines, names = [], {}
    for aid, _, _, _ in actions:
        n = camel(aid.split("."))
        if n in names:
            fail(f"colisão de nome de ActionID: {n}: {names[n]} e {aid}")
        names[n] = aid
        lines.append(f'    public static let {swift_ident(n)} = ActionID(unchecked: "{aid}")')
    specs = [
        f'        ActionSpec(id: ActionID(unchecked: "{aid}"), label: "{lab}", shortcut: "{sc}", slice: .{sl}),'
        for aid, lab, sc, sl in actions
    ]
    return (
        "// GERADO por scripts/gen-automation-ids.py a partir de docs/rebuild/spec/03-screens.md §24. NÃO EDITAR.\n"
        "// ActionID = <grupo>.<ação> em lowerCamelCase (03 §24). A fatia vem da coluna Versão (regras no gerador).\n\n"
        "extension ActionID {\n" + "\n".join(lines) + "\n}\n\n"
        "extension ActionID {\n    /// Índice completo (03 §24).\n    public static let catalog: [ActionSpec] = [\n"
        + "\n".join(specs) + "\n    ]\n}\n"
    )


def gen_doc(a11y, actions):
    out = [
        "# Identificadores de automação",
        "",
        "Gerado por `scripts/gen-automation-ids.py` a partir de `docs/rebuild/spec/03-screens.md` §22 e §24. Não editar à mão.",
        "`<x>` é um placeholder (ID estável do modelo; nunca texto visível nem índice de posição).",
        "",
        "## A11yID (03 §22)",
        "",
    ]
    cur = None
    for surface, pat in a11y:
        if surface != cur:
            cur = surface
            out += ["", f"### {surface}", ""]
        out.append(f"- `{pat}`")
    out += ["", "## ActionID (03 §24)", "", "| ActionID | Rótulo | Atalho | Fatia |", "|---|---|---|---|"]
    for aid, lab, sc, sl in actions:
        out.append(f"| `{aid}` | {lab} | {sc or '—'} | {sl} |")
    out.append("")
    return "\n".join(out)


def main(argv):
    if any(a in ("-h", "--help") for a in argv[1:]):
        print(__doc__)
        return 0
    check = "--check" in argv[1:]
    if any(a not in ("--check",) for a in argv[1:]):
        print(__doc__, file=sys.stderr)
        return 2
    text = SPEC.read_text(encoding="utf-8")
    a11y = parse_a11y(text)
    actions = parse_actions(text)
    if len(a11y) < 100 or len(actions) < 100:
        fail(f"parsing suspeito: {len(a11y)} IDs, {len(actions)} ações")
    swift_a11y, _ = gen_a11y(a11y)
    outputs = {
        OUT_A11Y: swift_a11y,
        OUT_ACTION: gen_actions(actions),
        OUT_DOC: gen_doc(a11y, actions),
    }
    stale = []
    for path, content in outputs.items():
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    if check:
        if stale:
            print("gen-automation-ids: defasado: " + ", ".join(stale) + " (rode scripts/gen-automation-ids.py)", file=sys.stderr)
            return 1
        print(f"gen-automation-ids: OK ({len(a11y)} A11yID, {len(actions)} ActionID)")
        return 0
    print(f"gen-automation-ids: {len(a11y)} A11yID, {len(actions)} ActionID")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
