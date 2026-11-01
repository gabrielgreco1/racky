"""Gateway do GitHub no egress: o agente faz git e PR por http://github.racky e http://api.github.racky, o egress põe o token e aplica
a política (repositórios permitidos, push só em feat/*, na API só leitura e abrir PR). O token nunca chega ao agente nem ao log."""
from __future__ import annotations
import asyncio
import base64
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_egress import github_gateway as gh  # noqa: E402
from racky_egress.config import Config  # noqa: E402
from racky_egress.proxy import EgressProxy  # noqa: E402

TOKEN = "ghp_TESTTOKEN0123456789abcdefABCDEF"
ACCESS = gh.GitHubAccess(token=TOKEN, repos=["acme/acme-platform"])


def pkt(line: str) -> bytes:
    data = line.encode()
    return f"{len(data) + 4:04x}".encode() + data


def push_body(*refs: tuple[str, str, str]) -> bytes:
    lines = [pkt(f"{old} {new} {ref}\0report-status") if i == 0 else pkt(f"{old} {new} {ref}") for i, (old, new, ref) in enumerate(refs)]
    return b"".join(lines) + b"0000PACK...."


class Policy(unittest.TestCase):
    def test_git_paths_and_repos(self):
        gh.check(ACCESS, "github.racky", "GET", "/acme/acme-platform.git/info/refs", "service=git-upload-pack", b"")
        gh.check(ACCESS, "github.racky", "POST", "/Acme/Acme-Platform/git-upload-pack", "", b"0000")
        with self.assertRaises(gh.Denied):
            gh.check(ACCESS, "github.racky", "GET", "/someone/else.git/info/refs", "", b"")
        with self.assertRaises(gh.Denied):
            gh.check(ACCESS, "github.racky", "GET", "/acme/acme-platform/settings", "", b"")

    def test_dot_segments_and_encoded_separators_are_refused_before_the_allowlist(self):
        for host, path in [
            ("api.github.racky", "/repos/acme/acme-platform/../../other/repo"),
            ("api.github.racky", "/repos/acme/acme-platform/%2e%2e/%2e%2e/other/repo"),
            ("api.github.racky", "/repos/acme/acme-platform/%2E%2e/x"),
            ("api.github.racky", "/repos/acme/acme-platform%2fissues"),
            ("api.github.racky", "/repos//acme/acme-platform"),
            ("api.github.racky", "/repos/acme/acme-platform/./issues"),
            ("github.racky", "/acme/acme-platform.git/../../other/repo.git/info/refs"),
            ("github.racky", "/acme/acme-platform.git/%2e%2e/x/info/refs"),
        ]:
            with self.subTest(path=path), self.assertRaises(gh.Denied):
                gh.check(ACCESS, host, "GET", path, "", b"")
        gh.check(ACCESS, "api.github.racky", "GET", "/repos/acme/acme-platform/issues", "", b"")  # o caminho normal segue valendo

    def test_push_only_to_feature_branches_and_never_deletes(self):
        a, b = "1" * 40, "2" * 40
        gh.check(ACCESS, "github.racky", "POST", "/acme/acme-platform.git/git-receive-pack", "",
                 push_body((gh.ZERO, b, "refs/heads/feat/listings-chicago")))
        for refs in [((a, b, "refs/heads/main"),), ((a, gh.ZERO, "refs/heads/feat/x"),), ((a, b, "refs/tags/v1"),),
                     ((gh.ZERO, b, "refs/heads/feat/ok"), (a, b, "refs/heads/main"))]:
            with self.assertRaises(gh.Denied):
                gh.check(ACCESS, "github.racky", "POST", "/acme/acme-platform.git/git-receive-pack", "", push_body(*refs))

    def test_api_reads_and_opens_pull_requests_only(self):
        gh.check(ACCESS, "api.github.racky", "GET", "/repos/acme/acme-platform/pulls", "", b"")
        gh.check(ACCESS, "api.github.racky", "POST", "/repos/acme/acme-platform/pulls", "", b"{}")
        for method, path in [("PUT", "/repos/acme/acme-platform/pulls/1/merge"), ("DELETE", "/repos/acme/acme-platform"),
                             ("POST", "/repos/acme/acme-platform/issues"), ("GET", "/user"), ("GET", "/repos/other/repo")]:
            with self.assertRaises(gh.Denied):
                gh.check(ACCESS, "api.github.racky", method, path, "", b"")

    def test_config_parses_and_drops_bad_entries(self):
        cfg = Config.parse({"github": {"token": TOKEN, "repos": ["Acme/Acme-Platform.git", "nope"], "push_prefixes": ["bad", "refs/heads/feat/"]}})
        self.assertEqual(cfg.github.repos, ["acme/acme-platform"])
        self.assertEqual(cfg.github.push_prefixes, ["refs/heads/feat/"])
        self.assertIsNone(Config.parse({}).github)


