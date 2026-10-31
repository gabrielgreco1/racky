"""T3-03: ingest de registros (browser e http_request), render pelo modo API e reverse proxy do runtime."""
import asyncio
import base64
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_egress import reqlog as rl  # noqa: E402
from racky_egress.admin import AdminServer  # noqa: E402
from racky_egress.config import Config  # noqa: E402
from racky_egress.proxy import EgressProxy  # noqa: E402

TOKEN = "t0ken-abcdefabcdefabcdef"
API_KEY = "zyte-api-key-SECRET-123456"


async def http(port, method, path, token=TOKEN, payload=None):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    body = json.dumps(payload).encode() if payload is not None else b""
    auth = f"Authorization: Bearer {token}\r\n" if token else ""
    w.write(f"{method} {path} HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {len(body)}\r\n\r\n".encode() + body)
    await w.drain()
    data = await asyncio.wait_for(r.read(), 10)
    w.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    return int(head.split()[1]), rest


class Harness(unittest.TestCase):
    def run_admin(self, fn, **cfg):
        async def body():
            with tempfile.TemporaryDirectory() as tmp:
                proxy = EgressProxy(Config.parse({"bind": "127.0.0.1", "logs_dir": tmp, "via": "zyte-us", **cfg}), Path(tmp))
                # corpo de teste: porta do "runtime" falso preenchida pelo teste
                admin = AdminServer(proxy, TOKEN)
                server = await asyncio.start_server(admin.handle, "127.0.0.1", 0)
                try:
                    await fn(server.sockets[0].getsockname()[1], proxy, admin, Path(tmp))
                finally:
                    server.close()

        asyncio.run(body())


class IngestTests(Harness):
    def test_requires_token(self):
        async def fn(port, proxy, admin, tmp):
            status, _ = await http(port, "POST", "/v1/reqlog/ingest", token=None, payload={"record": {"source": "browser"}})
            self.assertEqual(status, 401)
            status, _ = await http(port, "POST", "/v1/reqlog/ingest", token="wrong", payload={"record": {"source": "browser"}})
            self.assertEqual(status, 401)

        self.run_admin(fn)

    def test_ingest_redacts_chains_and_forces_observed(self):
        async def fn(port, proxy, admin, tmp):
            rid = rl.new_ulid()
            status, body = await http(port, "POST", "/v1/reqlog/ingest", payload={
                "record": {"id": rid, "source": "work:python", "method": "POST", "url": "http://x.test/a?api_key=SUPERSECRET&q=1",
                           "status": 200, "trust": "reported", "via": "forged", "request_headers": [["Authorization", "Bearer abc123456"], ["Accept", "*/*"]],
                           "unknown_field": "dropped"},
                "request_body": "user=a&password=hunter2hunter2 sk-ant-api03-LEAKYLEAKYLEAKY", "response_body": '{"ok":true}'})
            self.assertEqual(status, 200, body)
            self.assertEqual(json.loads(body)["id"], rid)
            rec = proxy.reqlog.read()[-1]
            self.assertEqual((rec["trust"], rec["via"], rec["source"]), ("observed", "zyte-us", "work:python"))
            self.assertNotIn("SUPERSECRET", rec["url"])
            self.assertIn("q=1", rec["url"])
            self.assertEqual(rec["request_headers"][0][1], rl.REDACTED)
            self.assertNotIn("unknown_field", rec)
            req_body = (tmp / rec["request_body_file"]).read_text()
            self.assertNotIn("LEAKYLEAKYLEAKY", req_body)
            self.assertEqual((tmp / rec["response_body_file"]).read_text(), '{"ok":true}')
            ok, line = rl.verify_chain(tmp / "requests.jsonl")
            self.assertTrue(ok, line)

        self.run_admin(fn)

    def test_rejects_bad_source_and_bad_id(self):
        async def fn(port, proxy, admin, tmp):
            for record in ({"source": "egress"}, {"source": "browser", "id": "not-a-ulid"}, {"source": "../x"}):
                status, _ = await http(port, "POST", "/v1/reqlog/ingest", payload={"record": record})
                self.assertEqual(status, 400, record)
            status, _ = await http(port, "POST", "/v1/reqlog/ingest", payload=["x"])
            self.assertEqual(status, 400)
            self.assertEqual(proxy.reqlog.count, 0)

        self.run_admin(fn)

    def test_since_follows_file_order_for_late_ids(self):
        async def fn(port, proxy, admin, tmp):
            late, early = rl.new_ulid(2_000_000_000_000), rl.new_ulid(1_000_000_000_000)
            for rid in (late, early):  # o browser grava ao FIM da requisição, com o ULID do COMEÇO
                await http(port, "POST", "/v1/reqlog/ingest", payload={"record": {"id": rid, "source": "browser", "url": "http://a.test/"}})
            status, body = await http(port, "GET", f"/v1/reqlog?since={late}")
            self.assertEqual([r["id"] for r in json.loads(body)["records"]], [early])

        self.run_admin(fn)


