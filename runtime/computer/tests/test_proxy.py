"""Proxy do egress em processo: origem local, upstream HTTP com Basic e upstream SOCKS5 com usuário e senha."""
import asyncio
import base64
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_egress import reqlog as rl  # noqa: E402
from racky_egress.config import Config  # noqa: E402
from racky_egress.proxy import EgressProxy  # noqa: E402

LOCAL = ["127.0.0.0/8"]


async def origin_handler(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except asyncio.IncompleteReadError:  # túnel aberto e fechado sem enviar nada
        writer.close()
        return
    line = head.split(b"\r\n", 1)[0].decode()
    body = json.dumps({"line": line, "secret": "sk-ant-api03-LEAKYTOKEN123456"}).encode()
    writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
    await writer.drain()
    writer.close()


async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        w.close()


class HTTPUpstream:
    """Proxy HTTP mínimo com Basic obrigatório. Registra o que recebeu."""

    def __init__(self, user, password):
        self.expected = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.seen = []

    async def handle(self, reader, writer):
        head = await reader.readuntil(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        self.seen.append((lines[0], headers.get("proxy-authorization")))
        if headers.get("proxy-authorization") != self.expected:
            writer.write(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        method, target, _ = lines[0].split(" ")
        if method == "CONNECT":
            host, port = target.rsplit(":", 1)
            ur, uw = await asyncio.open_connection(host, int(port))
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(pipe(reader, uw), pipe(ur, writer))
        else:
            from urllib.parse import urlsplit
            u = urlsplit(target)
            ur, uw = await asyncio.open_connection(u.hostname, u.port or 80)
            rest = (u.path or "/") + ("?" + u.query if u.query else "")
            uw.write(head.replace(target.encode(), rest.encode(), 1))
            await uw.drain()
            await asyncio.gather(pipe(reader, uw), pipe(ur, writer))


class Socks5Upstream:
    def __init__(self, user, password):
        self.user, self.password = user.encode(), password.encode()
        self.seen = []

    async def handle(self, reader, writer):
        ver, n = await reader.readexactly(2)
        methods = await reader.readexactly(n)
        if 2 not in methods:
            writer.write(b"\x05\xff")
            writer.close()
            return
        writer.write(b"\x05\x02")
        _v, ul = await reader.readexactly(2)
        user = await reader.readexactly(ul)
        pl = (await reader.readexactly(1))[0]
        pw = await reader.readexactly(pl)
        if user != self.user or pw != self.password:
            writer.write(b"\x01\x01")
            writer.close()
            return
        writer.write(b"\x01\x00")
        _v, cmd, _r, atyp = await reader.readexactly(4)
        if atyp == 3:
            ln = (await reader.readexactly(1))[0]
            host = (await reader.readexactly(ln)).decode()
        elif atyp == 1:
            host = ".".join(str(b) for b in await reader.readexactly(4))
        else:
            host = "?"
        port = int.from_bytes(await reader.readexactly(2), "big")
        self.seen.append((host, port, user.decode()))
        ur, uw = await asyncio.open_connection(host, port)
        writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        await asyncio.gather(pipe(reader, uw), pipe(ur, writer))


async def raw_request(proxy_port, payload: bytes, read_all=True) -> bytes:
    r, w = await asyncio.open_connection("127.0.0.1", proxy_port)
    w.write(payload)
    await w.drain()
    data = b""
    try:
        while chunk := await asyncio.wait_for(r.read(65536), 5):
            data += chunk
            if not read_all:
                break
    except asyncio.TimeoutError:
        pass
    w.close()
    return data


class Harness:
    def __init__(self, upstream_cfg=None, allow=LOCAL, noise=None):
        self.upstream_cfg, self.allow, self.noise = upstream_cfg, allow, noise

    async def __aenter__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.origin = await asyncio.start_server(origin_handler, "127.0.0.1", 0)
        self.origin_port = self.origin.sockets[0].getsockname()[1]
        data = {"allow_cidrs": self.allow, "bind": "127.0.0.1", "logs_dir": self.tmp.name}
        if self.noise is not None:
            data["noise"] = self.noise
        if self.upstream_cfg:
            data["upstream"] = self.upstream_cfg
            data["via"] = "test-proxy"
        self.proxy = EgressProxy(Config.parse(data), Path(self.tmp.name))
        self.server = await asyncio.start_server(self.proxy.handle, "127.0.0.1", 0, limit=1 << 17)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc):
        self.proxy.close_all("test-end")
        await asyncio.sleep(0.2)  # deixa os handlers gravarem o registro final antes de apagar o diretório
        self.server.close()
        self.origin.close()
        self.tmp.cleanup()

    def records(self):
        return self.proxy.reqlog.read(None, 1000)


def run(coro):
    return asyncio.run(coro)


class DirectMode(unittest.TestCase):
    def test_plain_http_logged_with_redacted_body_and_headers(self):
        async def body():
            async with Harness() as h:
                req = (f"GET http://127.0.0.1:{h.origin_port}/a?x=1&api_key=SECRETVALUE HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                       "Authorization: Bearer abc123456789\r\nCookie: s=1\r\nUser-Agent: t\r\n\r\n").encode()
                data = await raw_request(h.port, req)
                self.assertIn(b"200 OK", data)
                self.assertIn(b"LEAKYTOKEN", data)  # o agente recebe a resposta intacta; só o LOG é redigido
                await asyncio.sleep(0.1)
                recs = h.records()
                self.assertEqual(len(recs), 1)
                rec = recs[0]
                self.assertEqual((rec["status"], rec["via"], rec["kind"], rec["source"], rec["trust"]),
                                 (200, "direct", "http", "egress", "observed"))
                self.assertNotIn("SECRETVALUE", rec["url"])
                hdrs = dict(map(tuple, rec["request_headers"]))
                self.assertEqual(hdrs["Authorization"], rl.REDACTED)
                self.assertEqual(hdrs["Cookie"], rl.REDACTED)
                text = (Path(h.tmp.name) / rec["response_body_file"]).read_text()
                self.assertNotIn("LEAKYTOKEN", text)
                self.assertEqual(rl.verify_chain(h.proxy.reqlog.file), (True, None))
                self.assertEqual(h.proxy.usage_snapshot()["total"]["requests"], 1)
        run(body())

    def test_connect_tunnel_counts_bytes_and_logs_one_record(self):
        async def body():
            async with Harness() as h:
                r, w = await asyncio.open_connection("127.0.0.1", h.port)
                w.write(f"CONNECT 127.0.0.1:{h.origin_port} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
                await w.drain()
                self.assertIn(b"200", await r.readuntil(b"\r\n\r\n"))
                w.write(b"GET /tunneled HTTP/1.1\r\nHost: o\r\n\r\n")
                await w.drain()
                data = await r.read(65536)
                self.assertIn(b"/tunneled", data)
                w.close()
                await asyncio.sleep(0.3)
                recs = h.records()
                self.assertEqual(len(recs), 1)
                self.assertEqual((recs[0]["kind"], recs[0]["method"], recs[0]["host"], recs[0]["via"]), ("tunnel", "CONNECT", "127.0.0.1", "direct"))
                self.assertGreater(recs[0]["bytes_up"], 0)
                self.assertGreater(recs[0]["bytes_down"], 0)
                usage = h.proxy.usage_snapshot()["total"]
                self.assertEqual((usage["tunnels"], usage["requests"]), (1, 1))
        run(body())

    def test_private_destinations_blocked_and_logged(self):
        async def body():
            async with Harness(allow=[]) as h:  # sem exceção: tudo que é local está bloqueado
                for target in ["169.254.169.254:80", "127.0.0.1:22", "10.0.0.1:443", "host.docker.internal:80", "2130706433:80",
                               "192.168.1.1:80", "100.64.0.1:80", "[::1]:80"]:
                    data = await raw_request(h.port, f"CONNECT {target} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
                    self.assertTrue(data.startswith(b"HTTP/1.1 403"), f"{target}: {data[:60]!r}")
                    self.assertIn(b"X-Racky-Blocked", data)
                data = await raw_request(h.port, b"GET http://169.254.169.254/latest/meta-data/ HTTP/1.1\r\nHost: a\r\n\r\n")
                self.assertTrue(data.startswith(b"HTTP/1.1 403"))
                data = await raw_request(h.port, b"GET http://93.184.216.34@127.0.0.1:1/ HTTP/1.1\r\nHost: a\r\n\r\n")
                self.assertTrue(data.startswith(b"HTTP/1.1 403"))
                recs = h.records()
                self.assertEqual(len(recs), 10)
                self.assertTrue(all(r["blocked"] and r["blocked_reason"] for r in recs))
                self.assertEqual(h.proxy.usage_snapshot()["total"]["blocked"], 10)
                self.assertEqual(rl.verify_chain(h.proxy.reqlog.file), (True, None))
        run(body())

    def test_noise_hosts_get_403_and_non_proxy_requests_400(self):
        async def body():
            async with Harness() as h:
                data = await raw_request(h.port, b"CONNECT update.googleapis.com:443 HTTP/1.1\r\nHost: x\r\n\r\n")
                self.assertTrue(data.startswith(b"HTTP/1.1 403"))
                data = await raw_request(h.port, b"GET /health HTTP/1.1\r\nHost: egress\r\n\r\n")
                self.assertTrue(data.startswith(b"HTTP/1.1 400"))
        run(body())


class Chained(unittest.TestCase):
    def test_http_upstream_with_credentials_connect_and_plain(self):
        async def body():
            up = HTTPUpstream("apikey-user", "p4ssw0rd-secret")
            srv = await asyncio.start_server(up.handle, "127.0.0.1", 0)
            uport = srv.sockets[0].getsockname()[1]
            cfg = {"scheme": "http", "host": "127.0.0.1", "port": uport, "username": "apikey-user", "password": "p4ssw0rd-secret"}
            async with Harness(cfg) as h:
                data = await raw_request(h.port, f"GET http://127.0.0.1:{h.origin_port}/plain HTTP/1.1\r\nHost: o\r\n\r\n".encode())
                self.assertIn(b"/plain", data)
                r, w = await asyncio.open_connection("127.0.0.1", h.port)
                w.write(f"CONNECT 127.0.0.1:{h.origin_port} HTTP/1.1\r\n\r\n".encode())
                await w.drain()
                await r.readuntil(b"\r\n\r\n")
                w.write(b"GET /tun HTTP/1.1\r\nHost: o\r\n\r\n")
                await w.drain()
                self.assertIn(b"/tun", await r.read(65536))
                w.close()
                await asyncio.sleep(0.3)
                self.assertEqual(len(up.seen), 2)
                self.assertTrue(all(auth == up.expected for _l, auth in up.seen))
                recs = h.records()
                self.assertTrue(all(r["via"] == "test-proxy" for r in recs))
                blob = (Path(h.tmp.name) / "requests.jsonl").read_text()
                self.assertNotIn("p4ssw0rd-secret", blob)
                self.assertNotIn(up.expected.split()[1], blob)
                self.assertEqual(h.proxy.usage_snapshot()["by_via"]["test-proxy"]["requests"], 2)
            srv.close()
        run(body())

    def test_upstream_407_becomes_proxy_error(self):
        async def body():
            up = HTTPUpstream("right", "right")
            srv = await asyncio.start_server(up.handle, "127.0.0.1", 0)
            cfg = {"scheme": "http", "host": "127.0.0.1", "port": srv.sockets[0].getsockname()[1], "username": "wrong", "password": "wrong-pass"}
            async with Harness(cfg) as h:
                data = await raw_request(h.port, f"CONNECT 127.0.0.1:{h.origin_port} HTTP/1.1\r\n\r\n".encode())
                self.assertTrue(data.startswith(b"HTTP/1.1 502"))
                self.assertIn(b"407", data)
                data = await raw_request(h.port, f"GET http://127.0.0.1:{h.origin_port}/ HTTP/1.1\r\nHost: o\r\n\r\n".encode())
                self.assertIn(b" 407 ", data.split(b"\r\n")[0])
                await asyncio.sleep(0.2)
                errs = [r for r in h.records() if r.get("error") == "proxy_error"]
                self.assertEqual(len(errs), 2)
                self.assertTrue(all(r["upstream_status"] == 407 for r in errs))
                self.assertNotIn("wrong-pass", (Path(h.tmp.name) / "requests.jsonl").read_text())
            srv.close()
        run(body())

    def test_socks5_upstream_with_credentials(self):
        async def body():
            up = Socks5Upstream("sockuser", "sockpass-secret")
            srv = await asyncio.start_server(up.handle, "127.0.0.1", 0)
            cfg = {"scheme": "socks5", "host": "127.0.0.1", "port": srv.sockets[0].getsockname()[1], "username": "sockuser",
                   "password": "sockpass-secret"}
            async with Harness(cfg) as h:
                data = await raw_request(h.port, f"GET http://127.0.0.1:{h.origin_port}/viasocks HTTP/1.1\r\nHost: o\r\n\r\n".encode())
                self.assertIn(b"/viasocks", data)
                r, w = await asyncio.open_connection("127.0.0.1", h.port)
                w.write(f"CONNECT 127.0.0.1:{h.origin_port} HTTP/1.1\r\n\r\n".encode())
                await w.drain()
                self.assertIn(b"200", await r.readuntil(b"\r\n\r\n"))
                w.close()
                await asyncio.sleep(0.2)
                self.assertEqual(len(up.seen), 2)
                self.assertTrue(all(user == "sockuser" for _h, _p, user in up.seen))
            srv.close()
        run(body())

    def test_geo_suffix_applied_to_username(self):
        async def body():
            up = HTTPUpstream("u-country-us", "pw-secret")
            srv = await asyncio.start_server(up.handle, "127.0.0.1", 0)
            cfg = {"scheme": "http", "host": "127.0.0.1", "port": srv.sockets[0].getsockname()[1], "username": "u", "password": "pw-secret",
                   "geo": {"country": "us", "mode": "suffix", "template": "-country-{cc}"}}
            async with Harness(cfg) as h:
                await raw_request(h.port, f"CONNECT 127.0.0.1:{h.origin_port} HTTP/1.1\r\n\r\n".encode())
                self.assertEqual(up.seen[0][1], up.expected)
            srv.close()
        run(body())

    def test_reload_closes_open_tunnels_and_reports_count(self):
        async def body():
            async with Harness() as h:
                r, w = await asyncio.open_connection("127.0.0.1", h.port)
                w.write(f"CONNECT 127.0.0.1:{h.origin_port} HTTP/1.1\r\n\r\n".encode())
                await w.drain()
                await r.readuntil(b"\r\n\r\n")
                await asyncio.sleep(0.1)
                closed = h.proxy.apply_config(Config.parse({"allow_cidrs": LOCAL, "bind": "127.0.0.1", "logs_dir": h.tmp.name, "via": "other"}))
                self.assertEqual(closed, 1)
                await asyncio.sleep(0.3)
                self.assertEqual(await r.read(10), b"")
                rec = [x for x in h.records() if x["kind"] == "tunnel"][0]
                self.assertEqual(rec["closed_by"], "proxy_switch")
        run(body())


if __name__ == "__main__":
    unittest.main()
