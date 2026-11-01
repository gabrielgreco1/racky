"""Admin API: autenticação por token, usage, reqlog, corpo e reload (troca de proxy)."""
import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_egress.admin import AdminServer  # noqa: E402
from racky_egress.config import Config, load_config  # noqa: E402
from racky_egress.proxy import EgressProxy  # noqa: E402

TOKEN = "t0ken-abcdefabcdefabcdef"


async def http(port, method, path, token=None):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    auth = f"Authorization: Bearer {token}\r\n" if token else ""
    w.write(f"{method} {path} HTTP/1.1\r\nHost: x\r\n{auth}\r\n".encode())
    await w.drain()
    data = await asyncio.wait_for(r.read(), 5)
    w.close()
    head, _, body = data.partition(b"\r\n\r\n")
    return int(head.split()[1]), body


class AdminTests(unittest.TestCase):
    def run_with_admin(self, fn):
        async def body():
            with tempfile.TemporaryDirectory() as tmp:
                secrets = Path(tmp) / "run"
                logs = Path(tmp) / "logs"
                secrets.mkdir()
                logs.mkdir()

                def write_cfg(**extra):
                    data = {"bind": "127.0.0.1", "logs_dir": str(logs), "via": "direct", **extra}
                    (secrets / "egress.json").write_text(json.dumps(data))

                write_cfg()
                proxy = EgressProxy(load_config(secrets), logs)
                admin = AdminServer(proxy, TOKEN, config_loader=lambda: load_config(secrets))
                self.admin = admin
                server = await asyncio.start_server(admin.handle, "127.0.0.1", 0)
                try:
                    await fn(server.sockets[0].getsockname()[1], proxy, write_cfg, logs)
                finally:
                    server.close()

        asyncio.run(body())

    def test_vnc_tunnel_forwards_the_upgrade_without_the_bearer_and_refuses_plain_requests(self):
        async def fn(port, proxy, write_cfg, logs):
            seen = {}

            async def runtime(r, w):
                head = await r.readuntil(b"\r\n\r\n")
                seen["head"] = head.decode()
                w.write(b"HTTP/1.1 101 Switching Protocols\r\n\r\n")
                await w.drain()
                data = await r.read(100)
                w.write(b"echo:" + data)
                await w.drain()
                w.close()

            rt = await asyncio.start_server(runtime, "127.0.0.1", 0)
            proxy_admin = self.admin
            proxy_admin.runtime_address = ("127.0.0.1", rt.sockets[0].getsockname()[1])
            # sem Upgrade: recusado (400), nunca chega ao runtime
            self.assertEqual((await http(port, "GET", "/vnc?ticket=x"))[0], 400)
            self.assertNotIn("head", seen)
            r, w = await asyncio.open_connection("127.0.0.1", port)
            w.write(b"GET /vnc?ticket=abc HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    b"Sec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer nope\r\n\r\n")
            await w.drain()
            self.assertIn(b"101", await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 5))
            w.write(b"ping")
            await w.drain()
            self.assertEqual(await asyncio.wait_for(r.read(100), 5), b"echo:ping")
            w.close()
            rt.close()
            self.assertTrue(seen["head"].startswith("GET /v1/vnc?ticket=abc HTTP/1.1"))
            self.assertNotIn("Authorization", seen["head"])  # o token do computador nunca vai no túnel

        self.run_with_admin(fn)

    def test_tcp_tunnel_reaches_a_local_service_only_with_the_token_and_never_a_control_port(self):
        async def fn(port, proxy, write_cfg, logs):
            async def service(r, w):
                data = await r.read(100)
                w.write(b"pg:" + data)
                await w.drain()
                w.close()

            svc = await asyncio.start_server(service, "127.0.0.1", 0)
            svc_port = svc.sockets[0].getsockname()[1]

            async def open_tunnel(path, token):
                r, w = await asyncio.open_connection("127.0.0.1", port)
                auth = f"Authorization: Bearer {token}\r\n" if token else ""
                w.write(f"GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: racky-tcp\r\nConnection: Upgrade\r\n{auth}\r\n".encode())
                await w.drain()
                return r, w, await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 5)

            r, w, head = await open_tunnel(f"/v1/tcp?port={svc_port}", TOKEN)
            self.assertIn(b" 101 ", head)
            w.write(b"startup")
            await w.drain()
            self.assertEqual(await asyncio.wait_for(r.read(100), 5), b"pg:startup")
            w.close()
            for path, token, status in ((f"/v1/tcp?port={svc_port}", None, b" 401 "), ("/v1/tcp?port=3128", TOKEN, b" 400 "),
                                        ("/v1/tcp?port=8790", TOKEN, b" 400 "), ("/v1/tcp?port=22", TOKEN, b" 400 "),
                                        ("/v1/tcp?port=1", TOKEN, b" 400 ")):
                r, w, head = await open_tunnel(path, token)
                self.assertIn(status, head, path)
                w.close()
            svc.close()

        self.run_with_admin(fn)

    def test_auth_required_except_health(self):
        async def fn(port, proxy, write_cfg, logs):
            self.assertEqual((await http(port, "GET", "/v1/health"))[0], 200)
            for path in ["/v1/usage", "/v1/reqlog", "/v1/proxy"]:
                self.assertEqual((await http(port, "GET", path))[0], 401)
                self.assertEqual((await http(port, "GET", path, "wrong-token"))[0], 401)
                self.assertEqual((await http(port, "GET", path, TOKEN))[0], 200)
            self.assertEqual((await http(port, "POST", "/v1/proxy/reload"))[0], 401)

        self.run_with_admin(fn)

    def test_no_token_configured_locks_everything_but_health(self):
        async def body():
            with tempfile.TemporaryDirectory() as tmp:
                proxy = EgressProxy(Config.parse({"bind": "127.0.0.1", "logs_dir": tmp}), Path(tmp))
                server = await asyncio.start_server(AdminServer(proxy, None).handle, "127.0.0.1", 0)
                port = server.sockets[0].getsockname()[1]
                self.assertEqual((await http(port, "GET", "/v1/usage", ""))[0], 401)
                self.assertEqual((await http(port, "GET", "/v1/usage", "anything"))[0], 401)
                server.close()

        asyncio.run(body())

    def test_reload_switches_via_and_reports_closed_tunnels(self):
        async def fn(port, proxy, write_cfg, logs):
            write_cfg(via="other", allow_cidrs=["10.0.0.0/8"])
            status, body = await http(port, "POST", "/v1/proxy/reload", TOKEN)
            self.assertEqual(status, 200, body)
            payload = json.loads(body)
            self.assertEqual((payload["applied"], payload["via"], payload["closed_tunnels"]), (True, "other", 0))
            self.assertEqual(json.loads((await http(port, "GET", "/v1/proxy", TOKEN))[1])["via"], "other")
            self.assertTrue((logs / "usage.json").exists())

        self.run_with_admin(fn)

    def test_reload_with_bad_config_returns_500_and_keeps_old(self):
        async def fn(port, proxy, write_cfg, logs):
            write_cfg(upstream={"scheme": "ftp", "host": "x", "port": 1})
            status, _ = await http(port, "POST", "/v1/proxy/reload", TOKEN)
            self.assertEqual(status, 500)
            self.assertEqual(proxy.config.via, "direct")

        self.run_with_admin(fn)

    def test_body_route_is_confined(self):
        async def fn(port, proxy, write_cfg, logs):
            self.assertEqual((await http(port, "GET", "/v1/reqlog/NOPE/body", TOKEN))[0], 404)
            self.assertEqual((await http(port, "GET", "/v1/reqlog/../../etc/passwd/body", TOKEN))[0], 404)

        self.run_with_admin(fn)


if __name__ == "__main__":
    unittest.main()
