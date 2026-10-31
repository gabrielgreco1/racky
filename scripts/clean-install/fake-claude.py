#!/usr/bin/env python3
"""fake-claude.py - um "Claude Code" de mentira para o teste de instalação limpa (scripts/clean-install.sh). Nunca fala com a Anthropic.

Responde ao que o Racky pergunta (`--version`, `--help`, `auth status --json`) e, lançado como sessão, lê o `--mcp-config` que o app
injeta, sobe `racky mcp --child <pai> --capability <token>` e reserva UM computador (boxes_reserve) pelo caminho MCP de verdade; depois
acompanha boxes_status e registra tudo em $FAKE_CLAUDE_LOG. Fica vivo até receber SIGTERM.
Env: FAKE_CLAUDE_LOG (arquivo), FAKE_APP_SOCK (socket do app de teste), FAKE_COMPUTER (nome; padrão ci1), FAKE_STATUS_SECONDS (padrão 150).
"""
import json, os, subprocess, sys, time

args = sys.argv[1:]
if args[:1] in (["--version"], ["--help"]) or args[:2] == ["auth", "status"]:
    with open(os.environ.get("FAKE_CLAUDE_LOG", "/dev/null"), "a") as f:  # prova de que o Racky achou ESTE claude
        f.write("probe %s\n" % " ".join(args))
if args[:1] == ["--version"]:
    print("9.9.9 (fake-claude)")
    sys.exit(0)
if args[:1] == ["--help"]:
    sys.exit(1)  # sem --help o Racky usa a tabela por versão
if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": True}))
    sys.exit(0)

LOG = os.environ.get("FAKE_CLAUDE_LOG", "/dev/null")
NAME = os.environ.get("FAKE_COMPUTER", "ci1")


def log(msg):
    with open(LOG, "a") as f:
        f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))


config = None
for i, a in enumerate(args):
    if a == "--mcp-config" and i + 1 < len(args):
        config = args[i + 1]
print("FAKE-CLAUDE: session up (no model, no network)", flush=True)
log("session start argv=%s" % json.dumps(args)[:400])
if config is None:
    log("no --mcp-config in argv")
    time.sleep(3600)
text = config if config.lstrip().startswith("{") else open(config).read()
server = json.loads(text)["mcpServers"]["racky"]
env = dict(os.environ)
env["RACKY_MCP_NO_LAUNCH"] = "1"  # nunca reabrir "o" app: o do dono tem o mesmo bundle id
if os.environ.get("FAKE_APP_SOCK"):
    env["RACKY_APP_SOCK"] = os.environ["FAKE_APP_SOCK"]
log('mcp command: %s exists=%s' % (json.dumps([server['command']] + server['args'])[:300], os.path.exists(server['command'])))
proc = subprocess.Popen([server["command"]] + server["args"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(LOG, 'a'), env=env, text=True, bufsize=1)
seq = [0]


def rpc(method, params=None, notify=False):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        seq[0] += 1
        msg["id"] = seq[0]
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if notify:
        return None
    line = proc.stdout.readline()
    return json.loads(line) if line else None


def call(tool, arguments):
    reply = rpc("tools/call", {"name": tool, "arguments": arguments})
    try:
        return json.loads(reply["result"]["content"][0]["text"])
    except Exception:
        return reply


init = rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "fake-claude", "version": "0"}})
time.sleep(0.5)
log("initialize -> %s (helper rc=%s)" % (json.dumps(init)[:300], proc.poll()))
rpc("notifications/initialized", notify=True)
t0 = time.time()
for attempt in range(40):  # "pending" = o usuário ainda decide; repete com os mesmos argumentos
    out = call("boxes_reserve", {"names": [NAME], "display": "headless"})
    log("boxes_reserve -> %s" % json.dumps(out)[:600])
    if not (isinstance(out, dict) and out.get("status") == "pending"):
        break
    time.sleep(2)
print("FAKE-CLAUDE: reserved %s" % NAME, flush=True)
deadline = time.time() + float(os.environ.get("FAKE_STATUS_SECONDS", "150"))
while time.time() < deadline:
    st = call("boxes_status", {})
    log("boxes_status +%.1fs -> %s" % (time.time() - t0, json.dumps(st)[:400]))
    boxes = st.get("boxes") if isinstance(st, dict) else None
    if boxes and any(b.get("name") == NAME and b.get("state") in ("ready", "in_use") for b in boxes):
        print("FAKE-CLAUDE: %s is ready after %.1fs" % (NAME, time.time() - t0), flush=True)
        log("READY after %.1fs" % (time.time() - t0))
        break
    if boxes and any(b.get("name") == NAME and b.get("state") == "failed" for b in boxes):
        log("FAILED")
        break
    time.sleep(2)
time.sleep(3600)
