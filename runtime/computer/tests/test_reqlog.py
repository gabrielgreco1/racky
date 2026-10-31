import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_egress import reqlog as rl  # noqa: E402


def make(tmp, secrets=(), quota=rl.DEFAULT_BODY_QUOTA):
    return rl.ReqLog(Path(tmp), rl.Redactor(secrets), quota)


class Redaction(unittest.TestCase):
    def test_headers_by_name(self):
        r = rl.Redactor()
        out = dict((k, v) for k, v in r.headers([("Authorization", "Bearer abc"), ("Cookie", "s=1"), ("Set-Cookie", "s=2"),
                                                 ("Proxy-Authorization", "Basic xxx"), ("X-Api-Key", "k"), ("X-Auth-Token", "t"),
                                                 ("Accept", "text/html")]))
        for name in ["Authorization", "Cookie", "Set-Cookie", "Proxy-Authorization", "X-Api-Key", "X-Auth-Token"]:
            self.assertEqual(out[name], rl.REDACTED)
        self.assertEqual(out["Accept"], "text/html")

    def test_configured_header_names(self):
        r = rl.Redactor(extra_headers=["X-Custom-Secret"])
        self.assertEqual(r.headers([("x-custom-secret", "v")])[0][1], rl.REDACTED)

    def test_query_and_tokens(self):
        r = rl.Redactor()
        u = r.url("http://x.test/a?q=1&api_key=SUPERSECRET&token=abc123&page=2&sig=zzz")
        self.assertNotIn("SUPERSECRET", u)
        self.assertNotIn("abc123", u)
        self.assertNotIn("zzz", u)
        self.assertIn("q=1", u)
        self.assertIn("page=2", u)
        for secret in ["sk-ant-api03-abcdefghijkl", "ghp_abcdefghijklmnopqrstuv", "github_pat_11ABCDEFG0abcdefghijklmn", "AKIAABCDEFGHIJKLMNOP",
                       "Bearer abcdef123456", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"]:
            self.assertNotIn(secret.split(" ")[-1], r.text(f"x {secret} y"), secret)

    def test_prose_not_destroyed(self):
        r = rl.Redactor()
        text = "Basic information about Bearer authentication and tokens"
        self.assertEqual(r.text(text), text)

    def test_userinfo_in_url(self):
        r = rl.Redactor()
        self.assertEqual(r.url("http://user:pass@host.test/p"), f"http://{rl.REDACTED}@host.test/p")

    def test_configured_secret_values(self):
        r = rl.Redactor(["hunter2-password", "apikey123"])
        self.assertEqual(r.text("pw=hunter2-password and apikey123 ok"), f"pw={rl.REDACTED} and {rl.REDACTED} ok")

    def test_short_secrets_ignored(self):
        self.assertEqual(rl.Redactor(["a"]).text("banana"), "banana")


class Permissions(unittest.TestCase):
    def test_log_bodies_and_directory_are_owner_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp)
            log.append({"method": "GET", "url": "http://x.test/"})
            log.write_body("01TEST", "response", b"hello", 100)
            self.assertEqual(log.file.stat().st_mode & 0o777, 0o600)
            self.assertEqual((log.bodies / "01TEST.response.txt").stat().st_mode & 0o777, 0o600)
            self.assertEqual(log.bodies.stat().st_mode & 0o777, 0o700)


class Chain(unittest.TestCase):
    def test_append_chain_and_verify(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp)
            for i in range(5):
                log.append({"source": "egress", "url": f"http://x/{i}"})
            ok, line = rl.verify_chain(log.file)
            self.assertTrue(ok and line is None)
            first = json.loads(log.file.read_text().splitlines()[0])
            self.assertEqual(first["prev_sha256"], rl.GENESIS)

    def test_tamper_detected_with_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp)
            for i in range(5):
                log.append({"url": f"http://x/{i}"})
            lines = log.file.read_text().splitlines()
            lines[2] = lines[2].replace("http://x/2", "http://x/9")
            log.file.write_text("\n".join(lines) + "\n")
            self.assertEqual(rl.verify_chain(log.file), (False, 4))  # a linha 3 mudou: a 4 não encaixa mais

    def test_deleted_line_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp)
            for i in range(4):
                log.append({"url": str(i)})
            lines = log.file.read_text().splitlines()
            del lines[1]
            log.file.write_text("\n".join(lines) + "\n")
            self.assertFalse(rl.verify_chain(log.file)[0])

    def test_recover_continues_chain_after_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            make(tmp).append({"n": 1})
            again = make(tmp)
            again.append({"n": 2})
            self.assertEqual(rl.verify_chain(again.file), (True, None))
            self.assertEqual(again.count, 2)

    def test_ulids_sort_by_time(self):
        a, b = rl.new_ulid(1000), rl.new_ulid(2000)
        self.assertEqual(len(a), 26)
        self.assertLess(a, b)


class Bodies(unittest.TestCase):
    def test_body_limited_redacted_and_truncated(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp, secrets=["my-proxy-password"])
            data = b"hello my-proxy-password " + b"x" * 5000
            fields = log.write_body("01ID", "response", data, 100)
            self.assertTrue(fields["response_body_truncated"])
            stored = (Path(tmp) / fields["response_body_file"]).read_bytes()
            self.assertLessEqual(len(stored), 120)
            self.assertNotIn(b"my-proxy-password", stored)

    def test_quota_drops_bodies(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp, quota=50)
            self.assertIn("response_body_file", log.write_body("A", "response", b"x" * 40, 1000))
            self.assertEqual(log.write_body("B", "response", b"y" * 40, 1000), {"response_body_dropped": "quota"})

    def test_body_path_confined_to_bodies_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp)
            fields = log.write_body("C", "response", b"ok", 10)
            self.assertIsNotNone(log.body_path(fields["response_body_file"]))
            self.assertIsNone(log.body_path("../requests.jsonl"))
            self.assertIsNone(log.body_path("bodies/../requests.jsonl"))

    def test_textual(self):
        self.assertTrue(rl.is_textual("text/html; charset=utf-8"))
        self.assertTrue(rl.is_textual("application/json"))
        self.assertTrue(rl.is_textual("application/vnd.api+json"))
        self.assertFalse(rl.is_textual("image/png"))
        self.assertFalse(rl.is_textual(None))

    def test_sniff_text_without_content_type(self):
        self.assertTrue(rl.sniff_text(b'{"ok":true}'))
        self.assertTrue(rl.sniff_text("açaí e café".encode()))
        self.assertFalse(rl.sniff_text(b"\x89PNG\r\n\x1a\n\x00\x00"))
        self.assertFalse(rl.sniff_text(b""))
        self.assertFalse(rl.sniff_text(bytes(range(1, 31)) * 10))

    def test_exclusive_create_never_overwrites(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = make(tmp)
            log.write_body("D", "response", b"one", 10)
            with self.assertRaises(FileExistsError):
                log.write_body("D", "response", b"two", 10)


if __name__ == "__main__":
    unittest.main()
