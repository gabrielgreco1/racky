#!/usr/bin/env python3
# CLI de mentira de um worker (nenhum codex/opencode/claude real, nenhum uso gasto). Lê o que um CLI real leria:
#   - a config injetada: `-c mcp_servers.racky_worker={command=...,args=[...]}` (Codex), `OPENCODE_CONFIG_CONTENT` (OpenCode) ou
#     `--mcp-config <arquivo>` (Claude), de onde sai o comando do helper `racky mcp --child .. --capability ..`;
#   - o prompt (último argumento ou `--prompt`), de onde sai o nome do computador (`box_claim {"name":"<computador>"}`).
# Depois fala MCP (JSON-RPC por linha) com o helper REAL, uma execução por chamada (como o helper atende), e segue o roteiro de FAKE_CLI_MODE:
#   done  : box_claim, journal, result_submit, box_release, imprime DONE
#   hang  : box_claim e dorme ignorando SIGINT e SIGTERM (só SIGKILL derruba)
#   crash : box_claim e sai com código 3 sem resultado
#   quit  : box_claim, result_submit e sai SEM box_release
import json, os, re, shlex, signal, subprocess, sys, time

argv = sys.argv[1:]
mode = os.environ.get("FAKE_CLI_MODE", "done")
dump = os.environ.get("FAKE_CLI_DUMP")

def prompt_of(args):
    if "--prompt" in args:
        return args[args.index("--prompt") + 1]
    return args[-1]

def helper_command(args, env):
    for a in args:
        m = re.match(r'mcp_servers\.racky_worker=\{command="([^"]+)",args=\[(.*?)\]', a)
        if m:
            return [m.group(1)] + re.findall(r'"([^"]*)"', m.group(2))
    cfg = env.get("OPENCODE_CONFIG_CONTENT")
    if cfg:
        mcp = json.loads(cfg)["mcp"]
        return list(mcp.values())[0]["command"]
    if "--mcp-config" in args:
        data = json.load(open(args[args.index("--mcp-config") + 1]))
        server = list(data["mcpServers"].values())[0]
        return [server["command"]] + server["args"]
    raise SystemExit("no worker MCP server in the launch config")

command = helper_command(argv, os.environ)
prompt = prompt_of(argv)
computer = re.search(r'box_claim \{"name":"([^"]+)"\}', prompt).group(1)
if dump:
    json.dump({"argv": argv, "command": command, "computer": computer, "prompt_len": len(prompt),
               "has_opencode_config": "OPENCODE_CONFIG_CONTENT" in os.environ}, open(dump, "w"))

def call(tool, arguments, rid=2):
    lines = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": tool, "arguments": arguments}},
    ]
    env = dict(os.environ, RACKY_MCP_NO_LAUNCH="1")
    p = subprocess.run(command, input="\n".join(json.dumps(l) for l in lines) + "\n", capture_output=True, text=True, env=env, timeout=60)
    for line in p.stdout.splitlines():
        reply = json.loads(line)
        if reply.get("id") == rid:
            result = reply["result"]
            return result["isError"], json.loads(result["content"][0]["text"])
    raise SystemExit("no reply to " + tool)

def must(tool, arguments):
    error, body = call(tool, arguments)
    if error:
        print("TOOL ERROR", tool, body, flush=True)
        raise SystemExit(4)
    return body

claimed = must("box_claim", {"name": computer, "wait_s": 20})
assert claimed["work_path_host"], claimed
if mode == "hang":
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    print("HANGING", flush=True)
    while True:
        time.sleep(0.2)
if mode == "crash":
    sys.exit(3)
must("journal", {"kind": "PLAN", "text": "open the page and submit the title"})
must("result_submit", {"result": {"title": "Example Domain", "computer": computer}, "evidence": {}})
if mode != "quit":
    must("box_release", {})
print("DONE", flush=True)
