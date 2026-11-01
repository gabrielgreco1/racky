"""Servidor de controle do runtime: autenticação, roteamento, lock de escrita, ingestão ao egress e contrato de erros.
Sem Chromium: o navegador é um dublê. O comportamento com o Chromium real é coberto pelo teste vivo (CoreTests/LiveComputerTests)."""
import asyncio
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_runtime import API_VERSION  # noqa: E402
from racky_runtime.browser import OpError  # noqa: E402
from racky_runtime.ingest import Ingestor, post_json  # noqa: E402
from racky_runtime.server import OPS, READS, RuntimeServer  # noqa: E402
from racky_runtime.ulid import new_ulid  # noqa: E402

TOKEN = "runtime-token-0123456789abcdef"


class FakeBrowser:
    ready = True

    def __init__(self):
        self.write_lock = asyncio.Lock()
        self.calls = []
        self.concurrent_writes = 0
        self.max_concurrent_writes = 0

    async def open(self, a):
        self.concurrent_writes += 1
        self.max_concurrent_writes = max(self.max_concurrent_writes, self.concurrent_writes)
        await asyncio.sleep(0.15)
        self.concurrent_writes -= 1
        self.calls.append(("open", a))
        return {"url": a["url"], "status": 200}

    async def read(self, a):
        self.calls.append(("read", a))
        return {"content": "text"}

    async def click(self, a):
        raise OpError("timeout", "selector not found", 408)

    async def type(self, a):
        raise ValueError("boom: secret detail\nsecond line")

    async def tabs(self, a):
        return {"tabs": [a.get("action")]}

    async def cookies(self, a):
        return {"cookies": [a.get("action")]}

    async def status(self, a):
        return {"ready": True}

    async def screenshot(self, a):
        return {"png_b64": ""}

    async def eval(self, a):
        return {"result_json": "1"}


class FakeDisplay:
    mode = "headless"

    async def set_mode(self, display):
        if display not in ("headless", "desktop"):
            raise OpError("invalid_argument", "display must be headless or desktop")
        self.mode = display
        return {"display": display, "reloaded": False}


async def call(port, method, path, token=TOKEN, payload=None, raw=None):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    body = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else b"")
    auth = f"Authorization: Bearer {token}\r\n" if token else ""
    w.write(f"{method} {path} HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {len(body)}\r\n\r\n".encode() + body)
    await w.drain()
    data = await asyncio.wait_for(r.read(), 10)
    w.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    return int(head.split()[1]), head, json.loads(rest) if rest else None