class RenderTests(Harness):
    def with_provider(self, fn, reply, **cfg):
        """Provedor de render falso: guarda o último pedido (corpo e Authorization) e devolve `reply`."""
        async def inner(port, proxy, admin, tmp):
            seen = {}

            async def provider(r, w):
                head = await r.readuntil(b"\r\n\r\n")
                headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in head.decode().split("\r\n")[1:] if ":" in l}
                seen["auth"] = headers.get("authorization")
                seen["body"] = json.loads(await r.readexactly(int(headers["content-length"])))
                data = json.dumps(reply[0]).encode()
                w.write(f"HTTP/1.1 {reply[1]} X\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
                await w.drain()
                w.close()

            server = await asyncio.start_server(provider, "127.0.0.1", 0)
            try:
                endpoint = f"http://127.0.0.1:{server.sockets[0].getsockname()[1]}/v1/extract"
                proxy.apply_config(Config.parse({"bind": "127.0.0.1", "logs_dir": str(tmp), "via": "zyte-us",                                                  "render": {"adapter": "zyte", "endpoint": endpoint, "api_key": API_KEY}, **cfg}))
                proxy.policy.resolver = lambda host, port: {"example.com": ["93.184.216.34"]}.get(host, [host])  # offline
                await fn(port, proxy, admin, tmp, seen)
            finally:
                server.close()

        self.run_admin(inner)

    def test_not_supported_without_render_capability(self):
        async def fn(port, proxy, admin, tmp):
            status, body = await http(port, "POST", "/v1/render", payload={"url": "https://example.com/"})
            self.assertEqual(status, 501)
            self.assertEqual(json.loads(body)["error"], "not_supported")
            status, body = await http(port, "GET", "/v1/proxy")
            self.assertFalse(json.loads(body)["render_supported"])

        self.run_admin(fn)

    def test_render_records_html_captures_usage_and_never_leaks_key(self):
        html = "<html><body><h1>Listing 42</h1></body></html>"
        api = base64.b64encode(b'{"listings":[1,2,3]}').decode()
        reply = ({"browserHtml": html, "networkCapture": [{"url": "https://example.com/api/listings", "method": "GET", "statusCode": 200,
                                                           "httpResponseBody": api}]}, 200)

        async def fn(port, proxy, admin, tmp, seen):
            status, body = await http(port, "POST", "/v1/render", payload={"url": "https://example.com/", "capture": ["/api/"], "output": "text"})
            out = json.loads(body)
            self.assertEqual(status, 200, body)
            self.assertEqual(out["content"], "Listing 42")
            self.assertEqual(len(out["captures"]), 1)
            self.assertEqual(out["usage"]["renders"], 1)
            self.assertEqual(seen["body"]["networkCapture"][0]["value"], "/api/")
            self.assertEqual(seen["auth"], "Basic " + base64.b64encode(f"{API_KEY}:".encode()).decode())
            records = {r["id"]: r for r in proxy.reqlog.read()}
            self.assertEqual(records[out["request_id"]]["source"], "render-api")
            cap = records[out["captures"][0]["id"]]
            self.assertEqual((cap["source"], cap["parent"]), ("render-api:capture", out["request_id"]))
            self.assertEqual((tmp / cap["response_body_file"]).read_text(), '{"listings":[1,2,3]}')
            self.assertEqual(proxy.usage_snapshot()["total"]["renders"], 1)
            self.assertNotIn(API_KEY, (tmp / "requests.jsonl").read_text())
            self.assertNotIn(API_KEY, body.decode())

        self.with_provider(fn, reply)

    def test_render_marks_antibot_wall_as_blocked(self):
        async def fn(port, proxy, admin, tmp, seen):
            status, body = await http(port, "POST", "/v1/render", payload={"url": "https://example.com/"})
            out = json.loads(body)
            self.assertIn("anti-bot", out["blocked"])
            rec = next(r for r in proxy.reqlog.read() if r["id"] == out["request_id"])
            self.assertTrue(rec["blocked"])

        self.with_provider(fn, ({"browserHtml": "<title>Just a moment...</title>"}, 200))

    def test_render_provider_error_is_proxy_error(self):
        async def fn(port, proxy, admin, tmp, seen):
            status, body = await http(port, "POST", "/v1/render", payload={"url": "https://example.com/"})
            out = json.loads(body)
            self.assertEqual((out["error"], out["details"]["upstream_status"]), ("proxy_error", 401))
            self.assertEqual(proxy.usage_snapshot()["total"]["renders"], 0)

        self.with_provider(fn, ({"detail": "Authentication failed"}, 401))

    def test_render_target_goes_through_ssrf_filter(self):
        async def fn(port, proxy, admin, tmp, seen):
            for url in ("http://169.254.169.254/latest", "http://127.0.0.1:8080/", "http://192.168.0.1/"):
                status, body = await http(port, "POST", "/v1/render", payload={"url": url})
                self.assertEqual(status, 403, url)
                self.assertEqual(json.loads(body)["error"], "blocked_by_policy")
            self.assertNotIn("body", seen)  # o provedor nem foi chamado

        self.with_provider(fn, ({"browserHtml": "x"}, 200))


class RuntimeForwardTests(Harness):
    def test_forward_adds_nothing_and_requires_token(self):
        async def fn(port, proxy, admin, tmp):
            seen = {}

            async def fake_runtime(r, w):
                head = await r.readuntil(b"\r\n\r\n")
                headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in head.decode().split("\r\n")[1:] if ":" in l}
                seen["line"] = head.decode().split("\r\n")[0]
                seen["auth"] = headers.get("authorization")
                seen["body"] = await r.readexactly(int(headers["content-length"]))
                data = json.dumps({"url": "http://x/", "echo": json.loads(seen["body"])}).encode()
                w.write(f"HTTP/1.1 200 X\r\nContent-Length: {len(data)}\r\n\r\n".encode() + data)
                await w.drain()
                w.close()

            runtime = await asyncio.start_server(fake_runtime, "127.0.0.1", 0)
            admin.runtime_address = ("127.0.0.1", runtime.sockets[0].getsockname()[1])
            try:
                status, _ = await http(port, "POST", "/runtime/v1/open", token=None, payload={"url": "x"})
                self.assertEqual(status, 401)
                self.assertNotIn("line", seen)
                status, body = await http(port, "POST", "/runtime/v1/open", payload={"url": "http://x/"})
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)["echo"], {"url": "http://x/"})
                self.assertEqual(seen["line"], "POST /v1/open HTTP/1.1")
                self.assertEqual(seen["auth"], f"Bearer {TOKEN}")
            finally:
                runtime.close()

        self.run_admin(fn)

    def test_runtime_down_is_box_restarted(self):
        async def fn(port, proxy, admin, tmp):
            admin.runtime_address = ("127.0.0.1", 1)
            status, body = await http(port, "POST", "/runtime/v1/open", payload={})
            self.assertEqual((status, json.loads(body)["error"]), (503, "box_restarted"))

        self.run_admin(fn)


if __name__ == "__main__":
    unittest.main()
