import json, sys, http.server, itertools, re, time
LOG = sys.argv[2]; PORT = int(sys.argv[1]); n = itertools.count(1)

def out_text(o):
    v = o.get('output')
    if isinstance(v, list): return " ".join(x.get('text', '') for x in v if isinstance(x, dict))
    return v if isinstance(v, str) else json.dumps(v)

def first_json(text):
    m = re.search(r'\{.*\}', text, re.S)
    try: return json.loads(m.group(0)) if m else {}
    except Exception: return {}

def decide(d):
    # Os modelos reais do Codex usam "code mode": a única ferramenta direta é `exec` (JavaScript) e as demais (MCP, spawn_agent...) são
    # métodos de `tools`. O mock fala assim: um script por passo, e o resultado volta como custom_tool_call_output.
    items = d.get('input', [])
    if not d.get('tools') and not any(x.get('type') == 'additional_tools' for x in items):
        return {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
    # A tarefa do filho chega como mensagem do usuário (v1) ou como `agent_message` do pai (v2, multi-agent).
    user_texts = " ".join(
        c.get('text', '') or c.get('encrypted_content', '') for x in items
        if (x.get('type') == 'message' and x.get('role') == 'user') or x.get('type') == 'agent_message' for c in x.get('content', []))
    calls = [x for x in items if x.get('type') in ('custom_tool_call', 'function_call')]
    outs = {x['call_id']: out_text(x) for x in items if x.get('type') in ('custom_tool_call_output', 'function_call_output')}
    k = len(calls)
    def last_out(): return outs.get(calls[-1]['call_id'], '') if calls else ''
    def js(code): return {"type": "custom_tool_call", "name": "exec", "input": '// @exec: {"yield_time_ms": 150000, "max_output_tokens": 4000}\n' + code}
    def final(text): return {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text, "annotations": []}]}
    if "COMPUTER: ex" in user_texts:  # worker
        W = "mcp__racky_worker__"
        if k == 0:
            return js(f"""
const c = await tools.{W}box_claim({{name: "ex", wait_s: 45}}); text(c.content[0].text);
const o = await tools.{W}browser_open({{url: "https://example.com"}}); text(o.content[0].text);
const r = await tools.{W}browser_read({{what: "text"}}); text(r.content[0].text);
const q = await tools.{W}reqlog_query({{}}); text(q.content[0].text);
""")
        if k == 1:
            rid = None
            for m in re.finditer(r'"id"\s*:\s*"([^"]+)"', last_out()): rid = m.group(1); break
            ev = json.dumps({"/title": [rid]} if rid else {})
            return js(f"""
const s = await tools.{W}result_submit({{result: {{title: "Example Domain"}}, evidence: {ev}}}); text(s.content[0].text);
const b = await tools.{W}box_release({{}}); text(b.content[0].text);
""")
        return final("WORKER-DONE title=Example Domain")
    # pai
    if k == 0:
        return js("""
const r = await tools.mcp__racky__boxes_reserve({names: ["ex"], display: "headless", batch: "mock"}); text(r.content[0].text);
text(JSON.stringify(ALL_TOOLS.map(t => t.name).filter(n => /agent|wait/.test(n))));
""")
    if k == 1:
        box = (first_json(last_out()).get('boxes') or [{}])[0]
        brief = "COMPUTER: ex\nTASK: open https://example.com and submit the page title with result_submit.\nWHAT WE ALREADY KNOW: nothing yet\nOUTPUT: {\"title\": \"string\"}"
        args = {"agent_type": box.get('worker', 'racky-worker-1'), "message": brief, "task_name": "ex_worker", "fork_turns": "none"}
        return {"type": "function_call", "namespace": "collaboration", "name": "spawn_agent", "arguments": json.dumps(args)}
    if k in (2, 3):
        return {"type": "function_call", "namespace": "collaboration", "name": "wait_agent", "arguments": json.dumps({"timeout_ms": 30000})}
    if k == 4:
        return js("const b = await tools.mcp__racky__boxes_status({}); text(b.content[0].text);")
    return final("ROOT-DONE the subagent submitted the title: Example Domain")

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0)))
        i = next(n)
        try: d = json.loads(body)
        except Exception:
            self.send_response(400); self.end_headers(); return
        if i <= 8: open(f'{LOG}.{i}.req.json', 'wb').write(body)  # evidência: o pedido bruto dos primeiros turnos
        item = decide(d)
        item.setdefault("id", f"it_{i}"); item.setdefault("status", "completed")
        if item["type"] in ("function_call", "custom_tool_call"): item["call_id"] = f"call_{i}"
        else: item["id"] = f"msg_{i}"
        with open(LOG, "a") as f: f.write(json.dumps({"i": i, "t": time.time(), "item": item})[:600] + "\n")
        self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
        def ev(t, dd): self.wfile.write(f"event: {t}\ndata: {json.dumps(dd)}\n\n".encode())
        rid = f"resp_{i}"
        ev("response.created", {"type": "response.created", "response": {"id": rid, "status": "in_progress"}})
        ev("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item})
        ev("response.completed", {"type": "response.completed", "response": {"id": rid, "status": "completed", "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}})
        self.wfile.flush()
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