class ServerTests(unittest.TestCase):
    def run_server(self, fn, token=TOKEN):
        async def body():
            browser, display = FakeBrowser(), FakeDisplay()
            server = RuntimeServer(browser, token, display)
            listener = await asyncio.start_server(server.handle, "127.0.0.1", 0)
            try:
                await fn(listener.sockets[0].getsockname()[1], browser, display)
            finally:
                listener.close()

        asyncio.run(body())

    def test_health_is_open_and_carries_the_contract_version(self):
        async def fn(port, browser, display):
            status, head, payload = await call(port, "GET", "/v1/health", token=None)
            self.assertEqual(status, 200)
            self.assertTrue(payload["ready"] and payload["api"] == API_VERSION == "2")
            self.assertIn(f"X-Racky-Runtime: {API_VERSION}".encode(), head)

        self.run_server(fn)

    def test_everything_else_needs_the_token(self):
        async def fn(port, browser, display):
            for token in (None, "wrong", TOKEN + "x", ""):
                status, _, payload = await call(port, "POST", "/v1/open", token=token, payload={"url": "http://x/"})
                self.assertEqual((status, payload["error"]), (401, "unauthorized"), token)
            self.assertEqual(browser.calls, [])
            self.assertEqual((await call(port, "POST", "/v1/open", payload={"url": "http://x/"}))[0], 200)

        self.run_server(fn)

    def test_no_token_configured_locks_everything_but_health(self):
        async def fn(port, browser, display):
            self.assertEqual((await call(port, "POST", "/v1/open", token="anything", payload={}))[0], 401)
            self.assertEqual((await call(port, "GET", "/v1/health", token=None))[0], 200)

        self.run_server(fn, token=None)

    def test_routing_and_bad_input(self):
        async def fn(port, browser, display):
            self.assertEqual((await call(port, "POST", "/v1/nope", payload={}))[0], 404)
            self.assertEqual((await call(port, "GET", "/v1/open"))[0], 404)
            self.assertEqual((await call(port, "POST", "/v2/open", payload={}))[0], 404)
            status, _, payload = await call(port, "POST", "/v1/open", raw=b"{not json")
            self.assertEqual((status, payload["error"]), (400, "invalid_argument"))
            status, _, payload = await call(port, "POST", "/v1/open", raw=b"[1,2]")
            self.assertEqual((status, payload["error"]), (400, "invalid_argument"))
            self.assertEqual(set(OPS), {"open", "read", "screenshot", "click", "type", "press", "select", "scroll", "wait", "eval", "cookies", "tabs",
                                        "back", "forward", "reload", "download", "upload", "status", "mode", "lease", "vnc_ticket", "frame", "selection"})

        self.run_server(fn)

    def test_errors_keep_their_codes_and_never_leak_internals(self):
        async def fn(port, browser, display):
            status, _, payload = await call(port, "POST", "/v1/click", payload={"selector": "#x"})
            self.assertEqual((status, payload["error"]), (408, "timeout"))
            status, _, payload = await call(port, "POST", "/v1/type", payload={"text": "x"})
            self.assertEqual(status, 400)
            self.assertEqual(payload["error"], "invalid_argument")
            self.assertNotIn("second line", payload["message"])  # só a primeira linha, sem stack
            status, _, payload = await call(port, "POST", "/v1/mode", payload={"display": "http"})
            self.assertEqual((status, payload["error"]), (400, "invalid_argument"))
            status, _, payload = await call(port, "POST", "/v1/mode", payload={"display": "desktop"})
            self.assertEqual((status, payload), (200, {"display": "desktop", "reloaded": False}))
            self.assertEqual(display.mode, "desktop")

        self.run_server(fn)

    def test_writes_are_serialized_but_reads_do_not_wait_for_them(self):
        async def fn(port, browser, display):
            started = asyncio.get_running_loop().time()
            writes = [asyncio.ensure_future(call(port, "POST", "/v1/open", payload={"url": f"http://x/{i}"})) for i in range(3)]
            await asyncio.sleep(0.03)
            # CS-193: leituras, screenshot e status não disputam o lock das escritas
            read_started = asyncio.get_running_loop().time()
            for op, payload in (("read", {"what": "text"}), ("status", {}), ("screenshot", {}), ("eval", {"js": "1"}),
                                ("tabs", {"action": "list"}), ("cookies", {"action": "get"})):
                self.assertEqual((await call(port, "POST", f"/v1/{op}", payload=payload))[0], 200, op)
            self.assertLess(asyncio.get_running_loop().time() - read_started, 0.12, "reads waited behind a write")
            await asyncio.gather(*writes)
            self.assertEqual(browser.max_concurrent_writes, 1)  # escritas uma por vez
            self.assertGreaterEqual(asyncio.get_running_loop().time() - started, 0.4)
            # `tabs` e `cookies` que ESCREVEM entram no lock; os de leitura não
            self.assertIn("read", READS)

        self.run_server(fn)


class IngestorTests(unittest.TestCase):
    def test_no_token_drops_and_counts(self):
        ing = Ingestor(None)
        ing.submit({"source": "browser"})
        self.assertEqual(ing.dropped, 1)

    def test_posts_with_the_token_and_flush_waits_for_delivery(self):
        async def body():
            seen = {}

            async def egress(r, w):
                head = await r.readuntil(b"\r\n\r\n")
                headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in head.decode().split("\r\n")[1:] if ":" in l}
                seen["auth"] = headers["authorization"]
                seen["line"] = head.decode().split("\r\n")[0]
                seen["body"] = json.loads(await r.readexactly(int(headers["content-length"])))
                await asyncio.sleep(0.1)
                w.write(b'HTTP/1.1 200 X\r\nContent-Length: 2\r\n\r\n{}')
                await w.drain()
                w.close()

            server = await asyncio.start_server(egress, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            ing = Ingestor(TOKEN, host="127.0.0.1", port=port)
            rid = new_ulid()
            ing.submit({"id": rid, "source": "browser", "url": "http://x/"}, response_body="hello")
            self.assertNotIn("auth", seen)  # ainda em voo
            await ing.flush()
            self.assertEqual(seen["auth"], f"Bearer {TOKEN}")
            self.assertEqual(seen["line"], "POST /v1/reqlog/ingest HTTP/1.1")
            self.assertEqual(seen["body"]["record"]["id"], rid)
            self.assertEqual(seen["body"]["response_body"], "hello")
            self.assertEqual(ing.dropped, 0)
            server.close()

        asyncio.run(body())

    def test_unreachable_egress_never_raises(self):
        async def body():
            ing = Ingestor(TOKEN, host="127.0.0.1", port=1)
            ing.submit({"source": "browser"})
            await ing.flush()
            self.assertEqual(ing.dropped, 1)

        asyncio.run(body())


class UlidTests(unittest.TestCase):
    def test_shape_and_order(self):
        a, b = new_ulid(1_000), new_ulid(2_000)
        self.assertEqual((len(a), len(b)), (26, 26))
        self.assertLess(a, b)
        self.assertEqual(new_ulid(0, b"\x00" * 10), "0" * 26)


if __name__ == "__main__":
    unittest.main()