class FakeGitHub:
    """Servidor no lugar do github.com: guarda a requisição recebida e responde 200."""

    def __init__(self):
        self.seen = []

    async def handle(self, reader, writer):
        head = await reader.readuntil(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        body = await reader.readexactly(int(headers.get("content-length", "0")))
        self.seen.append((lines[0], headers, body))
        payload = b'{"number": 7}'
        writer.write(b"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(payload) + payload)
        await writer.drain()
        writer.close()


class ThroughTheProxy(unittest.TestCase):
    def run_case(self, request: bytes, github: dict | None = None):
        async def body():
            tmp = tempfile.TemporaryDirectory()
            fake = FakeGitHub()
            server = await asyncio.start_server(fake.handle, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            data = {"bind": "127.0.0.1", "logs_dir": tmp.name}
            if github is not None:
                data["github"] = github
            proxy = EgressProxy(Config.parse(data), Path(tmp.name))
            seen_hosts = []

            async def connect(host):
                seen_hosts.append(host)
                return await asyncio.open_connection("127.0.0.1", port)
            proxy.github_connect = connect
            srv = await asyncio.start_server(proxy.handle, "127.0.0.1", 0)
            r, w = await asyncio.open_connection("127.0.0.1", srv.sockets[0].getsockname()[1])
            w.write(request)
            await w.drain()
            reply = await r.read(1 << 16)
            await asyncio.sleep(0.1)
            records = proxy.reqlog.read(None, 100)
            log_text = Path(proxy.reqlog.file).read_text() if Path(proxy.reqlog.file).exists() else ""
            srv.close()
            server.close()
            tmp.cleanup()
            return reply, fake.seen, seen_hosts, records, log_text
        return asyncio.run(body())

    def test_pull_request_goes_to_the_real_api_with_the_token_the_agent_never_sees(self):
        payload = b'{"title":"feat(listings): chicago","head":"feat/listings-chicago","base":"main"}'
        req = (b"POST http://api.github.racky/repos/acme/acme-platform/pulls HTTP/1.1\r\nHost: api.github.racky\r\n"
               b"Content-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(payload)) + payload
        reply, seen, hosts, records, log_text = self.run_case(req, {"token": TOKEN, "repos": ["acme/acme-platform"]})
        self.assertIn(b"201 Created", reply)
        self.assertEqual(hosts, ["api.github.com"])
        line, headers, body = seen[0]
        self.assertEqual(line, "POST /repos/acme/acme-platform/pulls HTTP/1.1")
        self.assertEqual(headers["authorization"], f"Bearer {TOKEN}")
        self.assertEqual(headers["host"], "api.github.com")
        self.assertEqual(body, payload)
        self.assertNotIn(TOKEN.encode(), reply)
        self.assertNotIn(TOKEN, log_text)
        self.assertEqual(records[-1]["kind"], "github")

    def test_git_push_uses_basic_auth_and_main_is_refused(self):
        ok = push_body((gh.ZERO, "2" * 40, "refs/heads/feat/listings-chicago"))
        req = (b"POST http://github.racky/acme/acme-platform.git/git-receive-pack HTTP/1.1\r\nHost: github.racky\r\n"
               b"Content-Type: application/x-git-receive-pack-request\r\nContent-Length: %d\r\n\r\n" % len(ok)) + ok
        reply, seen, hosts, _, _ = self.run_case(req, {"token": TOKEN, "repos": ["acme/acme-platform"]})
        self.assertEqual(hosts, ["github.com"])
        expected = "Basic " + base64.b64encode(f"x-access-token:{TOKEN}".encode()).decode()
        self.assertEqual(seen[0][1]["authorization"], expected)
        bad = push_body(("1" * 40, "2" * 40, "refs/heads/main"))
        req = (b"POST http://github.racky/acme/acme-platform.git/git-receive-pack HTTP/1.1\r\nHost: github.racky\r\n"
               b"Content-Length: %d\r\n\r\n" % len(bad)) + bad
        reply, seen, hosts, _, _ = self.run_case(req, {"token": TOKEN, "repos": ["acme/acme-platform"]})
        self.assertIn(b"200 OK", reply, "o git só mostra o motivo numa resposta do protocolo")
        self.assertIn(b"ng refs/heads/main push to refs/heads/main is not allowed", reply)
        self.assertEqual(seen, [], "nada chega ao GitHub")

    def test_refused_push_speaks_side_band_when_asked(self):
        body = pkt("1" * 40 + " " + gh.ZERO + " refs/heads/feat/x\0report-status side-band-64k") + b"0000"
        out = gh.push_rejection(body, "deleting refs/heads/feat/x is not allowed")
        payload = out.split(b"\r\n\r\n", 1)[1]
        self.assertEqual(payload[4:5], b"\x01", "canal 1 do side-band")
        self.assertIn(b"ng refs/heads/feat/x deleting", payload)
        self.assertTrue(payload.endswith(b"0000"))
        shallow = pkt("shallow " + "3" * 40) + body
        self.assertIn("side-band-64k", gh.receive_pack_caps(shallow), "clone raso: as capacidades vêm na primeira linha de comando")

    def test_without_access_the_gateway_says_so(self):
        req = b"GET http://github.racky/acme/acme-platform.git/info/refs?service=git-upload-pack HTTP/1.1\r\nHost: github.racky\r\n\r\n"
        reply, seen, _, _, _ = self.run_case(req, None)
        self.assertIn(b"403", reply)
        self.assertIn(b"GitHub access is off", reply)
        self.assertEqual(seen, [])

    def test_chunked_push_body_is_read(self):
        ok = push_body((gh.ZERO, "2" * 40, "refs/heads/feat/a"))
        chunked = b"%x\r\n" % len(ok) + ok + b"\r\n0\r\n\r\n"
        req = (b"POST http://github.racky/acme/acme-platform.git/git-receive-pack HTTP/1.1\r\nHost: github.racky\r\n"
               b"Transfer-Encoding: chunked\r\n\r\n") + chunked
        reply, seen, _, _, _ = self.run_case(req, {"token": TOKEN, "repos": ["acme/acme-platform"]})
        self.assertIn(b"201", reply)
        self.assertEqual(seen[0][2], ok)


if __name__ == "__main__":
    unittest.main()
